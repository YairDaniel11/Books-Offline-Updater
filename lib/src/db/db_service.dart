import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../services/repo_service.dart' show DownloadCancelled, githubRepo;
import 'db_manifest.dart';
import 'zstd_stream.dart';

/// כתובת קבועה של המניפסט העדכני (release בשם `db`). הקבצים עצמם ב-`db-v<N>`.
const dbManifestUrl = 'https://github.com/$githubRepo/releases/download/db/manifest.json';

/// צעדי עדכון בין גרסאות עוקבות: release נפרד שלא נמחק (db-steps).
const stepsManifestUrl = 'https://github.com/$githubRepo/releases/download/db-steps/steps-manifest.json';

const stepsFileName = 'steps-manifest.json';
const stepsSigFileName = 'steps-manifest.json.sig';
const manifestFileName = 'manifest.json';
const manifestSigFileName = 'manifest.json.sig';

/// מניפסט שאומת (חתימה + library_id).
class DbRelease {
  DbRelease(this.manifestBytes, this.signature, this.manifest);
  final Uint8List manifestBytes;
  final String signature;
  final DbManifest manifest;
}

class StepsRelease {
  StepsRelease(this.manifestBytes, this.signature, this.manifest);
  final Uint8List manifestBytes;
  final String signature;
  final StepsManifest manifest;
}

class DbException implements Exception {
  DbException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum LocalDbState {
  /// כבר הגרסה העדכנית.
  current,

  /// גרסה ישנה שיש לה קובץ עדכון.
  hasDelta,

  /// גרסה לא מוכרת (או ישנה מדי): נדרש המסד המלא.
  unknown,
}

class LocalDbInfo {
  LocalDbInfo(this.sha256, this.state, {this.version, this.delta, this.updates});
  final String sha256;
  final LocalDbState state;

  /// גרסת המסד המקומי, כשזוהתה לפי קובץ עדכון.
  final int? version;
  final DbArtifact? delta;

  /// הקבצים שיש להחיל לפי הסדר כדי להגיע לגרסה העדכנית: קובץ עדכון אחד, או שרשרת צעדים.
  final List<DbArtifact>? updates;
}

typedef ProgressCallback = void Function(int done, int? total, String detail);

class DbService {
  DbService() {
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'books-offline-update'
      ..autoUncompress = false;
  }

  late final HttpClient _client;

  void close() => _client.close(force: true);

  // ─── מניפסט ───────────────────────────────────────────────────────

  DbRelease _verify(Uint8List bytes, String sig) {
    if (!verifyManifestSignature(bytes, sig)) {
      throw DbException('לא ניתן לוודא שהקבצים מהמאגר המקורי, ולכן לא ייעשה בהם שימוש.');
    }
    final m = DbManifest.parse(bytes);
    if (m.libraryId != dbLibraryId) throw DbException('הקבצים שייכים למסד אחר (${m.libraryId})');
    return DbRelease(bytes, sig, m);
  }

  Future<Uint8List> _getBytes(String url) async {
    final req = await _client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw DbException('שגיאת שרת ${res.statusCode}');
    }
    final b = BytesBuilder();
    await for (final c in res.timeout(const Duration(seconds: 30))) {
      b.add(c);
    }
    return b.takeBytes();
  }

  Future<DbRelease> fetchRemote() async {
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final bytes = await _getBytes('$dbManifestUrl?t=$stamp');
      final sig = utf8.decode(await _getBytes('$dbManifestUrl.sig?t=$stamp'));
      return _verify(bytes, sig);
    } on DbException {
      rethrow;
    } on DbManifestException catch (e) {
      throw DbException(e.message);
    } catch (e) {
      throw DbException('לא ניתן לבדוק את גרסת המסד ($e)');
    }
  }

  StepsRelease _verifySteps(Uint8List bytes, String sig) {
    if (!verifyManifestSignature(bytes, sig)) throw DbException('צעדי העדכון לא אומתו כמקוריים');
    final m = StepsManifest.parse(bytes);
    if (m.libraryId != dbLibraryId) throw DbException('צעדי העדכון שייכים למסד אחר');
    return StepsRelease(bytes, sig, m);
  }

  /// צעדי העדכון ברשת. `null` כשאין כאלה או שאי אפשר לקרוא אותם: אז פשוט אין שרשרת.
  Future<StepsRelease?> fetchSteps() async {
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final bytes = await _getBytes('$stepsManifestUrl?t=$stamp');
      final sig = utf8.decode(await _getBytes('$stepsManifestUrl.sig?t=$stamp'));
      return _verifySteps(bytes, sig);
    } catch (_) {
      return null;
    }
  }

  Future<StepsRelease?> readMirrorSteps(String dir) async {
    final mf = File(p.join(dir, stepsFileName));
    final sf = File(p.join(dir, stepsSigFileName));
    if (!await mf.exists() || !await sf.exists()) return null;
    try {
      return _verifySteps(await mf.readAsBytes(), await sf.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// קורא מניפסט מתיקיית מראה; `null` אם אין בה כזה.
  Future<DbRelease?> readMirror(String dir) async {
    final mf = File(p.join(dir, manifestFileName));
    final sf = File(p.join(dir, manifestSigFileName));
    if (!await mf.exists() || !await sf.exists()) return null;
    try {
      return _verify(await mf.readAsBytes(), await sf.readAsString());
    } on DbManifestException catch (e) {
      throw DbException(e.message);
    }
  }

  // ─── קבצים ────────────────────────────────────────────────────────

  static String partPath(String dir, DbPart part) => p.join(dir, part.fileName);

  /// כמה מחלקי [a] כבר שלמים (לפי גודל) בתיקיית המראה.
  static ({int present, int total}) partsStatus(DbArtifact a, String dir) {
    var present = 0;
    for (final part in a.parts) {
      final f = File(partPath(dir, part));
      if (f.existsSync() && f.lengthSync() == part.size) present++;
    }
    return (present: present, total: a.parts.length);
  }

  static bool isComplete(DbArtifact a, String dir) {
    final s = partsStatus(a, dir);
    return s.present == s.total;
  }

  static Future<String> sha256OfFile(
    String path, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final f = File(path);
    final total = await f.length();
    var done = 0;
    final stream = f.openRead().map((c) {
      if (isCancelled?.call() ?? false) throw DownloadCancelled();
      done += c.length;
      onProgress?.call(done, total);
      return c;
    });
    return (await sha256.bind(stream).first).toString();
  }

  /// מוריד חלק לתיקיית המראה: ממשיך מהמקום שנעצר, מאמת sha256 וממיר שם רק אחרי אימות מלא.
  Future<void> _downloadPart(
    DbPart part,
    String dir, {
    required void Function(int bytes) onBytes,
    required bool Function() isCancelled,
  }) async {
    final target = File(partPath(dir, part));
    final tmp = File('${target.path}.part');
    if (await target.exists()) {
      if (await target.length() == part.size && await sha256OfFile(target.path, isCancelled: isCancelled) == part.sha256) {
        onBytes(part.size);
        return;
      }
      await target.delete();
    }
    Object? lastError;
    var counted = 0;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (isCancelled()) throw DownloadCancelled();
      try {
        var have = await tmp.exists() ? await tmp.length() : 0;
        if (have > part.size) {
          await tmp.delete();
          have = 0;
        }
        // מסנכרנים את המונה לגודל בפועל (אחרי ניסיון חוזר ההמשך מתחיל מהקובץ הקיים).
        onBytes(have - counted);
        counted = have;
        if (have < part.size) {
          final req = await _client.getUrl(Uri.parse(part.url));
          if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
          final res = await req.close().timeout(const Duration(seconds: 30));
          if (res.statusCode != 200 && res.statusCode != 206) {
            await res.drain<void>();
            throw DbException('שגיאת שרת ${res.statusCode}');
          }
          if (res.statusCode == 200 && have > 0) {
            // השרת התעלם מ-Range: מתחילים מחדש.
            onBytes(-counted);
            counted = 0;
            have = 0;
          }
          final sink = tmp.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
          try {
            await for (final c in res.timeout(const Duration(seconds: 30))) {
              if (isCancelled()) throw DownloadCancelled();
              sink.add(c);
              counted += c.length;
              onBytes(c.length);
            }
            await sink.flush();
          } finally {
            await sink.close();
          }
        }
        if (await tmp.length() == part.size && await sha256OfFile(tmp.path, isCancelled: isCancelled) == part.sha256) {
          await tmp.rename(target.path);
          return;
        }
        await tmp.delete();
        onBytes(-counted);
        counted = 0;
        throw DbException('בדיקת תקינות הקובץ נכשלה');
      } on DownloadCancelled {
        rethrow;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    throw DbException('ההורדה של ${part.fileName} נכשלה: $lastError');
  }

  /// מוריד את כל חלקי [artifacts] לתיקיית המראה, ושומר ליד זה את המניפסט החתום.
  Future<void> download(
    DbRelease release,
    List<DbArtifact> artifacts,
    String dir, {
    required ProgressCallback onProgress,
    required bool Function() isCancelled,
    StepsRelease? steps,
  }) async {
    await Directory(dir).create(recursive: true);
    final parts = [for (final a in artifacts) ...a.parts];
    final total = parts.fold<int>(0, (a, b) => a + b.size);
    var done = 0;
    for (final part in parts) {
      await _downloadPart(
        part,
        dir,
        onBytes: (n) {
          done += n;
          onProgress(done, total, part.fileName);
        },
        isCancelled: isCancelled,
      );
    }
    // המניפסט נשמר אחרון: מראה עם מניפסט תמיד מצביעה על קבצים שלמים.
    await _writeAtomic(File(p.join(dir, manifestFileName)), release.manifestBytes);
    await _writeAtomic(File(p.join(dir, manifestSigFileName)), utf8.encode(release.signature));
    if (steps != null) {
      await _writeAtomic(File(p.join(dir, stepsFileName)), steps.manifestBytes);
      await _writeAtomic(File(p.join(dir, stepsSigFileName)), utf8.encode(steps.signature));
    }
    await _cleanOrphans(dir, release.manifest, steps?.manifest ?? (await readMirrorSteps(dir))?.manifest);
  }

  Future<void> _writeAtomic(File f, List<int> bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  /// מוחק מהמראה קבצי גרסאות קודמות שאינם מופיעים במניפסט הנוכחי (רק קבצים שהתוכנה יצרה).
  Future<void> _cleanOrphans(String dir, DbManifest m, StepsManifest? steps) async {
    final keep = <String>{
      for (final a in [m.full, ...m.deltas, ...?steps?.steps]) ...a.parts.map((e) => e.fileName),
    };
    try {
      await for (final e in Directory(dir).list()) {
        if (e is! File) continue;
        final n = p.basename(e.path);
        if (n.startsWith('$dbLibraryId-') && (n.contains('.db') && !keep.contains(n))) {
          await e.delete();
        }
      }
    } catch (_) {}
  }

  // ─── מסד מקומי ────────────────────────────────────────────────────

  Future<LocalDbInfo> inspectLocalDb(
    DbManifest m,
    String path, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    String? knownSha,
    StepsManifest? steps,
    bool Function(List<DbArtifact> chain)? chainIsWorthIt,
  }) async {
    final sha = knownSha ?? await sha256OfFile(path, onProgress: onProgress, isCancelled: isCancelled);
    if (sha == m.full.sha256) return LocalDbInfo(sha, LocalDbState.current, version: m.version);
    final d = m.deltaForSha(sha);
    if (d != null) return LocalDbInfo(sha, LocalDbState.hasDelta, version: d.fromVersion, delta: d, updates: [d]);
    final chain = steps?.chainFromSha(sha, m.full.sha256);
    if (chain != null && chain.isNotEmpty && (chainIsWorthIt?.call(chain) ?? true)) {
      return LocalDbInfo(sha, LocalDbState.hasDelta, version: chain.first.fromVersion, updates: chain);
    }
    return LocalDbInfo(sha, LocalDbState.unknown);
  }

  /// בונה את המסד היעד מתוך תיקיית המראה. [delta] (אם הועבר) מוחל על המסד הקיים ב-[target];
  /// אחרת מחולץ המסד המלא. הקובץ היעד מוחלף רק אחרי שה-SHA-256 של התוצאה אומת.
  Future<void> install(
    DbArtifact artifact,
    String mirrorDir,
    String target, {
    required ProgressCallback onProgress,
    required bool Function() isCancelled,
  }) async {
    final sources = [for (final part in artifact.parts) partPath(mirrorDir, part)];
    for (final part in artifact.parts) {
      final f = File(partPath(mirrorDir, part));
      if (!await f.exists() || await f.length() != part.size) {
        throw DbException('בתיקיית המראה חסר או חלקי הקובץ ${part.fileName}');
      }
    }
    // אימות תקינות החלקים לפני הפענוח (העתקה בדיסק און קי עלולה להשחית).
    final total = artifact.downloadSize;
    var base = 0;
    for (final part in artifact.parts) {
      final sha = await sha256OfFile(
        partPath(mirrorDir, part),
        onProgress: (d, _) => onProgress(base + d, total, 'בודק תקינות: ${part.fileName}'),
        isCancelled: isCancelled,
      );
      if (sha != part.sha256) throw DbException('הקובץ ${part.fileName} פגום. יש להוריד או להעתיק אותו מחדש.');
      base += part.size;
    }

    final tmpPath = '$target.new';
    final old = File('$target.old');
    try {
      await Directory(p.dirname(target)).create(recursive: true);
      final ZstdResult r;
      if (artifact.compression == 'none') {
        r = await _concat(sources, tmpPath, onProgress, isCancelled);
      } else {
        r = await zstdDecompressFiles(
          sources,
          tmpPath,
          prefixPath: artifact.isDelta ? target : null,
          onProgress: (d, t) => onProgress(d, t, artifact.isDelta ? 'מחיל את העדכון' : 'מחלץ את המסד'),
          isCancelled: isCancelled,
        );
      }
      if (isCancelled()) throw DownloadCancelled();
      if (r.size != artifact.size || r.sha256 != artifact.sha256) {
        throw DbException('התוצאה לא עברה בדיקת תקינות. המסד הקיים לא שונה.');
      }
      onProgress(1, 1, 'מחליף את הקובץ');
      final t = File(tmpPath);
      final dest = File(target);
      final hadOld = await dest.exists();
      if (hadOld) {
        if (await old.exists()) await old.delete();
        try {
          await dest.rename(old.path);
        } on FileSystemException {
          throw DbException('לא ניתן להחליף את הקובץ. ייתכן שאוצריא פתוחה ומשתמשת בו. סגרו אותה ונסו שוב.');
        }
      }
      try {
        await t.rename(target);
      } catch (_) {
        if (hadOld) await old.rename(target);
        rethrow;
      }
      if (hadOld) await old.delete();
    } finally {
      final t = File(tmpPath);
      if (await t.exists()) await t.delete();
    }
  }

  static const _sqliteHeader = 'SQLite format 3\u0000';

  /// האם הקובץ נראה כמסד SQLite: כותרת "SQLite format 3\0". קובץ שחסר או ריק נחשב תקין (ייווצר מסד חדש).
  static Future<bool> looksLikeSqlite(String path) async {
    final f = File(path);
    if (!await f.exists()) return true;
    final len = await f.length();
    if (len == 0) return true;
    if (len < _sqliteHeader.length) return false;
    RandomAccessFile? raf;
    try {
      raf = await f.open();
      final head = await raf.read(_sqliteHeader.length);
      return String.fromCharCodes(head) == _sqliteHeader;
    } finally {
      await raf?.close();
    }
  }

  /// כמה מקום פנוי דרוש בכונן של היעד: החלקים שעוד צריך להוריד, ואת התוצאה (`.new`) לצד הקובץ הקיים.
  /// בשרשרת צעדים הצעדים מוחלים בזה אחר זה, ולכן נספר הגדול שבהם. מרווח קטן לתקורה.
  static int requiredBytes(List<DbArtifact> artifacts, {int bytesToDownload = 0}) {
    var biggest = 0;
    for (final a in artifacts) {
      if (a.size > biggest) biggest = a.size;
    }
    return bytesToDownload + biggest + 64 * 1024 * 1024;
  }

  /// התאוששות מהפסקה (קריסה, כיבוי) בין "יעד ← .old" ל-".new ← יעד" בהחלפת המסד:
  /// אם אין קובץ יעד אבל יש `.old`, מחזירים אותו. מנקים גם `.new` שנשאר.
  static Future<void> recoverInterrupted(String target) async {
    try {
      final old = File('$target.old');
      if (!await File(target).exists() && await old.exists()) await old.rename(target);
      final nw = File('$target.new');
      if (await nw.exists()) await nw.delete();
    } catch (_) {}
  }

  Future<ZstdResult> _concat(
    List<String> sources,
    String dest,
    ProgressCallback onProgress,
    bool Function() isCancelled,
  ) async {
    final out = File(dest).openWrite();
    final sink = _DigestCollector();
    final h = sha256.startChunkedConversion(sink);
    var size = 0;
    try {
      for (final s in sources) {
        await for (final c in File(s).openRead()) {
          if (isCancelled()) throw DownloadCancelled();
          out.add(c);
          h.add(c);
          size += c.length;
        }
      }
      await out.flush();
    } finally {
      await out.close();
      h.close();
    }
    return ZstdResult(size, sink.value.toString());
  }
}

class _DigestCollector implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
