import 'dart:ui' show AppExitResponse;

import 'package:books_offline_update/src/controllers/app_controller.dart';
import 'package:books_offline_update/src/screens/app_shell.dart';
import 'package:books_offline_update/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<AppController> pump(WidgetTester t) async {
    final app = AppController();
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('he', 'IL'),
      builder: (context, c) => Directionality(textDirection: TextDirection.rtl, child: c!),
      home: AppShell(controller: app),
    ));
    return app;
  }

  testWidgets('בלי פעולה רצה: יציאה מיידית בלי שאלה', (t) async {
    await pump(t);
    final r = await t.binding.handleRequestAppExit();
    expect(r, AppExitResponse.exit);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('פעולה רצה: נשאלים, ברירת המחדל היא להישאר', (t) async {
    final app = await pump(t);
    app.activity = Activity('מוריד');
    final f = t.binding.handleRequestAppExit();
    await t.pump();
    expect(find.text('יש פעולה בעיצומה. לסגור בכל זאת?'), findsOneWidget);
    await t.tap(find.text('להישאר'));
    await t.pump();
    expect(await f, AppExitResponse.cancel);

    final f2 = t.binding.handleRequestAppExit();
    await t.pump();
    await t.tap(find.text('לסגור בכל זאת'));
    await t.pump();
    expect(await f2, AppExitResponse.exit);
  });
}
