import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:books_offline_update/src/db/db_manifest.dart';
import 'package:books_offline_update/src/db/db_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('manifest', () {
    final bytes = File('test/fixtures/manifest.json').readAsBytesSync();
    final sig = File('test/fixtures/manifest.json.sig').readAsStringSync();

    test('חתימה אמיתית מאומתת', () {
      expect(verifyManifestSignature(bytes, sig), isTrue);
    });

    test('מניפסט ששונה נדחה', () {
      final tampered = Uint8List.fromList(bytes)..[100] ^= 1;
      expect(verifyManifestSignature(tampered, sig), isFalse);
      expect(verifyManifestSignature(bytes, 'AAAA'), isFalse);
    });

    test('פענוח המניפסט', () {
      final m = DbManifest.parse(bytes);
      expect(m.libraryId, dbLibraryId);
      expect(m.version, 6);
      expect(m.full.parts.single.fileName, 'otzarya-unofficial-books-6.db.zst');
      expect(m.deltas.map((d) => d.fromVersion), [5, 4]);
      expect(m.deltaForVersion(5)!.isDelta, isTrue);
    });

    test('שם קובץ מסוכן נדחה', () {
      final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      (j['full']['parts'] as List)[0]['url'] = 'https://example.com/a/..%5Cx';
      expect(() => DbManifest.parse(utf8.encode(jsonEncode(j))), throwsA(isA<DbManifestException>()));
    });
  });

  // בדיקת התקנה אמיתית מול zstd.exe: דורשת ZSTD_EXE ו-ZSTD_LIB_PATH (ה-DLL של הפלאגין).
  final exe = Platform.environment['ZSTD_EXE'];
  final lib = Platform.environment['ZSTD_LIB_PATH'];
  group('install', () {
    late Directory tmp;
    late String oldDb, newDb;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dbtest');
      final rnd = Random(7);
      final base = Uint8List.fromList(List.generate(6 << 20, (_) => rnd.nextInt(256)));
      final more = Uint8List.fromList(List.generate(1 << 20, (_) => rnd.nextInt(256)));
      oldDb = p.join(tmp.path, 'old.db');
      newDb = p.join(tmp.path, 'new.db');
      File(oldDb).writeAsBytesSync(base);
      final changed = Uint8List.fromList(base)..fillRange(1000, 5000, 9);
      File(newDb).writeAsBytesSync([...changed, ...more]);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    String sha(String path) => sha256.convert(File(path).readAsBytesSync()).toString();

    DbArtifact artifactOf(String zst, String result, {String? fromSha, bool delta = false}) {
      final bytes = File(zst).readAsBytesSync();
      // מפצלים לשני חלקים כדי לבדוק גם איחוד חלקים.
      final cut = bytes.length ~/ 2;
      final parts = <DbPart>[];
      for (final (i, chunk) in [bytes.sublist(0, cut), bytes.sublist(cut)].indexed) {
        final name = 'x.zst.part${i + 1}';
        File(p.join(tmp.path, 'mirror', name))
          ..createSync(recursive: true)
          ..writeAsBytesSync(chunk);
        parts.add(DbPart(url: 'https://example.com/$name', size: chunk.length, sha256: sha256.convert(chunk).toString()));
      }
      return DbArtifact(
        compression: delta ? 'zstd-patch' : 'zstd',
        size: File(result).lengthSync(),
        sha256: sha(result),
        parts: parts,
        fromVersion: delta ? 1 : null,
        fromSha256: fromSha,
      );
    }

    test('עדכון בקובץ patch והתקנה מלאה', () async {
      final full = p.join(tmp.path, 'full.zst');
      final patch = p.join(tmp.path, 'patch.zst');
      expect(Process.runSync(exe!, ['-q', '-f', '-3', newDb, '-o', full]).exitCode, 0);
      expect(Process.runSync(exe, ['-q', '-f', '--patch-from=$oldDb', '--long=31', '--ultra', '-19', newDb, '-o', patch]).exitCode, 0);

      final svc = DbService();
      final mirror = p.join(tmp.path, 'mirror');

      // patch על מסד קיים
      final target = p.join(tmp.path, 'target.db');
      File(oldDb).copySync(target);
      final d = artifactOf(patch, newDb, fromSha: sha(oldDb), delta: true);
      await svc.install(d, mirror, target, onProgress: (_, _, _) {}, isCancelled: () => false);
      expect(sha(target), sha(newDb));
      expect(File('$target.new').existsSync(), isFalse);
      expect(File('$target.old').existsSync(), isFalse);

      // מלא למסד חדש
      final fresh = p.join(tmp.path, 'sub', 'fresh.db');
      final f = artifactOf(full, newDb);
      await svc.install(f, mirror, fresh, onProgress: (_, _, _) {}, isCancelled: () => false);
      expect(sha(fresh), sha(newDb));

      // patch מול מסד בסיס שגוי: נכשל והמסד לא משתנה
      final wrong = p.join(tmp.path, 'wrong.db');
      File(newDb).copySync(wrong);
      final before = sha(wrong);
      await expectLater(
        svc.install(d, mirror, wrong, onProgress: (_, _, _) {}, isCancelled: () => false),
        throwsA(anything),
      );
      expect(sha(wrong), before);
      expect(File('$wrong.new').existsSync(), isFalse);

      svc.close();
    }, skip: exe == null || lib == null ? 'חסרים ZSTD_EXE / ZSTD_LIB_PATH' : false);
  });
}
