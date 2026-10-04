import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:books_offline_update/src/pak/pak_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String zipPath;
  late Map<String, Uint8List> expected;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pak_test');
    final big = utf8.encode('שלום עולם, זהו טקסט חוזר לבדיקה.\n' * 90000);
    expected = {
      'ספר א.txt': Uint8List.fromList(utf8.encode('בראשית ברא אלהים')),
      'תת/ספר ב.txt': Uint8List.fromList(big),
      'ריק.txt': Uint8List(0),
    };
    final ar = Archive();
    expected.forEach((k, v) => ar.add(ArchiveFile(k, v.length, v)));
    final bytes = ZipEncoder().encode(ar);
    zipPath = p.join(tmp.path, 'in.zip');
    await File(zipPath).writeAsBytes(bytes);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<PakFile> build(String pakPath) async {
    final pak = await PakFile.openOrCreate(pakPath);
    await pak.ingestZip(zipPath, 'תיקייה');
    await pak.commit();
    return pak;
  }

  test('ingest, commit, פתיחה מחדש וחילוץ', () async {
    final pakPath = p.join(tmp.path, 'a.pak');
    await (await build(pakPath)).close();
    final pak = await PakFile.openOrCreate(pakPath, allowCreate: false);
    expect(pak.files.keys.toSet(), expected.keys.map((k) => 'תיקייה/$k').toSet());
    final out = p.join(tmp.path, 'out');
    for (final e in pak.files.entries) {
      await pak.extractTo(e.value, p.join(out, e.key));
    }
    for (final e in expected.entries) {
      final got = await File(p.join(out, 'תיקייה', e.key)).readAsBytes();
      expect(got, e.value, reason: e.key);
    }
    await pak.close();
  });

  test('ingest חוזר לא מגדיל את הקובץ (dedupe)', () async {
    final pak = await build(p.join(tmp.path, 'b.pak'));
    final len = pak.fileLength;
    final first = pak.files.length;
    await pak.ingestZip(zipPath, 'תיקייה');
    expect(pak.files.length, first);
    expect(pak.fileLength, len);
    await pak.close();
  });

  test('pruneUnder ו-compact', () async {
    final pakPath = p.join(tmp.path, 'c.pak');
    var pak = await build(pakPath);
    final keepPath = 'תיקייה/ספר א.txt';
    final gone = pak.pruneUnder('תיקייה', {keepPath});
    expect(gone.length, 2);
    expect(pak.files.keys, [keepPath]);
    await pak.commit();
    expect(pak.deadBytes, greaterThan(0));
    await pak.compact(); // ה-instance נסגר בתוך compact
    pak = await PakFile.openOrCreate(pakPath);
    expect(pak.deadBytes, 0);
    final out = p.join(tmp.path, 'x.txt');
    await pak.extractTo(pak.files[keepPath]!, out);
    expect(await File(out).readAsBytes(), expected['ספר א.txt']);
    await pak.close();
  });

  test('CRC שגוי נתפס', () async {
    final pak = await build(p.join(tmp.path, 'd.pak'));
    final e = pak.files['תיקייה/ספר א.txt']!;
    final bad = PakEntry(
      offset: e.offset,
      compressedSize: e.compressedSize,
      size: e.size,
      method: e.method,
      crc: e.crc ^ 1,
      version: e.version,
    );
    await expectLater(pak.extractTo(bad, p.join(tmp.path, 'bad.txt')), throwsFormatException);
    await pak.close();
  });

  test('אינדקס אחרון פגום: חוזרים לאינדקס התקין הקודם', () async {
    final pakPath = p.join(tmp.path, 'e.pak');
    final pak = await build(pakPath);
    final fullCount = pak.files.length;
    await pak.close();
    final bytes = await File(pakPath).readAsBytes();
    final bd = ByteData.sublistView(bytes);
    final idx = bd.getUint64(bytes.length - 32 + 8, Endian.little);
    bytes[idx + 10] ^= 0xFF;
    await File(pakPath).writeAsBytes(bytes);
    // האינדקס האחרון פגום, ולכן נטען האינדקס הקודם (הריק מיצירת הקובץ) — בלי קריסה ובלי נתונים שגויים.
    final reopened = await PakFile.openOrCreate(pakPath);
    expect(reopened.files.length, lessThan(fullCount));
    await reopened.close();
  });

  test('כל האינדקסים פגומים זורק FormatException', () async {
    final pakPath = p.join(tmp.path, 'g.pak');
    final pak = await build(pakPath);
    await pak.close();
    final bytes = await File(pakPath).readAsBytes();
    // משבשים כל מופע של ה-magic של הזנב.
    final magic = 'OTZPAKFT'.codeUnits;
    for (var i = 0; i + magic.length <= bytes.length; i++) {
      var m = true;
      for (var k = 0; k < magic.length; k++) {
        if (bytes[i + k] != magic[k]) {
          m = false;
          break;
        }
      }
      if (m) bytes[i] = 0;
    }
    await File(pakPath).writeAsBytes(bytes);
    await expectLater(PakFile.openOrCreate(pakPath), throwsFormatException);
  });

  test('קובץ שאינו PAK זורק FormatException', () async {
    final f = p.join(tmp.path, 'f.pak');
    await File(f).writeAsBytes(List.filled(100, 7));
    await expectLater(PakFile.openOrCreate(f), throwsFormatException);
  });
}
