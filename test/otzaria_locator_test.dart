import 'dart:convert';
import 'dart:io';

import 'package:books_offline_update/src/services/otzaria_locator.dart';
import 'package:hive_ce/hive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// צירוף המסד לאוצריא: נכתב לקופסת ההגדרות, נקרא בחזרה, ונשמר שאר התוכן.
void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('otz-root-'));
  tearDown(() async => root.delete(recursive: true));

  test('קופסה חדשה: צירוף ואז איתור', () async {
    final db = p.join(root.path, 'מסדים אישיים', 'otzarya-unofficial-books.db');
    expect(await OtzariaLocator.findDbPath(root: root.path), isNull);
    expect(await OtzariaLocator.attach(db, root: root.path), isTrue);
    expect(await OtzariaLocator.findDbPath(root: root.path), db);
  });

  test('קופסה אמיתית (עותק): הנתיב מתעדכן והשדות הקיימים נשמרים', () async {
    final real = File(p.join(Platform.environment['APPDATA'] ?? '', 'otzaria', 'app_preferences.hive'));
    if (!real.existsSync()) return;
    await real.copy(p.join(root.path, 'app_preferences.hive'));
    final before = await OtzariaLocator.findDbPath(root: root.path);
    expect(before, isNotNull);
    expect(await OtzariaLocator.attach(r'C:\x\otzarya-unofficial-books.db', root: root.path), isTrue);
    expect(await OtzariaLocator.findDbPath(root: root.path), r'C:\x\otzarya-unofficial-books.db');
    final text = String.fromCharCodes(await File(p.join(root.path, 'app_preferences.hive')).readAsBytes());
    expect(text.contains('updateSource'), isTrue);
    expect(text.contains('key-library-path'), isTrue);
  });

  Future<void> seed(Object? value) async {
    Hive.init(root.path);
    final box = await Hive.openBox<dynamic>('app_preferences', path: root.path);
    await box.put('key-attached-libraries', value);
    await box.put('other', 'keep');
    await box.close();
  }

  test('מבנה לא צפוי ברשימת הספריות: לא כותבים ולא מוחקים דבר', () async {
    await seed('{"not":"a list"}');
    final before = await File(p.join(root.path, 'app_preferences.hive')).readAsBytes();
    expect(await OtzariaLocator.attach(p.join(root.path, 'x.db'), root: root.path), isFalse);
    expect(await File(p.join(root.path, 'app_preferences.hive')).readAsBytes(), before);
  });

  test('ספריות קיימות (גם ערכים לא צפויים) נשמרות, ונוצר גיבוי חד-פעמי', () async {
    await seed(jsonEncode([
      {'slug': 'mine', 'path': 'C:/m.db', 'priority': 3},
      'weird',
    ]));
    final db = p.join(root.path, 'x.db');
    expect(await OtzariaLocator.attach(db, root: root.path), isTrue);
    expect(await OtzariaLocator.findDbPath(root: root.path), db);
    Hive.init(root.path);
    final box = await Hive.openBox<dynamic>('app_preferences', path: root.path);
    final list = jsonDecode(box.get('key-attached-libraries') as String) as List;
    expect(box.get('other'), 'keep');
    await box.close();
    expect(list.length, 3);
    expect(list.contains('weird'), isTrue);
    expect((list.first as Map)['slug'], 'mine');
    expect(File(p.join(root.path, 'app_preferences.hive.books-update.bak')).existsSync(), isTrue);
    expect(File(p.join(root.path, 'app_preferences.hive.books-update.tmp')).existsSync(), isFalse);
  });
}
