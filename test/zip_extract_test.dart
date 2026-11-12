import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:books_offline_update/src/pak/zip_reader.dart' show safeZipPath;
import 'package:books_offline_update/src/services/zip_extract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final bs = String.fromCharCode(92);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('zipx'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String zipOf(Map<String, String> files) {
    final ar = Archive();
    files.forEach((name, text) => ar.addFile(ArchiveFile.bytes(name, utf8.encode(text))));
    final path = p.join(tmp.path, 't.zip');
    File(path).writeAsBytesSync(ZipEncoder().encode(ar));
    return path;
  }

  test('חילוץ לפי סדרים, וקבצים קיימים מדולגים', () async {
    final z = zipOf({'סדר זרעים/ברכות - וגשל.pdf': 'a' * 5000, 'סדר מועד/שבת - וגשל.pdf': 'b' * 3000});
    final dest = p.join(tmp.path, 'תלמוד בבלי');
    expect(await extractZipTo(z, dest), 2);
    expect(File(p.join(dest, 'סדר זרעים', 'ברכות - וגשל.pdf')).readAsStringSync(), 'a' * 5000);
    expect(File(p.join(dest, 'סדר מועד', 'שבת - וגשל.pdf')).lengthSync(), 3000);
    expect(await extractZipTo(z, dest), 0);
    expect(Directory(dest).listSync(recursive: true).any((e) => e.path.endsWith('.part')), isFalse);
  });

  test('נתיבים מסוכנים נדחים', () {
    expect(isSafeZipName('../x.txt'), isFalse);
    expect(isSafeZipName('a/../../x'), isFalse);
    expect(isSafeZipName('/etc/x'), isFalse);
    expect(isSafeZipName('C:/x'), isFalse);
    expect(isSafeZipName('a${bs}b'), isTrue); // backslash נחשב מפריד
    expect(isSafeZipName('a$bs..${bs}x'), isFalse);
    expect(isSafeZipName('${bs}abs'), isFalse);
    expect(isSafeZipName('a/NUL'), isFalse);
    expect(isSafeZipName('con.txt'), isFalse);
    expect(isSafeZipName('LPT1'), isFalse);
    expect(isSafeZipName('a/b.txt:stream'), isFalse);
    expect(isSafeZipName('a/b.'), isFalse);
    expect(isSafeZipName('a /b'), isFalse);
    expect(isSafeZipName('console/x.txt'), isTrue);
    expect(safeZipPath('סדר$bsברכות.pdf'), 'סדר/ברכות.pdf');
    expect(isSafeZipName('סדר זרעים/ברכות.pdf'), isTrue);
  });

  test('ארכיון עם נתיב מסוכן נכשל ואינו כותב מחוץ ליעד', () async {
    final z = zipOf({'../evil.txt': 'x'});
    await expectLater(extractZipTo(z, p.join(tmp.path, 'out')), throwsA(isA<FormatException>()));
    expect(File(p.join(tmp.path, 'evil.txt')).existsSync(), isFalse);
  });

  test('קובץ קיים באותו גודל אבל תוכן שונה נכתב מחדש (CRC)', () async {
    final z = zipOf({'a/x.txt': 'hello world'});
    final dest = p.join(tmp.path, 'out');
    await extractZipTo(z, dest);
    final f = File(p.join(dest, 'a', 'x.txt'));
    f.writeAsStringSync('HELLO WORLD'); // אותו גודל
    expect(await extractZipTo(z, dest), 1);
    expect(f.readAsStringSync(), 'hello world');
  });

  test('שם עם backslash מחולץ בלי להפיל את החילוץ', () async {
    final z = zipOf({'a${bs}b.txt': 'x'});
    final dest = p.join(tmp.path, 'out2');
    expect(await extractZipTo(z, dest), 1);
    expect(File(p.join(dest, 'a', 'b.txt')).existsSync(), isTrue);
  });
}
