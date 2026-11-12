import 'dart:io';
import 'dart:typed_data';

import 'package:books_offline_update/src/controllers/app_controller.dart';
import 'package:books_offline_update/src/db/db_manifest.dart';
import 'package:books_offline_update/src/db/db_service.dart';
import 'package:books_offline_update/src/db/db_controller.dart';
import 'package:books_offline_update/src/screens/copy_screen.dart';
import 'package:books_offline_update/src/screens/db_screen.dart';
import 'package:books_offline_update/src/screens/home_screen.dart';
import 'package:books_offline_update/src/screens/prepare_screen.dart';
import 'package:books_offline_update/src/screens/settings_screen.dart';
import 'package:books_offline_update/src/theme/app_theme.dart';
import 'package:books_offline_update/src/update/app_update.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// בדיקת עשן: המסכים נבנים בלי חריגות במצב ריק (בלי רשת ובלי מאגר).
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('he', 'IL'),
        builder: (context, c) => Directionality(textDirection: TextDirection.rtl, child: c!),
        home: Scaffold(body: child),
      );

  late AppController app;
  late DbController db;
  setUp(() {
    app = AppController();
    db = DbController(app);
  });

  DbRelease release() {
    final bytes = File('test/fixtures/manifest.json').readAsBytesSync();
    return DbRelease(Uint8List.fromList(bytes), '', DbManifest.parse(bytes));
  }

  Future<void> pumpHome(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1200, 1000));
    await t.pumpWidget(host(HomeScreen(controller: app, db: db, onNavigate: (_) {})));
  }

  testWidgets('דף הבית: בלי רשת, כפתור "נסו שוב" והערה על אוצריא', (t) async {
    db.targetDb = '${Directory.systemTemp.path}/no-such-dir/x.db';
    await pumpHome(t);
    expect(find.text('אין חיבור לרשת'), findsWidgets);
    expect(find.text('נסו שוב'), findsOneWidget);
    expect(find.text('מצב העדכונים'), findsOneWidget);
    expect(find.textContaining('לפני שמתחילים, סגור את אוצריא'), findsOneWidget);
    expect(find.textContaining('ספרים בודדים'), findsOneWidget);
    expect(find.text('(DB)'), findsNothing);
  });

  testWidgets('דף הבית: המסד עוד לא מותקן', (t) async {
    db.targetDb = '${Directory.systemTemp.path}/no-such-dir/x.db';
    db.remote = release();
    await pumpHome(t);
    expect(find.text('מסד הספרים עוד לא מותקן'), findsOneWidget);
    expect(find.text('הורדה והתקנה'), findsOneWidget);
    expect(find.text('לפני שמתחילים, סגור את אוצריא.'), findsOneWidget);
  });

  group('דף הבית עם מסד קיים', () {
    late File f;
    setUp(() {
      f = File('${Directory.systemTemp.createTempSync('home').path}/x.db')..writeAsBytesSync([1]);
      db.targetDb = f.path;
      db.remote = release();
    });
    tearDown(() => f.parent.deleteSync(recursive: true));

    testWidgets('יש עדכון', (t) async {
      db.local = LocalDbInfo('x', LocalDbState.hasDelta, version: 4);
      await pumpHome(t);
      expect(find.text('יש עדכון למסד הספרים'), findsOneWidget);
      expect(find.text('עדכן עכשיו'), findsOneWidget);
      expect(find.textContaining('גרסה 4 · יש עדכון'), findsOneWidget);
    });

    testWidgets('הכול מעודכן: בלי כפתור ראשי', (t) async {
      db.local = LocalDbInfo('x', LocalDbState.current, version: 6);
      await pumpHome(t);
      expect(find.text('הכול מעודכן במחשב הזה'), findsOneWidget);
      expect(find.text('עדכן עכשיו'), findsNothing);
      expect(find.text('בדוק שוב'), findsOneWidget);
    });
  });

  testWidgets('הכנה למחשב בלי אינטרנט: שלוש אפשרויות', (t) async {
    await t.binding.setSurfaceSize(const Size(1200, 1000));
    await t.pumpWidget(host(PrepareScreen(db: db)));
    expect(find.text('מה יש במחשב השני?'), findsOneWidget);
    expect(find.text('אין לו מסד ספרים'), findsOneWidget);
    expect(find.text('אני יודע איזו גרסה יש לו'), findsOneWidget);
    expect(find.text('יש לי עותק של המסד שלו'), findsOneWidget);
    await t.tap(find.text('יש לי עותק של המסד שלו'));
    await t.pump();
    expect(find.text('בחירת הקובץ'), findsOneWidget);
  });

  testWidgets('לשונית המסד: פרטים טכניים סגורים כברירת מחדל', (t) async {
    await t.binding.setSurfaceSize(const Size(1200, 1400));
    await t.pumpWidget(host(DbScreen(db: db, app: app)));
    expect(find.text('פרטים טכניים'), findsOneWidget);
    expect(find.text('תיקיית קבצי המסד'), findsNothing); // מוסתר עד שפותחים
    await t.tap(find.text('פרטים טכניים'));
    await t.pumpAndSettle();
    expect(find.text('תיקיית קבצי המסד'), findsOneWidget);
  });

  testWidgets('הגדרות', (t) async {
    await t.binding.setSurfaceSize(const Size(1200, 1400));
    await t.pumpWidget(host(SettingsScreen(controller: app, update: UpdateController(), onLockNow: () {})));
    expect(find.textContaining('למתקדמים'), findsOneWidget);
  });

  testWidgets('העתקת הספרים: כפתור גדול, מושבת כשאין קבצים', (t) async {
    await t.binding.setSurfaceSize(const Size(1200, 1000));
    await t.pumpWidget(host(CopyScreen(db: db, app: app, locked: true)));
    expect(find.text('העתק את הספרים לאוצריא'), findsOneWidget);
    expect(find.text('לא נמצאו קבצי ספרים להעתקה.'), findsOneWidget);
    expect(find.text('קובץ המסד של אוצריא'), findsNothing); // נעול: בלי שינוי מיקומים
  });
}
