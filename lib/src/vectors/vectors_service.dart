import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../db/db_manifest.dart' show verifyManifestSignature;
import '../db/zstd_stream.dart';
import '../services/native_sha256.dart';
import '../services/net_errors.dart';
import '../services/repo_service.dart' show DownloadCancelled, githubRepo;
import 'vector_set.dart';
import 'vectors_manifest.dart';

const vectorsManifestUrl = 'https://github.com/$githubRepo/releases/download/vectors/vectors-manifest.json';
const vectorsManifestFileName = 'vectors-manifest.json';
const vectorsSigFileName = 'vectors-manifest.json.sig';

typedef VProgress = void Function(int done, int? total, String detail);

/// מניפסט וקטורים שאומת (חתימה).
class VectorsRelease {
  VectorsRelease(this.bytes, this.signature, this.manifest);
  final Uint8List bytes;
  final String signature;
  final VectorsManifest manifest;
}

class VectorsService {
  VectorsService() {
    _client = createHttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'books-offline-update'
      ..autoUncompress = false;
  }
  late final HttpClient _client;
  void close() => _client.close(force: true);

  static VectorsRelease verify(Uint8List bytes, String sig) {
    if (!verifyManifestSignature(bytes, sig)) {
      throw VectorsException('לא ניתן לוודא שמניפסט הוקטורים מהמאגר המקורי, ולכן לא ייעשה בו שימוש.');
    }
    return VectorsRelease(bytes, sig, VectorsManifest.parse(bytes));
  }

  Future<Uint8List> _getBytes(String url) async {
    final req = await _client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 30));
    await ensureOk(res);
    final b = BytesBuilder();
    await for (final c in res.timeout(const Duration(seconds: 30))) {
      b.add(c);
    }
    return b.takeBytes();
  }

  Future<VectorsRelease> fetchRemote() async {
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final bytes = await _getBytes('$vectorsManifestUrl?t=$stamp');
      final sig = utf8.decode(await _getBytes('$vectorsManifestUrl.sig?t=$stamp'));
      return verify(bytes, sig);
    } on VectorsException {
      rethrow;
    } catch (e) {
      throw VectorsException('לא ניתן לבדוק את וקטורי החיפוש. ${friendlyNetError(e)}');
    }
  }

  /// מניפסט הוקטורים שבתיקיית המראה, או null כשאין.
  static VectorsRelease? readMirror(String dir) {
    final mf = File(p.join(dir, vectorsManifestFileName));
    final sf = File(p.join(dir, vectorsSigFileName));
    if (!mf.existsSync() || !sf.existsSync()) return null;
    try {
      return verify(mf.readAsBytesSync(), sf.readAsStringSync());
    } on VectorsException {
      rethrow;
    }
  }

  static String fileUrl(VectorsManifest m, VectorsFile f) =>
      'https://github.com/$githubRepo/releases/download/vectors-v${m.dbVersion}/${Uri.encodeComponent(f.file)}';

  /// האם כל קבצי הוקטורים שלמים (לפי גודל) בתיקייה.
  static bool isComplete(VectorsManifest m, String dir) {
    for (final f in m.files) {
      final file = File(p.join(dir, f.file));
      if (!file.existsSync() || file.lengthSync() != f.size) return false;
    }
    return true;
  }

  /// מוריד את קבצי הוקטורים כמו שהם (בלי פריסה). השרת לא תומך ב-Range, ולכן כותבים ל-.part
  /// ומשנים שם רק בגודל ו-sha256 מדויקים, עם ניסיונות חוזרים. המניפסט נכתב אחרון.
  Future<void> download(
    VectorsRelease r,
    String dir, {
    required VProgress onProgress,
    required bool Function() isCancelled,
  }) async {
    final m = r.manifest;
    await Directory(dir).create(recursive: true);
    final total = m.downloadSize;
    var done = 0;
    for (final f in m.files) {
      final target = File(p.join(dir, f.file));
      final tmp = File('${target.path}.part');
      if (await target.exists()) {
        if (await target.length() == f.size &&
            await sha256File(target.path, isCancelled: isCancelled) == f.sha256) {
          done += f.size;
          onProgress(done, total, f.file);
          continue;
        }
        await target.delete();
      }
      Object? lastError;
      var ok = false;
      final base = done;
      for (var attempt = 0; attempt < 4 && !ok; attempt++) {
        if (isCancelled()) throw DownloadCancelled();
        try {
          if (await tmp.exists()) await tmp.delete();
          done = base;
          final req = await _client.getUrl(Uri.parse(fileUrl(m, f)));
          final res = await req.close().timeout(const Duration(seconds: 30));
          await ensureOk(res);
          final sink = tmp.openWrite();
          try {
            await for (final c in res.timeout(const Duration(seconds: 60))) {
              if (isCancelled()) throw DownloadCancelled();
              sink.add(c);
              done += c.length;
              onProgress(done, total, f.file);
            }
            await sink.flush();
          } finally {
            await sink.close();
          }
          if (await tmp.length() == f.size &&
              await sha256File(tmp.path, isCancelled: isCancelled) == f.sha256) {
            await tmp.rename(target.path);
            ok = true;
          } else {
            await tmp.delete();
            throw VectorsException('בדיקת תקינות הקובץ נכשלה');
          }
        } on DownloadCancelled {
          try {
            if (await tmp.exists()) await tmp.delete();
          } catch (_) {}
          rethrow;
        } catch (e) {
          lastError = e;
          if (isFinalNetFailure(e)) break;
          await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      }
      if (!ok) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        throw VectorsException('ההורדה של ${f.file} נכשלה. ${friendlyNetError(lastError ?? 'שגיאה')}');
      }
    }
    await _writeAtomic(File(p.join(dir, vectorsManifestFileName)), r.bytes);
    await _writeAtomic(File(p.join(dir, vectorsSigFileName)), utf8.encode(r.signature));
    // ניקוי קבצי וקטורים של גרסאות קודמות (רק קבצים שהתוכנה יצרה).
    final keep = {for (final f in m.files) f.file};
    try {
      await for (final e in Directory(dir).list()) {
        final n = p.basename(e.path);
        if (e is File && n.startsWith('otzarya-books-vectors-') && !keep.contains(n)) await e.delete();
      }
    } catch (_) {}
  }

  /// מעתיק חבילה שלמה (קבצים + מניפסט) מ-[srcDir] ל-[destDir] בלי הורדה: כותב ל-.part, מאמת sha256 ורק אז משנה שם.
  /// קובץ זהה שכבר ביעד לא נכתב מחדש. המניפסט נכתב אחרון.
  static Future<void> copyPackage(
    VectorsRelease r,
    String srcDir,
    String destDir, {
    required VProgress onProgress,
    required bool Function() isCancelled,
  }) async {
    final m = r.manifest;
    await Directory(destDir).create(recursive: true);
    final total = m.downloadSize * 2;
    var done = 0;
    for (final f in m.files) {
      final src = File(p.join(srcDir, f.file));
      final dest = File(p.join(destDir, f.file));
      final tmp = File('${dest.path}.part');
      if (!await src.exists() || await src.length() != f.size) {
        throw VectorsException('בתיקיית המקור חסר או חלקי הקובץ ${f.file}');
      }
      try {
        if (await dest.exists() && await dest.length() == f.size) {
          final same = await sha256File(dest.path, isCancelled: isCancelled) == f.sha256;
          if (same) {
            done += f.size * 2;
            onProgress(done, total, f.file);
            continue;
          }
        }
        final out = tmp.openWrite();
        try {
          await for (final c in src.openRead()) {
            if (isCancelled()) throw DownloadCancelled();
            out.add(c);
            done += c.length;
            onProgress(done, total, 'מעתיק');
          }
          await out.flush();
        } finally {
          await out.close();
        }
        final sha = await sha256File(tmp.path,
            onProgress: (d, _) => onProgress(done + d, total, 'בודק שההעתקה תקינה'), isCancelled: isCancelled);
        if (sha != f.sha256) throw VectorsException('ההעתקה לא עברה בדיקת תקינות. נסו שוב, או בחרו כונן אחר.');
        done += f.size;
        if (await dest.exists()) await dest.delete();
        await tmp.rename(dest.path);
      } finally {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    }
    await _writeAtomicStatic(File(p.join(destDir, vectorsManifestFileName)), r.bytes);
    await _writeAtomicStatic(File(p.join(destDir, vectorsSigFileName)), utf8.encode(r.signature));
  }

  static Future<void> _writeAtomicStatic(File f, List<int> bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  Future<void> _writeAtomic(File f, List<int> bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  /// מתקין את הוקטורים מתיקיית החבילה לסט של אוצריא. התנאים שאינם תלויים בקבצים
  /// (אוצריא סגורה, התאמת מסד, מקום פנוי) נבדקים בבקר לפני הקריאה לכאן.
  /// מחזיר את מספר הדור החדש.
  static Future<int> install(
    VectorsManifest m,
    String packageDir,
    String vectorsDir, {
    required VProgress onProgress,
    required bool Function() isCancelled,
  }) async {
    // 1. אימות הקבצים.
    final total = m.downloadSize;
    var base = 0;
    final sources = <String>[];
    for (final f in m.files) {
      final path = p.join(packageDir, f.file);
      final file = File(path);
      if (!await file.exists() || await file.length() != f.size) {
        throw VectorsException('בתיקיית החבילה חסר או חלקי הקובץ ${f.file}');
      }
      final sha = await sha256File(path,
          onProgress: (d, _) => onProgress(base + d, total, 'בודק תקינות: ${f.file}'), isCancelled: isCancelled);
      if (sha != f.sha256) throw VectorsException('הקובץ ${f.file} פגום. יש להוריד או להעתיק אותו מחדש.');
      base += f.size;
      sources.add(path);
    }

    // 2. זהות הסט.
    var live = LiveSet.open(vectorsDir);
    if (live.doc['identity_digest'] != m.identityDigest || live.doc['codec_params_sha256'] != m.codecParamsSha256) {
      throw VectorsException('הוקטורים נבנו למודל אחר מהסט של אוצריא כאן, ולכן ההתקנה נעצרת.');
    }
    final segs = live.segments;
    if (segs.any((s) => s['id'] == m.segment.id)) {
      throw VectorsException('הוקטורים האלה כבר רשומים בסט של אוצריא.');
    }
    if (segs.any(isOurs)) {
      throw VectorsException(
          'כבר מותקנים וקטורים של המאגר בגרסה אחרת. עדכון וקטורים לגרסת מסד חדשה עדיין לא נבדק, ולכן התוכנה לא מבצעת אותו.');
    }

    // 3. פריסה.
    final segDir = Directory(p.join(vectorsDir, 'segments'));
    await segDir.create(recursive: true);
    final tmp = File(p.join(segDir.path, 'personal-vectors.oxv.tmp'));
    final finalFile = File(p.join(segDir.path, '${m.segment.id}.oxv'));
    var moved = false;
    try {
      final r = await zstdDecompressFiles(
        sources,
        tmp.path,
        onProgress: (d, t) => onProgress(d, t, 'פורס את הוקטורים'),
        isCancelled: isCancelled,
      );
      if (isCancelled()) throw DownloadCancelled();
      if (r.size != m.segment.size || r.sha256 != m.segment.sha256) {
        throw VectorsException('הוקטורים שנפרסו לא עברו בדיקת תקינות. הסט של אוצריא לא שונה.');
      }
      final h = readOxvHeader(tmp.path);
      if (h.id != m.segment.id || h.identityDigest != live.doc['identity_digest'] || h.version != 3) {
        throw VectorsException('כותרת מקטע הוקטורים אינה תואמת למניפסט או לסט. ההתקנה נעצרה.');
      }
      onProgress(1, 1, 'רושם בסט של אוצריא');
      final lock = SetLock.acquire(vectorsDir);
      try {
        final live2 = LiveSet.open(vectorsDir);
        if (live2.doc['generation'] != live.doc['generation']) {
          throw VectorsException('הסט השתנה במהלך ההתקנה. הפעילו שוב.');
        }
        live = live2;
        await tmp.rename(finalFile.path);
        moved = true;
        return await publishGeneration(
          live,
          segId: m.segment.id,
          slots: h.slots,
          sha256Hex: m.segment.sha256,
          size: m.segment.size,
          version: (live.doc['library_version'] as num).toInt(),
          origin: 'prebuilt: ${m.runId}',
        );
      } finally {
        lock.release();
      }
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
        if (moved && await finalFile.exists()) await finalFile.delete();
      } catch (_) {}
      rethrow;
    }
  }
}
