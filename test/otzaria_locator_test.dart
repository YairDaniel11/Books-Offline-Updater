import 'dart:io';

import 'package:books_offline_update/src/services/otzaria_locator.dart';
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
}
