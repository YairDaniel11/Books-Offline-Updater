import 'dart:io';

import 'package:books_offline_update/src/services/single_instance.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('מופע שני לא מקבל נעילה, ואחרי שחרור כן', () async {
    final d = Directory.systemTemp.createTempSync('si');
    try {
      final path = p.join(d.path, 'app.lock');
      final a = await SingleInstance.acquire(path);
      expect(a, isNotNull);
      expect(await SingleInstance.acquire(path), isNull);
      await a!.release();
      final c = await SingleInstance.acquire(path);
      expect(c, isNotNull);
      await c!.release();
    } finally {
      d.deleteSync(recursive: true);
    }
  },
      // ב-Mac נעילת fcntl היא לפי תהליך: ניסיון שני באותו תהליך מצליח, ורק תהליך אחר נחסם.
      // הבדיקה הזו מייצגת רק מערכות שבהן הנעילה היא לפי קובץ פתוח (Windows).
      skip: Platform.isMacOS ? 'נעילת fcntl לפי תהליך: לא ניתנת לבדיקה בתוך תהליך אחד' : null);
}
