import 'dart:io';

import 'package:books_offline_update/src/services/copy_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory d;
  setUp(() => d = Directory.systemTemp.createTempSync('ledger'));
  tearDown(() => d.deleteSync(recursive: true));

  test('תיקייה ללא רשימה: אינה מחזיקה בשום קובץ', () async {
    final l = await CopyLedger.load(d.path);
    expect(l.length, 0);
    expect(l.owns('a/b.txt'), isFalse);
  });

  test('שמירה וטעינה חוזרת, והסרה', () async {
    final l = await CopyLedger.load(d.path);
    l.add('ספרים/א.txt');
    l.add('ב.txt');
    await l.save();
    final l2 = await CopyLedger.load(d.path);
    expect(l2.owns('ספרים/א.txt'), isTrue);
    expect(l2.owns('ג.txt'), isFalse);
    l2.remove('ב.txt');
    await l2.save();
    expect((await CopyLedger.load(d.path)).length, 1);
    expect(File(p.join(d.path, '${CopyLedger.fileName}.tmp')).existsSync(), isFalse);
  });

  test('קובץ פגום או נתיבים לא בטוחים מתעלמים מהם', () async {
    File(p.join(d.path, CopyLedger.fileName)).writeAsStringSync('{not json');
    expect((await CopyLedger.load(d.path)).length, 0);
    File(p.join(d.path, CopyLedger.fileName)).writeAsStringSync('{"files":["../x","ok.txt","/abs"]}');
    final l = await CopyLedger.load(d.path);
    expect(l.length, 1);
    expect(l.owns('ok.txt'), isTrue);
  });
}
