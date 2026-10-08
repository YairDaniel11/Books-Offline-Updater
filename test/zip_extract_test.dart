import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:books_offline_update/src/services/zip_extract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
    expect(isSafeZipName('a${String.fromCharCode(92)}b'), isFalse);
    expect(isSafeZipName('סדר זרעים/ברכות.pdf'), isTrue);
  });

  test('ארכיון עם נתיב מסוכן נכשל ואינו כותב מחוץ ליעד', () async {
    final z = zipOf({'../evil.txt': 'x'});
    await expectLater(extractZipTo(z, p.join(tmp.path, 'out')), throwsA(isA<FormatException>()));
    expect(File(p.join(tmp.path, 'evil.txt')).existsSync(), isFalse);
  });
}
