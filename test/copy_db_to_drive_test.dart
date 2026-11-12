import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:books_offline_update/src/controllers/app_controller.dart';
import 'package:books_offline_update/src/db/db_controller.dart';
import 'package:books_offline_update/src/db/db_manifest.dart';
import 'package:books_offline_update/src/db/db_service.dart';
import 'package:books_offline_update/src/screens/prepare_screen.dart';
import 'package:books_offline_update/src/theme/app_theme.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// העתקת המסד העדכני לדיסק און קי, והתקנה ממנו במחשב השני.
void main() {
  late Directory tmp;
  late Uint8List dbBytes;
  late String dbSha;
  late DbRelease release;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('copydb');
    dbBytes = Uint8List.fromList(List.generate(300000, (i) => (i * 7 + 3) % 251));
    dbSha = sha256.convert(dbBytes).toString();
    final j = {
      'format': 1,
      'library_id': dbLibraryId,
      'db_version': 44,
      'full': {
        'compression': 'zstd',
        'size': dbBytes.length,
        'sha256': dbSha,
        'parts': [
          {'url': 'https://example.com/x.db.zst', 'size': 10, 'sha256': 'a' * 64},
        ],
      },
      'delta': [],
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(j)));
    release = DbRelease(bytes, 'SIGTEXT', DbManifest.parse(bytes));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File writeSrc() => File(p.join(tmp.path, 'src', 'books.db'))
    ..createSync(recursive: true)
    ..writeAsBytesSync(dbBytes);

  group('העתקה לכונן', () {
    test('מעתיק, מאמת וכותב מניפסט; אין קבצים זמניים', () async {
      final src = writeSrc();
      final dest = p.join(tmp.path, 'usb', dbMirrorDirName);
      final svc = DbService();
      var last = 0.0;
      await svc.copyRawDb(release, src.path, dest,
          onProgress: (d, t, _) => last = t == null ? 0 : d / t, isCancelled: () => false);
      final raw = File(p.join(dest, DbService.rawDbFileName(release.manifest.full)));
      expect(sha256.convert(raw.readAsBytesSync()).toString(), dbSha);
      expect(File(p.join(dest, manifestFileName)).readAsBytesSync(), release.manifestBytes);
      expect(File(p.join(dest, manifestSigFileName)).readAsStringSync(), 'SIGTEXT');
      expect(Directory(dest).listSync().where((e) => e.path.endsWith('.part') || e.path.endsWith('.tmp')), isEmpty);
      expect(last, closeTo(1.0, 0.01));

      // קובץ זהה שכבר שם: לא נכתב מחדש
      final before = raw.statSync().modified;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await svc.copyRawDb(release, src.path, dest, onProgress: (_, _, _) {}, isCancelled: () => false);
      expect(raw.statSync().modified, before);
      svc.close();
    });

    test('ביטול באמצע: לא נשאר קובץ חלקי ולא מניפסט', () async {
      final src = writeSrc();
      final dest = p.join(tmp.path, 'usb');
      final svc = DbService();
      await expectLater(
        svc.copyRawDb(release, src.path, dest, onProgress: (_, _, _) {}, isCancelled: () => true),
        throwsA(anything),
      );
      expect(Directory(dest).listSync(), isEmpty);
      svc.close();
    });

    test('מקור שאינו תואם לגרסה נדחה', () async {
      final src = File(p.join(tmp.path, 'bad.db'))..writeAsBytesSync(dbBytes.sublist(0, 1000));
      final svc = DbService();
      await expectLater(
          svc.copyRawDb(release, src.path, p.join(tmp.path, 'usb'), onProgress: (_, _, _) {}, isCancelled: () => false),
          throwsA(isA<DbException>()));
      svc.close();
    });

    test('מקור באותו גודל אך תוכן שונה: ההעתקה נכשלת ולא נשאר קובץ', () async {
      final bad = Uint8List.fromList(dbBytes)..[5] ^= 1;
      final src = File(p.join(tmp.path, 'bad.db'))..writeAsBytesSync(bad);
      final dest = p.join(tmp.path, 'usb');
      final svc = DbService();
      await expectLater(
          svc.copyRawDb(release, src.path, dest, onProgress: (_, _, _) {}, isCancelled: () => false),
          throwsA(isA<DbException>()));
      expect(Directory(dest).listSync(), isEmpty);
      svc.close();
    });
  });

  group('התקנה מקובץ מסד גולמי במראה', () {
    Future<String> prepareMirror({bool corrupt = false}) async {
      final dest = p.join(tmp.path, 'usb', dbMirrorDirName);
      Directory(dest).createSync(recursive: true);
      final b = Uint8List.fromList(dbBytes);
      if (corrupt) b[10] ^= 1;
      File(p.join(dest, DbService.rawDbFileName(release.manifest.full))).writeAsBytesSync(b);
      return dest;
    }

    test('מתקבל כמסד מלא ומותקן', () async {
      final mirror = await prepareMirror();
      final full = release.manifest.full;
      expect(DbService.isComplete(full, mirror), isFalse);
      expect(DbService.fullAvailable(full, mirror), isTrue);
      final target = p.join(tmp.path, 'target', 'books.db');
      final svc = DbService();
      await svc.install(full, mirror, target, onProgress: (_, _, _) {}, isCancelled: () => false);
      expect(sha256.convert(File(target).readAsBytesSync()).toString(), dbSha);
      expect(File('$target.new').existsSync(), isFalse);
      svc.close();
    });

    test('SHA שגוי: נדחה והמסד הקיים לא משתנה', () async {
      final mirror = await prepareMirror(corrupt: true);
      final target = p.join(tmp.path, 'target', 'books.db');
      File(target)
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      final svc = DbService();
      await expectLater(
        svc.install(release.manifest.full, mirror, target, onProgress: (_, _, _) {}, isCancelled: () => false),
        throwsA(isA<DbException>()),
      );
      expect(File(target).readAsStringSync(), 'old');
      expect(File('$target.new').existsSync(), isFalse);
      svc.close();
    });

    test('תוכנית ההתקנה בבקר מזהה את הקובץ הגולמי', () async {
      final mirror = await prepareMirror();
      final db = DbController(AppController());
      db.mirror = release;
      db.mirrorDir = mirror;
      db.targetDb = p.join(tmp.path, 'target', 'books.db');
      expect(db.plan!.action, InstallAction.full);
      File(p.join(mirror, DbService.rawDbFileName(release.manifest.full))).deleteSync();
      expect(db.plan!.action, InstallAction.blocked);
    });
  });

  group('מתי מוצג כפתור ההעתקה', () {
    late DbController db;
    late File mine;
    setUp(() {
      db = DbController(AppController());
      db.remote = release;
      mine = File(p.join(tmp.path, 'mine.db'))..writeAsBytesSync(dbBytes);
      db.targetDb = mine.path;
    });

    test('מסד המחשב הזה עדכני: מועתק', () {
      db.local = LocalDbInfo(dbSha, LocalDbState.current, version: 44);
      expect(db.latestDbToCopy(fromLocal: true, fromDetected: false), mine.path);
      expect(db.latestDbToCopy(fromLocal: false, fromDetected: false), isNull);
    });

    test('מסד המחשב הזה ישן: אין העתקה', () {
      db.local = LocalDbInfo('x', LocalDbState.hasDelta, version: 40);
      expect(db.latestDbToCopy(fromLocal: true, fromDetected: true), isNull);
    });

    test('עותק שנבחר וזוהה כעדכני', () {
      final other = File(p.join(tmp.path, 'other.db'))..writeAsBytesSync(dbBytes);
      db.detectedCurrentPath = other.path;
      expect(db.latestDbToCopy(fromLocal: false, fromDetected: true), other.path);
      expect(db.latestDbToCopy(fromLocal: false, fromDetected: false), isNull);
      db.clearTransferVersion();
      expect(db.latestDbToCopy(fromLocal: false, fromDetected: true), isNull);
    });
  });

  group('מסך ההכנה', () {
    Widget host(Widget c) => MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('he', 'IL'),
          builder: (context, c) => Directionality(textDirection: TextDirection.rtl, child: c!),
          home: Scaffold(body: c),
        );

    testWidgets('מסד עדכני: אין הורדה, יש כפתור העתקה', (t) async {
      final mine = File(p.join(tmp.path, 'mine.db'))..writeAsBytesSync(dbBytes);
      final db = DbController(AppController())
        ..remote = release
        ..targetDb = mine.path
        ..local = LocalDbInfo(dbSha, LocalDbState.current, version: 44);
      await t.binding.setSurfaceSize(const Size(1200, 1000));
      await t.pumpWidget(host(PrepareScreen(db: db)));
      expect(find.text('העתקת המסד לדיסק און קי'), findsOneWidget);
      expect(find.textContaining('הורדה והכנת הקבצים'), findsNothing);
      // אפשרות "יש לי עותק" בלי עותק שזוהה: ההורדה הרגילה נשארת
      await t.tap(find.text('יש לי עותק של המסד שלו'));
      await t.pump();
      expect(find.text('העתקת המסד לדיסק און קי'), findsNothing);
      expect(find.textContaining('הורדה והכנת הקבצים'), findsOneWidget);
    });

    testWidgets('מסד ישן: ההורדה הרגילה בלבד', (t) async {
      final mine = File(p.join(tmp.path, 'mine.db'))..writeAsBytesSync(dbBytes);
      final db = DbController(AppController())
        ..remote = release
        ..targetDb = mine.path
        ..local = LocalDbInfo('x', LocalDbState.unknown);
      await t.binding.setSurfaceSize(const Size(1200, 1000));
      await t.pumpWidget(host(PrepareScreen(db: db)));
      expect(find.text('העתקת המסד לדיסק און קי'), findsNothing);
      expect(find.textContaining('הורדה והכנת הקבצים'), findsOneWidget);
    });
  });
}
