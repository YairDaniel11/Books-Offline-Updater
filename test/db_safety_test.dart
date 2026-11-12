import 'dart:io';

import 'package:books_offline_update/src/db/db_service.dart';
import 'package:books_offline_update/src/services/disk_space.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('זיהוי קובץ SQLite לפי כותרת: חסר וריק תקינים, קובץ אחר נדחה', () async {
    final d = Directory.systemTemp.createTempSync('sq');
    try {
      final missing = p.join(d.path, 'none.db');
      expect(await DbService.looksLikeSqlite(missing), isTrue);

      final empty = File(p.join(d.path, 'empty.db'))..writeAsBytesSync([]);
      expect(await DbService.looksLikeSqlite(empty.path), isTrue);

      final good = File(p.join(d.path, 'good.db'))
        ..writeAsBytesSync([...'SQLite format 3\u0000'.codeUnits, ...List.filled(100, 7)]);
      expect(await DbService.looksLikeSqlite(good.path), isTrue);

      final text = File(p.join(d.path, 'doc.txt'))..writeAsStringSync('hello world, this is not a database at all');
      expect(await DbService.looksLikeSqlite(text.path), isFalse);

      final tiny = File(p.join(d.path, 'tiny.db'))..writeAsStringSync('abc');
      expect(await DbService.looksLikeSqlite(tiny.path), isFalse);
    } finally {
      d.deleteSync(recursive: true);
    }
  });

  test('פענוח פלט df -k', () {
    const out = 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
        '/dev/disk3s1 488245288 300000000 150000 67% /\n';
    expect(parseDfKilobytes(out), 150000 * 1024);
    expect(parseDfKilobytes('garbage'), isNull);
  });

  test('בדיקת מקום פנוי בכונן אמיתי מחזירה מספר חיובי (או null בלי לקרוס)', () async {
    final free = await freeDiskSpace(p.join(Directory.systemTemp.path, 'x.db'));
    if (free != null) expect(free, greaterThan(0));
  });
}
