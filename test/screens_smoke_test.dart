import 'package:books_offline_update/src/controllers/app_controller.dart';
import 'package:books_offline_update/src/db/db_controller.dart';
import 'package:books_offline_update/src/screens/db_screen.dart';
import 'package:books_offline_update/src/screens/home_screen.dart';
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

  testWidgets('דף הבית', (t) async {
    await t.binding.setSurfaceSize(const Size(1200, 900));
    await t.pumpWidget(host(HomeScreen(controller: app, db: db, onNavigate: (_) {})));
    expect(find.textContaining('מסד ספרים מותאמים לאוצריא'), findsOneWidget);
    expect(find.textContaining('ספרים בודדים (TXT)'), findsOneWidget);
  });

  testWidgets('לשונית המסד: פרטים טכניים סגורים כברירת מחדל', (t) async {
    await t.binding.setSurfaceSize(const Size(1200, 1400));
    await t.pumpWidget(host(DbScreen(db: db, app: app)));
    expect(find.text('מחשב בלי אינטרנט'), findsOneWidget);
    expect(find.text('פרטים טכניים'), findsOneWidget);
    expect(find.text('תיקיית קבצי המסד'), findsNothing); // מוסתר עד שפותחים
    await t.tap(find.text('פרטים טכניים'));
    await t.pumpAndSettle();
    expect(find.text('תיקיית קבצי המסד'), findsOneWidget);
  });

  testWidgets('הגדרות', (t) async {
    await t.binding.setSurfaceSize(const Size(1200, 1400));
    await t.pumpWidget(host(SettingsScreen(controller: app, update: UpdateController())));
    expect(find.textContaining('למתקדמים'), findsOneWidget);
  });
}
