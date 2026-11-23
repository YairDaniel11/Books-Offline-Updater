import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:books_offline_update/src/controllers/app_controller.dart';
import 'package:books_offline_update/src/db/db_controller.dart';
import 'package:books_offline_update/src/db/db_manifest.dart';
import 'package:books_offline_update/src/db/db_service.dart';
import 'package:books_offline_update/src/quick/progress_rate.dart';
import 'package:books_offline_update/src/quick/quick_update_controller.dart';
import 'package:books_offline_update/src/quick/quick_update_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _sha(int n) => n.toRadixString(16).padLeft(64, '0');

DbManifest _manifest(int latest, {String? notes}) => DbManifest.parse(
  Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': 1,
        'library_id': dbLibraryId,
        'db_version': latest,
        'release_notes': ?notes,
        'full': {
          'compression': 'zstd',
          'size': 1000,
          'sha256': _sha(latest),
          'parts': [
            {'url': 'https://example.com/$dbLibraryId-$latest.db.zst', 'size': 50, 'sha256': _sha(9999)},
          ],
        },
        'delta': [],
      }),
    ),
  ),
);

DbRelease _release(DbManifest m) => DbRelease(Uint8List(0), '', m);

/// בקר מסד בלי רשת; בדיקת הרשת יכולה להיתקע עד ש-[gate] יושלם.
class _FakeDb extends DbController {
  _FakeDb() : super(AppController());

  DbRelease? fakeRemote;
  DbRelease? fakeMirror;
  String? attachedPath;
  String initialTarget = '';
  List<DbArtifact>? downloaded;
  bool installed = false;
  Completer<void>? gate;
  int checkCalls = 0;
  Object? setTargetError;

  void poke() => notifyListeners();

  @override
  Future<void> init({String? pinMirrorDir}) async {
    mirrorDir = pinMirrorDir ?? '';
    otzariaDbPath = attachedPath;
    targetDb = initialTarget;
    await refreshMirror();
    await checkRemote();
  }

  @override
  Future<void> refreshMirror() async => mirror = fakeMirror;

  @override
  Future<void> checkRemote() async {
    checkCalls++;
    final g = gate;
    if (g != null) {
      checking = true;
      notifyListeners();
      try {
        await g.future;
      } finally {
        checking = false;
      }
    }
    remote = fakeRemote;
    notifyListeners();
  }

  @override
  Future<void> inspectTarget() async {}

  @override
  Future<void> setTarget(String path) async {
    if (setTargetError != null) throw setTargetError!;
    targetDb = path;
  }

  @override
  Future<bool> downloadArtifacts(List<DbArtifact> list, {required String title, String? doneMessage}) async {
    downloaded = list;
    return true;
  }

  @override
  InstallPlan? get plan => installed
      ? InstallPlan(InstallAction.none, 'עדכני')
      : InstallPlan(InstallAction.full, 'מלא', artifact: mirror!.manifest.full);

  @override
  Future<void> install({String title = ''}) async => installed = true;
}

/// מקום פנוי "לא ידוע": בלי הרצת df אמיתי (נכשל ב-macOS ב-CI).
Future<int?> _noDf(String _) async => null;

void main() {
  late Directory tmp;
  late Duration savedSlow;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('quickui');
    savedSlow = QuickUpdateController.slowNetwork;
  });
  tearDown(() {
    QuickUpdateController.slowNetwork = savedSlow;
    tmp.deleteSync(recursive: true);
  });

  String existing(String name) => (File(p.join(tmp.path, name))..createSync(recursive: true)).path;

  group('ProgressRate', () {
    late DateTime now;
    late ProgressRate r;
    setUp(() {
      now = DateTime(2024);
      r = ProgressRate(clock: () => now);
    });
    void at(int sec, String key, int done, int? total) {
      now = DateTime(2024).add(Duration(seconds: sec));
      r.add(key, done, total);
    }

    test('אין הערכה לפני חימום של 2 שניות', () {
      at(0, 'a', 0, 10000);
      expect(r.bytesPerSecond, isNull);
      at(1, 'a', 1000, 10000);
      expect(r.bytesPerSecond, isNull);
      expect(r.remaining, isNull);
    });

    test('מהירות וזמן שנותר מחושבים נכון', () {
      at(0, 'a', 0, 10000);
      at(1, 'a', 1000, 10000);
      at(2, 'a', 2000, 10000);
      expect(r.bytesPerSecond, closeTo(1000, 0.01));
      expect(r.remaining, const Duration(seconds: 8));
    });

    test('כשאין התקדמות המהירות 0 ואין זמן שנותר', () {
      at(0, 'a', 500, 10000);
      at(3, 'a', 500, 10000);
      expect(r.bytesPerSecond, 0);
      expect(r.remaining, isNull);
    });

    test('שינוי מפתח השלב מאפס את המדידה', () {
      at(0, 'a', 0, 10000);
      at(2, 'a', 2000, 10000);
      expect(r.bytesPerSecond, isNotNull);
      at(3, 'b', 2500, 10000);
      expect(r.bytesPerSecond, isNull);
    });

    test('שינוי הגודל הכולל מאפס את המדידה', () {
      at(0, 'a', 0, 10000);
      at(2, 'a', 2000, 10000);
      at(3, 'a', 2500, 20000);
      expect(r.bytesPerSecond, isNull);
    });

    test('ירידה במונה מאפסת את המדידה', () {
      at(0, 'a', 0, 10000);
      at(2, 'a', 2000, 10000);
      at(3, 'a', 100, 10000);
      expect(r.bytesPerSecond, isNull);
    });

    test('דגימה אחרונה ישנה מ-5 שניות: אין הערכה (הורדה תקועה)', () {
      at(0, 'a', 0, 10000);
      at(2, 'a', 2000, 10000);
      expect(r.remaining, isNotNull);
      now = DateTime(2024).add(const Duration(seconds: 8));
      expect(r.bytesPerSecond, isNull);
      expect(r.remaining, isNull);
    });

    test('reset מנקה הכול', () {
      at(0, 'a', 0, 10000);
      at(2, 'a', 2000, 10000);
      r.reset();
      expect(r.bytesPerSecond, isNull);
      expect(r.remaining, isNull);
    });

    test('עיצוב הזמן שנותר', () {
      expect(ProgressRate.formatRemaining(const Duration(seconds: 30)), 'פחות מדקה');
      expect(ProgressRate.formatRemaining(const Duration(seconds: 60)), 'עוד כדקה');
      expect(ProgressRate.formatRemaining(const Duration(minutes: 5)), "עוד כ-5 דק'");
      expect(ProgressRate.formatRemaining(const Duration(minutes: 60)), 'עוד כשעה');
      expect(ProgressRate.formatRemaining(const Duration(minutes: 120)), 'עוד כשעתיים');
      expect(ProgressRate.formatRemaining(const Duration(minutes: 185)), "עוד כ-3 שע' ו-5 דק'");
    });
  });

  group('דילוג על הרשת', () {
    late _FakeDb db;
    late QuickUpdateController c;
    setUp(() {
      QuickUpdateController.slowNetwork = const Duration(milliseconds: 60);
      db = _FakeDb()
        ..gate = Completer<void>()
        ..fakeMirror = _release(_manifest(52, notes: 'חדשות מהכונן'))
        ..fakeRemote = _release(_manifest(53, notes: 'חדשות מהרשת'))
        ..attachedPath = existing('otz.db');
      c = QuickUpdateController(freeSpace: _noDf, mirrorDir: tmp.path, db: db, findOtzariaDb: () async => db.attachedPath);
    });
    tearDown(() => c.dispose());

    Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

    test('אפשר לדלג רק אחרי שעבר זמן; הדילוג מעדכן מהכונן ומתעלם מהרשת המאוחרת', () async {
      final f = c.start();
      await wait(10);
      expect(c.phase, QuickPhase.checking);
      expect(c.canSkipNetwork, isFalse);
      await wait(120);
      expect(c.canSkipNetwork, isTrue);
      c.skipNetwork();
      await f;
      expect(c.online, isFalse);
      expect(c.phase, QuickPhase.ready);
      expect(c.action, QuickAction.update);
      expect(c.title, contains('52'));
      expect(c.releaseNotes, 'חדשות מהכונן');
      expect(c.canSkipNetwork, isFalse);

      // הרשת מסיימת אחרי הדילוג (עם remote לא ריק): המצב לא משתנה.
      db.gate!.complete();
      await wait(30);
      expect(db.remote, isNotNull);
      expect(c.online, isFalse);
      expect(c.phase, QuickPhase.ready);
      expect(c.title, contains('52'));
      expect(c.releaseNotes, 'חדשות מהכונן');
    });

    test('שגיאה מאוחרת של הרשת אחרי דילוג לא נזרקת ולא משנה את המצב', () async {
      final f = c.start();
      await wait(120);
      c.skipNetwork();
      await f;
      db.gate!.completeError(Exception('late-net-error'));
      await wait(30);
      expect(c.phase, QuickPhase.ready);
      expect(c.online, isFalse);
    });

    test('דילוג כשהמסד כבר מעודכן: מסתיים "המסד מעודכן" בלי רשת', () async {
      db.installed = true;
      final f = c.start();
      await wait(120);
      c.skipNetwork();
      await f;
      expect(c.phase, QuickPhase.done);
      expect(c.online, isFalse);
    });

    test('skipNetwork לפני הזמן לא עושה כלום', () async {
      final f = c.start();
      await wait(5);
      c.skipNetwork();
      await wait(120);
      expect(c.phase, QuickPhase.checking);
      expect(c.canSkipNetwork, isTrue);
      db.gate!.complete();
      await f;
      expect(c.online, isTrue);
    });

    test('"נסו שוב" כשהבדיקה הישנה עוד תלויה: ממתינה לה ולא נתקעת, בלי בדיקה כפולה', () async {
      var f = c.start();
      await wait(120);
      c.skipNetwork();
      await f;
      expect(db.checkCalls, 1);
      f = c.start();
      await wait(10);
      expect(c.phase, QuickPhase.checking);
      await wait(120);
      expect(c.canSkipNetwork, isTrue);
      c.skipNetwork();
      await f.timeout(const Duration(seconds: 2));
      expect(c.phase, QuickPhase.ready);
      expect(c.online, isFalse);
      expect(db.checkCalls, 1);
    });

    test('"נסו שוב" כשהבדיקה הישנה הסתיימה בינתיים: מצב מחובר', () async {
      final f = c.start();
      await wait(120);
      c.skipNetwork();
      await f;
      db.gate!.complete();
      await wait(30);
      db.gate = null;
      await c.start().timeout(const Duration(seconds: 2));
      expect(c.online, isTrue);
      expect(c.phase, QuickPhase.ready);
      expect(c.action, QuickAction.download);
    });
  });

  group('הודעות שגיאה', () {
    FileSystemException fse(int code) => FileSystemException('msg', r'C:\x\y.db', OSError('os', code));

    test('שגיאות קבצים לפי קוד', () {
      expect(QuickUpdateController.friendlyError(fse(32)), contains('תפוס'));
      expect(QuickUpdateController.friendlyError(fse(5)), contains('הרשאה'));
      expect(QuickUpdateController.friendlyError(fse(112)), contains('מקום פנוי'));
      expect(QuickUpdateController.friendlyError(fse(2)), contains('לא נמצאו'));
      expect(QuickUpdateController.friendlyError(fse(9999)), contains('שגיאה בגישה לקבצים'));
      expect(QuickUpdateController.friendlyError(fse(32)), contains(r'C:\x\y.db'));
    });

    test('DbException, TimeoutException וחריגה כללית', () {
      expect(QuickUpdateController.friendlyError(DbException('הודעה שלי')), 'הודעה שלי');
      expect(QuickUpdateController.friendlyError(TimeoutException('x')), contains('לא הגיב'));
      expect(QuickUpdateController.friendlyError(Exception('boom')), 'אירעה שגיאה לא צפויה.');
    });

    test('חריגה לא צפויה: כשל עם הודעה ידידותית, והטקסט הגולמי רק בפרטים', () async {
      final db = _FakeDb()
        ..fakeMirror = _release(_manifest(52))
        ..attachedPath = existing('otz.db')
        ..setTargetError = Exception('raw-boom-text');
      final c = QuickUpdateController(freeSpace: _noDf, mirrorDir: tmp.path, db: db, findOtzariaDb: () async => db.attachedPath);
      await c.start();
      expect(c.phase, QuickPhase.failed);
      expect(c.message, 'אירעה שגיאה לא צפויה.');
      expect(c.message, isNot(contains('Exception')));
      expect(c.errorDetails, contains('raw-boom-text'));
      c.dispose();
    });
  });

  group('עדכון מהכונן: פרטים', () {
    test('הפרטים כוללים סוג עדכון וגודל, וה"מה חדש" מוצג', () async {
      final db = _FakeDb()
        ..fakeMirror = _release(_manifest(52, notes: '  תיקון ספרים  '))
        ..attachedPath = existing('otz.db');
      final c = QuickUpdateController(freeSpace: _noDf, mirrorDir: tmp.path, db: db, findOtzariaDb: () async => db.attachedPath);
      await c.start();
      expect(c.phase, QuickPhase.ready);
      expect(c.detail.contains('עדכון חלקי') || c.detail.contains('החלפת המסד כולו'), isTrue, reason: c.detail);
      expect(c.detail, matches(RegExp(r'\d')));
      expect(c.detail, matches(RegExp(r'(B|KB|MB|GB)')));
      expect(c.releaseNotes, 'תיקון ספרים');
      c.dispose();
    });

    test('בלי release_notes: ה"מה חדש" ריק', () async {
      final db = _FakeDb()
        ..fakeMirror = _release(_manifest(52))
        ..attachedPath = existing('otz.db');
      final c = QuickUpdateController(freeSpace: _noDf, mirrorDir: tmp.path, db: db, findOtzariaDb: () async => db.attachedPath);
      await c.start();
      expect(c.releaseNotes, isEmpty);
      c.dispose();
    });
  });

  group('המסך', () {
    Widget host(Widget child, {double scale = 1}) => MaterialApp(
      theme: quickTheme(),
      builder: (context, ch) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: Directionality(textDirection: TextDirection.rtl, child: ch!),
      ),
      home: child,
    );

    Future<void> startIt(WidgetTester t, QuickUpdateController c) async {
      await t.runAsync(c.start);
      await t.pump();
    }

    Future<void> pumpUntil(WidgetTester t, bool Function() ok) async {
      for (var i = 0; i < 300 && !ok(); i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump();
      }
      await t.pump();
    }

    const sizes = [Size(400, 620), Size(400, 480), Size(400, 360), Size(400, 300)];
    final longNotes = List.generate(40, (i) => 'שורה $i של הערות גרסה ארוכות מאוד מאוד').join('\n');
    final longMsg = List.generate(30, (i) => 'הודעת שגיאה ארוכה מספר $i').join(' ');

    // השדה השני: טקסט הכפתור שחייב להופיע.
    final phases = <(String, String?, Future<QuickUpdateController> Function(_FakeDb, Directory))>[
      ('בדיקה', null, (db, d) async => QuickUpdateController(freeSpace: _noDf, mirrorDir: d.path, db: db)),
      ('מוכן להתקנה עם מיקום', 'התקנה', (db, d) async {
        db
          ..fakeMirror = _release(_manifest(52))
          ..initialTarget = p.join(d.path, 'none', 'x.db');
        return QuickUpdateController(freeSpace: _noDf, mirrorDir: d.path, db: db, findOtzariaDb: () async => null);
      }),
      ('מוכן עם הערות ארוכות', 'עדכון', (db, d) async {
        db
          ..fakeMirror = _release(_manifest(52, notes: longNotes))
          ..attachedPath = (File(p.join(d.path, 'o.db'))..createSync()).path;
        return QuickUpdateController(freeSpace: _noDf, mirrorDir: d.path, db: db, findOtzariaDb: () async => db.attachedPath);
      }),
      ('עבודה עם התקדמות', 'עצירה', (db, d) async => QuickUpdateController(freeSpace: _noDf, mirrorDir: d.path, db: db)),
      ('סיום עם אזהרה', 'סגירה', (db, d) async => QuickUpdateController(freeSpace: _noDf, mirrorDir: d.path, db: db)),
      ('כשל עם הודעה ארוכה', 'נסו שוב', (db, d) async => QuickUpdateController(freeSpace: _noDf, mirrorDir: d.path, db: db)),
    ];

    for (final scale in [1.0, 1.3]) {
      for (final size in sizes) {
        for (final ph in phases) {
          testWidgets('פריסה: ${ph.$1} ב-${size.width.toInt()}x${size.height.toInt()} טקסט x$scale', (t) async {
            await t.binding.setSurfaceSize(size);
            addTearDown(() => t.binding.setSurfaceSize(null));
            final db = _FakeDb();
            final c = await ph.$3(db, tmp);
            await t.pumpWidget(host(QuickUpdateScreen(controller: c, autoStart: false, onClose: () {}), scale: scale));
            switch (ph.$1) {
              case 'מוכן להתקנה עם מיקום' || 'מוכן עם הערות ארוכות':
                await startIt(t, c);
                expect(c.phase, QuickPhase.ready);
              case 'עבודה עם התקדמות':
                c.phase = QuickPhase.working;
                db.activity = DbActivity('מוריד')
                  ..progress = 0.4
                  ..detail = 'קובץ-ארוך-מאוד-${'x' * 80}.zst'
                  ..done = 400
                  ..total = 1000;
                db.poke();
                await t.pump();
              case 'סיום עם אזהרה':
                c
                  ..title = 'המסד עודכן'
                  ..detail = 'גרסה 52'
                  ..warning = longMsg
                  ..phase = QuickPhase.done;
                db.poke();
                await t.pump();
              case 'כשל עם הודעה ארוכה':
                c
                  ..note = longMsg
                  ..phase = QuickPhase.failed;
                db.poke();
                await t.pump();
            }
            await t.pump();
            expect(t.takeException(), isNull);
            expect(find.textContaining('המסד אינו חלק מתוכנת אוצריא'), findsOneWidget);
            if (ph.$2 != null) expect(find.text(ph.$2!), findsOneWidget);
            c.dispose();
          });
        }
      }
    }

    testWidgets('בדיקה איטית: כפתור הדילוג מופיע ולחיצה עליו עוברת למצב מהכונן', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 620));
      addTearDown(() => t.binding.setSurfaceSize(null));
      QuickUpdateController.slowNetwork = const Duration(milliseconds: 30);
      final db = _FakeDb()
        ..gate = Completer<void>()
        ..fakeMirror = _release(_manifest(52))
        ..attachedPath = existing('o.db');
      final c = QuickUpdateController(freeSpace: _noDf, mirrorDir: tmp.path, db: db, findOtzariaDb: () async => db.attachedPath);
      await t.pumpWidget(host(QuickUpdateScreen(controller: c, autoStart: false, onClose: () {})));
      late Future<void> started;
      await t.runAsync(() async {
        started = c.start();
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      await t.pump();
      expect(find.text('דילוג – עדכון מהכונן'), findsOneWidget);
      await t.tap(find.text('דילוג – עדכון מהכונן'));
      await t.runAsync(() => started);
      await t.pump();
      expect(c.phase, QuickPhase.ready);
      expect(find.text('עדכון'), findsOneWidget);
      expect(t.takeException(), isNull);
      c.dispose();
    });

    testWidgets('מקלדת: Enter בשלב מוכן מפעיל את הכפתור הראשי', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 620));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final db = _FakeDb()..fakeRemote = _release(_manifest(52));
      final c = QuickUpdateController(freeSpace: _noDf, mirrorDir: tmp.path, db: db);
      await t.pumpWidget(host(QuickUpdateScreen(controller: c, autoStart: false, onClose: () {})));
      await startIt(t, c);
      expect(c.phase, QuickPhase.ready);
      expect(db.downloaded, isNull);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpUntil(t, () => c.phase == QuickPhase.done);
      expect(db.downloaded, isNotNull);
      c.dispose();
    });

    testWidgets('מקלדת: Escape קורא ל-onClose כשלא רץ', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 620));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final db = _FakeDb()..fakeRemote = _release(_manifest(52));
      final c = QuickUpdateController(freeSpace: _noDf, mirrorDir: tmp.path, db: db);
      var closed = 0;
      await t.pumpWidget(host(QuickUpdateScreen(controller: c, autoStart: false, onClose: () => closed++)));
      await startIt(t, c);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(closed, 1);
      c.dispose();
    });

    testWidgets('מקלדת: Tab לכפתור "סגירה" ואז Enter סוגר ולא מפעיל "נסו שוב"', (t) async {
      // ב-Android Enter לא מפעיל כפתורים; באפליקציית שולחן העבודה כן.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      // מאופס בסוף הבדיקה (לפני בדיקת התקינות של המסגרת).
      await t.binding.setSurfaceSize(const Size(400, 620));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final db = _FakeDb(); // בלי רשת ובלי כונן: כשל
      final c = QuickUpdateController(freeSpace: _noDf, mirrorDir: tmp.path, db: db, findOtzariaDb: () async => null);
      var closed = 0;
      await t.pumpWidget(host(QuickUpdateScreen(controller: c, autoStart: false, onClose: () => closed++)));
      await startIt(t, c);
      expect(c.phase, QuickPhase.failed);
      final checksBefore = db.checkCalls;

      bool onClose() {
        final ctx = FocusManager.instance.primaryFocus?.context;
        if (ctx == null) return false;
        final self = find.byElementPredicate((e) => e == ctx);
        // הממוקד חייב להיות בתוך כפתור (ולא מיקוד השורש, שמכיל את כל המסך).
        return find.ancestor(of: self, matching: find.bySubtype<ButtonStyleButton>()).evaluate().isNotEmpty &&
            find.descendant(of: self, matching: find.text('סגירה')).evaluate().isNotEmpty;
      }

      for (var i = 0; i < 6 && !onClose(); i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
      }
      expect(onClose(), isTrue, reason: 'Tab לא הגיע לכפתור סגירה');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
      expect(closed, 1);
      expect(db.checkCalls, checksBefore, reason: '"נסו שוב" לא היה אמור לרוץ');
      debugDefaultTargetPlatformOverride = null;
      c.dispose();
    });

    testWidgets('כשל: "העתקת פרטי התקלה" מעתיק את ההודעה והפרטים ללוח', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 620));
      addTearDown(() => t.binding.setSurfaceSize(null));
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final db = _FakeDb();
      final c = QuickUpdateController(freeSpace: _noDf, mirrorDir: tmp.path, db: db);
      c
        ..note = 'הודעת בדיקה לכשל'
        ..errorDetails = 'raw details here'
        ..phase = QuickPhase.failed;
      await t.pumpWidget(host(QuickUpdateScreen(controller: c, autoStart: false, onClose: () {})));
      expect(find.text('העתקת פרטי התקלה'), findsOneWidget);
      await t.tap(find.text('העתקת פרטי התקלה'));
      await t.pump();
      expect(copied, contains('הודעת בדיקה לכשל'));
      expect(copied, contains('raw details here'));
      expect(t.takeException(), isNull);
      c.dispose();
    });

    for (final size in [const Size(400, 620), const Size(400, 360)]) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('QuickAlreadyRunningScreen ב-${size.height.toInt()} טקסט x$scale: ללא חריגות', (t) async {
          await t.binding.setSurfaceSize(size);
          addTearDown(() => t.binding.setSurfaceSize(null));
          await t.pumpWidget(host(QuickAlreadyRunningScreen(onClose: () {}), scale: scale));
          await t.pump();
          expect(t.takeException(), isNull);
          expect(find.text('התוכנה כבר פתוחה'), findsOneWidget);
          expect(find.textContaining('המסד אינו חלק מתוכנת אוצריא'), findsOneWidget);
          expect(find.text('סגירה'), findsOneWidget);
        });
      }
    }

    testWidgets('QuickAlreadyRunningScreen: Escape, Enter והכפתור סוגרים', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 620));
      addTearDown(() => t.binding.setSurfaceSize(null));
      var closed = 0;
      await t.pumpWidget(host(QuickAlreadyRunningScreen(onClose: () => closed++)));
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(closed, 1);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(closed, 2);
      await t.tap(find.text('סגירה'));
      await t.pump();
      expect(closed, 3);
    });
  });
}
