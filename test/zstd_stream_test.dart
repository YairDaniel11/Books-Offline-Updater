import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:books_offline_update/src/db/zstd_stream.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final exe = Platform.environment['ZSTD_EXE'];
  final lib = Platform.environment['ZSTD_LIB_PATH'];
  final skip = exe == null || lib == null ? 'חסרים ZSTD_EXE / ZSTD_LIB_PATH' : false;

  late Directory tmp;
  late String oldDb, newDb, patch;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zstdtest');
    final rnd = Random(11);
    Uint8List rand(int n) => Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256)));
    final base = rand(12 << 20);
    final changed = Uint8List.fromList(base)
      ..fillRange(1000, 90000, 9)
      ..setRange(5 << 20, (5 << 20) + 4096, rand(4096));
    oldDb = p.join(tmp.path, 'old.db');
    newDb = p.join(tmp.path, 'new.db');
    patch = p.join(tmp.path, 'x.patch.zst');
    File(oldDb).writeAsBytesSync(base);
    File(newDb).writeAsBytesSync([...changed, ...rand(1 << 20)]);
    final r = Process.runSync(exe ?? 'zstd', ['--patch-from=$oldDb', '--long=31', '-3', '-q', newDb, '-o', patch]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  String sha(String path) => sha256.convert(File(path).readAsBytesSync()).toString();

  test('עדכון patch-from: תוצאה זהה בית-בית (פלט וסיומת ממופים)', () async {
    final out = p.join(tmp.path, 'out.db');
    var last = 0;
    final r = await zstdDecompressFiles([patch], out, prefixPath: oldDb, onProgress: (d, _) => last = d);
    expect(r.size, File(newDb).lengthSync());
    expect(r.sha256, sha(newDb));
    expect(sha(out), sha(newDb));
    expect(last, File(patch).lengthSync());
    // הקבצים משוחררים: אפשר למחוק ולהחליף מיד.
    File(oldDb).deleteSync();
    File(out).renameSync(p.join(tmp.path, 'renamed.db'));
  }, skip: skip);

  test('patch שחולק לחלקים', () async {
    final bytes = File(patch).readAsBytesSync();
    final a = p.join(tmp.path, 'a.part1'), b = p.join(tmp.path, 'a.part2');
    File(a).writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 3));
    File(b).writeAsBytesSync(bytes.sublist(bytes.length ~/ 3));
    final r = await zstdDecompressFiles([a, b], p.join(tmp.path, 'o.db'), prefixPath: oldDb);
    expect(r.sha256, sha(newDb));
  }, skip: skip);

  test('patch קטוע נדחה', () async {
    final bytes = File(patch).readAsBytesSync();
    final cut = p.join(tmp.path, 'cut.zst');
    File(cut).writeAsBytesSync(bytes.sublist(0, bytes.length - 20));
    await expectLater(zstdDecompressFiles([cut], p.join(tmp.path, 'o.db'), prefixPath: oldDb), throwsA(isA<ZstdException>()));
  }, skip: skip);

  test('מסד בסיס שגוי נותן sha שונה', () async {
    final wrong = p.join(tmp.path, 'wrong.db');
    final bytes = File(oldDb).readAsBytesSync()..[3 << 20] ^= 1;
    File(wrong).writeAsBytesSync(bytes);
    try {
      final r = await zstdDecompressFiles([patch], p.join(tmp.path, 'o.db'), prefixPath: wrong);
      expect(r.sha256, isNot(sha(newDb)));
    } on ZstdException {
      // גם דחייה (checksum של zstd) תקינה.
    }
  }, skip: skip);

  test('ביטול באמצע', () async {
    await expectLater(
      zstdDecompressFiles([patch], p.join(tmp.path, 'o.db'), prefixPath: oldDb, isCancelled: () => true),
      throwsA(isA<ZstdException>()),
    );
  }, skip: skip);

  test('דחיסה רגילה בלי prefix', () async {
    final z = p.join(tmp.path, 'plain.zst');
    final r = Process.runSync(exe!, ['-q', newDb, '-o', z]);
    expect(r.exitCode, 0);
    final out = await zstdDecompressFiles([z], p.join(tmp.path, 'plain.db'));
    expect(out.sha256, sha(newDb));
  }, skip: skip);
}
