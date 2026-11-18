import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../db/zstd_stream.dart';
import '../services/disk_space.dart';
import '../services/native_sha256.dart';
import 'oxv_format.dart';
import 'vectors_manifest.dart';

/// קידומת ה-backend שבה אוצריא ו-`otzaria_personal_vectors.py` מזהים מקטע "שלנו".
const vectorsWorkerBackend = 'otzaria-personal-vectors books-offline-update';
const _ourPrefixes = ['otzaria-personal-vectors', 'otzaria-sources personal export'];

bool _isOurs(Map seg) {
  final w = (seg['provenance'] is Map ? (seg['provenance'] as Map)['worker'] : null);
  final b = w is Map ? w['backend'] : null;
  return b is String && _ourPrefixes.any(b.startsWith);
}

/// הסט החי של אוצריא: מה ש-CURRENT מצביע עליו.
class LiveVectorSet {
  LiveVectorSet._(this.dir, this.pointer, this.doc, this.genDir);
  final String dir;
  final Map<String, dynamic> pointer;
  final Map<String, dynamic> doc;
  final String genDir;

  List<Map<String, dynamic>> get segments => [for (final s in doc['segments'] as List) Map<String, dynamic>.from(s as Map)];
  int get generation => doc['generation'] as int;

  static Future<LiveVectorSet> load(String vectorsDir) async {
    final cur = File(p.join(vectorsDir, 'CURRENT'));
    if (!await cur.exists()) throw VectorsException('לא נמצא סט וקטורים של אוצריא בתיקייה $vectorsDir. יש להפעיל את החיפוש הסמנטי באוצריא (או להוריד את הוקטורים הרשמיים) לפחות פעם אחת.');
    try {
      final ptr = Map<String, dynamic>.from(jsonDecode(utf8.decode(await cur.readAsBytes()).replaceFirst('﻿', '')) as Map);
      final rel = ptr['set'] as String;
      final setPath = p.normalize(p.join(vectorsDir, rel));
      if (!p.isWithin(vectorsDir, setPath)) throw VectorsException('CURRENT מצביע מחוץ לתיקיית הוקטורים');
      final raw = await File(setPath).readAsBytes();
      if (sha256.convert(raw).toString() != ptr['set_sha256']) {
        throw VectorsException('CURRENT אינו תואם לקובץ הסט שלו. לא נוגעים בסט.');
      }
      final doc = Map<String, dynamic>.from(jsonDecode(utf8.decode(raw)) as Map);
      if (doc['generation'] is! int || doc['segments'] is! List) throw VectorsException('מבנה סט הוקטורים לא צפוי');
      return LiveVectorSet._(vectorsDir, ptr, doc, p.dirname(setPath));
    } on VectorsException {
      rethrow;
    } catch (e) {
      throw VectorsException('קריאת סט הוקטורים של אוצריא נכשלה: $e');
    }
  }
}

class VectorsInstallResult {
  const VectorsInstallResult(this.generation, this.slots);
  final int generation;
  final int slots;
}

class VectorsInstaller {
  /// בודק את התנאים להתקנה (סעיף 5 באפיון) בלי לשנות דבר. מחזיר את הסט החי, או זורק [VectorsException] עם הסבר.
  /// [installedDbSha256]: sha256 של המסד המצורף לאוצריא (null: לא צורף).
  static Future<LiveVectorSet> checkPreconditions(
    VectorsManifest m,
    String vectorsDir, {
    required String? installedDbSha256,
  }) async {
    final live = await LiveVectorSet.load(vectorsDir);
    final doc = live.doc;
    if (doc['identity_digest'] != m.identityDigest || doc['codec_params_sha256'] != m.codecParamsSha256) {
      throw VectorsException('הוקטורים נבנו למודל אחר מזה שבאוצריא כאן, ולכן לא מתקינים אותם.');
    }
    if (installedDbSha256 == null) {
      throw VectorsException('מסד הספרים עוד לא צורף לאוצריא. מתקינים קודם את המסד, ואחר כך את הוקטורים.');
    }
    if (installedDbSha256 != m.dbSha256) {
      throw VectorsException('הוקטורים נבנו למסד גרסה ${m.dbVersion}, והמסד שמותקן כאן שונה ממנו. '
          'מעדכנים קודם את המסד לגרסה ${m.dbVersion}, ואחר כך מתקינים את הוקטורים.');
    }
    for (final s in live.segments) {
      if (s['id'] == m.segment.id) throw VectorsException('הוקטורים האלה כבר מותקנים.');
      if (_isOurs(s)) {
        throw VectorsException('כבר מותקנים כאן וקטורים של המאגר (גרסה אחרת, או שאוצריא כבר איחדה אותם). '
            'עדכון וקטורים לגרסה חדשה עדיין לא נתמך בתוכנה.');
      }
    }
    return live;
  }

  /// כמה מקום פנוי דרוש בכונן של אוצריא: הפריסה + שוליים.
  static int requiredBytes(VectorsManifest m) => m.segment.size + (64 << 20);

  static Future<VectorsInstallResult> install(
    VectorsManifest m, {
    required String vectorsDir,
    required String filesDir,
    required String? installedDbSha256,
    void Function(String stage, int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;
    void check() {
      if (cancelled()) throw VectorsException('הפעולה בוטלה');
    }

    // 1. קבצי החבילה: קיימים, בגודל ובתוכן הנכונים.
    final sources = <String>[];
    var i = 0;
    for (final f in m.files) {
      i++;
      final path = p.join(filesDir, f.file);
      final file = File(path);
      if (!await file.exists() || await file.length() != f.size) {
        throw VectorsException('הקובץ ${f.file} חסר או שגודלו שונה מהמניפסט. יש להכין את החבילה מחדש.');
      }
      final sha = await sha256File(path,
          onProgress: (d, t) => onProgress?.call('בודק את הקובץ הדחוס ($i/${m.files.length})', d, t), isCancelled: cancelled);
      check();
      if (sha != f.sha256) throw VectorsException('הקובץ ${f.file} פגום (sha256 שונה מהמניפסט). יש להכין את החבילה מחדש.');
      sources.add(path);
    }

    // 2. תנאים.
    final live0 = await checkPreconditions(m, vectorsDir, installedDbSha256: installedDbSha256);
    final free = await freeDiskSpace(p.join(vectorsDir, 'segments', 'x'));
    if (free != null && free < requiredBytes(m)) {
      throw VectorsException('אין מספיק מקום פנוי בכונן של אוצריא. דרושים כ-${(requiredBytes(m) / (1 << 30)).toStringAsFixed(1)}GB.');
    }

    // 3. פריסה ל-tmp ואימות.
    final segDir = Directory(p.join(vectorsDir, 'segments'));
    await segDir.create(recursive: true);
    final tmp = File(p.join(segDir.path, 'personal-vectors.oxv.tmp'));
    final finalFile = File(p.join(segDir.path, '${m.segment.id}.oxv'));
    Directory? gdir;
    var moved = false;
    var pointerTouched = false;
    try {
      if (await tmp.exists()) await tmp.delete();
      final r = await zstdDecompressFiles(sources, tmp.path,
          onProgress: (d, t) => onProgress?.call('פורס את הוקטורים', d, t), isCancelled: cancelled);
      check();
      if (r.size != m.segment.size || r.sha256 != m.segment.sha256) {
        throw VectorsException('הוקטורים אחרי הפריסה אינם תואמים למניפסט (גודל או sha256).');
      }
      final h = await readOxvHeader(tmp.path);
      if (h.id != m.segment.id || h.identityDigest != live0.doc['identity_digest'] || h.version != oxvSupportedVersion) {
        throw VectorsException('כותרת קובץ הוקטורים אינה תואמת למניפסט או לסט של אוצריא.');
      }
      if (h.slots != m.segment.slots) throw VectorsException('מספר הוקטורים בקובץ שונה מהמניפסט.');

      // 4. נעילה, והרשמה בסט.
      onProgress?.call('רושם את הוקטורים באוצריא', 0, 1);
      final lockFile = await File(p.join(vectorsDir, '.lock')).open(mode: FileMode.append);
      try {
        try {
          await lockFile.lock(FileLock.exclusive);
        } on FileSystemException {
          throw VectorsException('סט הוקטורים נעול: אוצריא מתקינה או מאחדת וקטורים. סגרו אותה ונסו שוב.');
        }
        final live = await LiveVectorSet.load(vectorsDir);
        if (live.generation != live0.generation) throw VectorsException('הסט השתנה במהלך ההתקנה. יש להריץ שוב.');
        if (await finalFile.exists()) await finalFile.delete();
        await tmp.rename(finalFile.path);
        moved = true;

        final gen = await _nextGeneration(vectorsDir);
        gdir = Directory(p.join(vectorsDir, 'gen-${gen.toString().padLeft(6, '0')}'));
        await gdir.create();
        final others = live.segments;
        for (final s in others) {
          for (final k in const ['del', 'links']) {
            final e = s[k];
            if (e is Map && e['file'] is String) {
              final name = p.basename(e['file'] as String);
              await File(p.join(live.genDir, name)).copy(p.join(gdir.path, name));
            }
          }
        }
        final delB = emptyDelBytes(h.slots);
        final linkB = emptyLinksBytes();
        await _writeDurable(p.join(gdir.path, '${m.segment.id}.del'), delB);
        await _writeDurable(p.join(gdir.path, '${m.segment.id}.links'), linkB);

        final libVersion = live.doc['library_version'];
        final pkgs = ((live.doc['identity'] as Map?)?['model'] as Map?)?['query_packages'];
        Object? package;
        if (pkgs is List) {
          for (final x in pkgs) {
            if (x is Map && x['quantization'] == 'fp32') {
              package = x;
              break;
            }
          }
        }
        final ours = <String, dynamic>{
          'id': m.segment.id,
          'file': 'segments/${m.segment.id}.oxv',
          'kind': 'delta',
          'from': libVersion,
          'to': libVersion,
          'sha256': m.segment.sha256,
          'size': m.segment.size,
          'slots': h.slots,
          'provenance': {
            'passage_package': package,
            'worker': {'backend': vectorsWorkerBackend, 'device': 'prebuilt: ${m.runId}'},
          },
          'del': {'file': '${m.segment.id}.del', 'crc32': crcOfBody(delB), 'count': 0},
          'links': {'file': '${m.segment.id}.links', 'crc32': crcOfBody(linkB), 'count': 0},
        };
        final segments = [...others, ours];
        var foreign = 0;
        for (final s in others) {
          foreign += (await readOxvHeader(p.join(vectorsDir, s['file'] as String))).foreign;
        }
        foreign += h.foreign;
        int sum(String k, [String? sub]) => segments.fold<int>(0, (a, s) {
              final v = sub == null ? s[k] : (s[k] as Map?)?[sub];
              return a + (v is int ? v : 0);
            });
        final doc = Map<String, dynamic>.from(live.doc)
          ..['generation'] = gen
          ..['segments'] = segments
          ..['stats'] = {
            'slots': sum('slots'),
            'slots_dead': sum('del', 'count'),
            'foreign': foreign,
            'foreign_unresolved': sum('links', 'count'),
            'bytes': sum('size'),
          }
          ..['created_at'] = DateTime.now().toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
        final raw = utf8.encode(const JsonEncoder.withIndent('  ').convert(doc));
        await _writeDurable(p.join(gdir.path, 'set.json'), raw);
        final pointer = utf8.encode(jsonEncode({
          'generation': gen,
          'set': 'gen-${gen.toString().padLeft(6, '0')}/set.json',
          'set_sha256': sha256.convert(raw).toString(),
        }));
        final oldCurrent = await File(p.join(vectorsDir, 'CURRENT')).readAsBytes();
        pointerTouched = true;
        await _writeDurable(p.join(vectorsDir, 'PREVIOUS'), oldCurrent);
        await _writeDurable(p.join(vectorsDir, 'CURRENT'), pointer);
        return VectorsInstallResult(gen, h.slots);
      } finally {
        try {
          await lockFile.unlock();
        } catch (_) {}
        await lockFile.close();
      }
    } catch (_) {
      // לפני ש-CURRENT הוחלף אין מה לשחזר: מנקים את מה שנוצר.
      try {
        if (await tmp.exists()) await tmp.delete();
        if (!pointerTouched) {
          if (moved && await finalFile.exists()) await finalFile.delete();
          if (gdir != null && await gdir.exists()) await gdir.delete(recursive: true);
        }
      } catch (_) {}
      rethrow;
    }
  }

  static Future<int> _nextGeneration(String vectorsDir) async {
    var maxN = 0;
    await for (final e in Directory(vectorsDir).list()) {
      final n = p.basename(e.path);
      if (e is Directory && n.startsWith('gen-')) {
        final v = int.tryParse(n.substring(4));
        if (v != null && v > maxN) maxN = v;
      }
    }
    for (final name in const ['CURRENT', 'PREVIOUS']) {
      final f = File(p.join(vectorsDir, name));
      if (!await f.exists()) continue;
      try {
        final g = (jsonDecode(utf8.decode(await f.readAsBytes()).replaceFirst('﻿', '')) as Map)['generation'];
        if (g is int && g > maxN) maxN = g;
      } catch (_) {}
    }
    return maxN + 1;
  }

  /// כתיבה עמידה: קובץ זמני, flush, והחלפה.
  static Future<void> _writeDurable(String path, List<int> data) async {
    final tmp = File('$path.tmp');
    final raf = await tmp.open(mode: FileMode.write);
    try {
      await raf.writeFrom(data is Uint8List ? data : Uint8List.fromList(data));
      await raf.flush();
    } finally {
      await raf.close();
    }
    await tmp.rename(path);
  }
}
