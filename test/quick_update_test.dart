import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:books_offline_update/src/controllers/app_controller.dart';
import 'package:books_offline_update/src/db/db_controller.dart';
import 'package:books_offline_update/src/db/db_manifest.dart';
import 'package:books_offline_update/src/db/db_service.dart';
import 'package:books_offline_update/src/quick/quick_update_controller.dart';
import 'package:books_offline_update/src/quick/quick_update_screen.dart';
import 'package:books_offline_update/src/services/app_paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _sha(int n) => n.toRadixString(16).padLeft(64, '0');

Map<String, dynamic> _part(String name, int size, int sha) => {
  'url': 'https://example.com/$name',
  'size': size,
  'sha256': _sha(sha),
};

/// גרסה v: sha = v. צעד from→from+1, ודלתא ישירה from→latest.
Map<String, dynamic> _step(int from, int to, {String? name}) => {
  'compression': 'zstd-patch',
  'size': 100,
  'sha256': _sha(to),
  'from_db_version': from,
  'from_sha256': _sha(from),
  'parts': [_part(name ?? '$dbLibraryId-$to.db.from-$from.patch.zst', 10, 1000 + from * 100 + to)],
};

DbManifest _manifest(int latest, {List<int> directFrom = const []}) => DbManifest.parse(
  Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': 1,
        'library_id': dbLibraryId,
        'db_version': latest,
        'full': {
          'compression': 'zstd',
          'size': 1000,
          'sha256': _sha(latest),
          'parts': [_part('$dbLibraryId-$latest.db.zst', 50, 9999)],
        },
        'delta': [for (final f in directFrom) _step(f, latest)],
      }),
    ),
  ),
);

StepsManifest _steps(int first, int latest, {Set<int> missing = const {}}) => StepsManifest(
  libraryId: dbLibraryId,
  version: latest,
  steps: [
    for (var v = first; v < latest; v++)
      if (!missing.contains(v)) DbManifest.artifactFrom(_step(v, v + 1), delta: true),
  ],
);

DbRelease _release(DbManifest m) => DbRelease(Uint8List(0), '', m);

/// בקר מסד בלי רשת, בלי הגדרות על הדיסק ובלי לגעת באוצריא.
class _FakeDb extends DbController {
  _FakeDb() : super(AppController());

  DbRelease? fakeRemote;
  StepsRelease? fakeSteps;
  DbRelease? fakeMirror;
  String? attachedPath;
  String initialTarget = '';
  List<DbArtifact>? downloaded;
  bool installed = false;
  bool downloadOk = true;
  String? fakeRemoteError;
  bool installNoop = false;
  String? installStopMessage;

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
    remote = fakeRemote;
    remoteSteps = fakeSteps;
    remoteError = fakeRemoteError;
  }

  @override
  Future<void> inspectTarget() async {}

  @override
  Future<void> setTarget(String path) async => targetDb = path;

  @override
  Future<bool> downloadArtifacts(List<DbArtifact> list, {required String title, String? doneMessage}) async {
    downloaded = list;
    return downloadOk;
  }

  @override
  InstallPlan? get plan => installed
      ? InstallPlan(InstallAction.none, 'עדכני')
      : InstallPlan(InstallAction.full, 'מלא', artifact: mirror!.manifest.full);

  @override
  Future<void> install({String title = ''}) async {
    if (installNoop) return;
    if (installStopMessage != null) {
      message = installStopMessage;
      messageIsError = false;
      return;
    }
    installed = true;
  }
}

/// בקר מסד אמיתי עם הגדרות בתיקייה זמנית, בלי פנייה לרשת.
class _NoNetDb extends DbController {
  _NoNetDb(String configDir) : super(AppController(), configDir: configDir);

  @override
  Future<void> checkRemote() async {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('quick'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('הקבצים שיורדים לכונן', () {
    test('מסד מלא + צעדים של 10 גרסאות אחורה + דלתאות ישירות, בלי כפילויות', () {
      final m = _manifest(52, directFrom: [50, 51]);
      final set = QuickUpdateController.driveSet(m, _steps(30, 52));
      expect(set.first, same(m.full));
      final steps = set.skip(1).where((a) => int.parse(a.sha256, radix: 16) == a.fromVersion! + 1);
      expect(steps.map((a) => a.fromVersion).toSet(), {42, 43, 44, 45, 46, 47, 48, 49, 50, 51});
      // הדלתא הישירה 51→52 זהה לצעד (אותו שם קובץ): לא נוספת שוב. 50→52 כן.
      final direct = set.where((a) => a.fromVersion == 50 && a.sha256 == _sha(52)).toList();
      expect(direct, hasLength(1));
      final names = [for (final a in set) ...a.parts.map((x) => x.fileName)];
      expect(names.toSet().length, names.length);
    });

    test('בלי מניפסט צעדים: המסד המלא והדלתאות הישירות', () {
      final m = _manifest(52, directFrom: [51]);
      final set = QuickUpdateController.driveSet(m, null);
      expect(set, hasLength(2));
    });

    test('צעד שאין ממנו שרשרת עד העדכנית לא יורד', () {
      final m = _manifest(52);
      final set = QuickUpdateController.driveSet(m, _steps(40, 52, missing: {47}));
      expect(set.skip(1).map((a) => a.fromVersion).toSet(), {48, 49, 50, 51});
    });
  });

  test('ניקוי קובצי עדכון ישנים מהכונן בלבד', () async {
    final keep = QuickUpdateController.driveSet(_manifest(52), _steps(48, 52));
    for (final n in [
      '$dbLibraryId-49.db.from-48.patch.zst',
      '$dbLibraryId-40.db.from-39.patch.zst',
      '$dbLibraryId-52.db.zst',
      'other.patch.zst',
      'manifest.json',
    ]) {
      File(p.join(tmp.path, n)).writeAsStringSync('x');
    }
    await QuickUpdateController.pruneOldPatches(tmp.path, keep);
    final left = tmp.listSync().map((e) => p.basename(e.path)).toSet();
    expect(left, {
      '$dbLibraryId-49.db.from-48.patch.zst',
      '$dbLibraryId-52.db.zst',
      'other.patch.zst',
      'manifest.json',
    });
  });

  test('זיהוי הפעלה מתוך עדכוני אוצריא', () {
    expect(AppPaths.launchedFromOtzariaUpdates(tmp.path), isFalse);
    File(p.join(tmp.path, 'descriptor.json')).writeAsStringSync('{}');
    expect(AppPaths.launchedFromOtzariaUpdates(tmp.path), isFalse);
    File(p.join(tmp.path, 'installer.json')).writeAsStringSync('{}');
    expect(AppPaths.launchedFromOtzariaUpdates(tmp.path), isTrue);
  });

  group('זרימת העדכון המהיר', () {
    late _FakeDb db;
    late QuickUpdateController c;
    setUp(() {
      db = _FakeDb();
      c = QuickUpdateController(
        mirrorDir: p.join(tmp.path, dbMirrorDirName),
        db: db,
        findOtzariaDb: () async => db.attachedPath,
      );
    });
    tearDown(() => c.dispose());

    String existing(String name) => (File(p.join(tmp.path, name))..createSync(recursive: true)).path;

    test('מצורף לאוצריא אבל הקובץ נמחק: כמו התקנה ראשונה (בחירת מיקום)', () async {
      db.fakeMirror = _release(_manifest(52));
      db.attachedPath = p.join(tmp.path, 'deleted', '$dbLibraryId.db');
      await c.start();
      expect(c.phase, QuickPhase.ready);
      expect(c.action, QuickAction.install);
    });

    test('התקנה ראשונה לתיקייה שכבר יש בה מסד עדכני: רק מצרפים, לא כשל', () async {
      db.fakeMirror = _release(_manifest(52));
      db.initialTarget = p.join(tmp.path, 'none', 'x.db');
      await c.start();
      db.installed = true; // המסד שבתיקייה שנבחרה כבר עדכני
      final folder = p.join(tmp.path, 'has-db');
      // ensureAttached רואה שהמסד כבר מצורף, ולכן לא נוגע באוצריא האמיתית.
      db.otzariaDbPath = p.join(folder, '$dbLibraryId.db');
      await c.installTo(folder);
      expect(c.phase, QuickPhase.done);
      expect(c.title, 'המסד מעודכן');
    });

    void fillDrive(DbManifest m, StepsManifest? steps) {
      Directory(c.mirrorDir).createSync(recursive: true);
      for (final a in QuickUpdateController.driveSet(m, steps)) {
        for (final part in a.parts) {
          File(p.join(c.mirrorDir, part.fileName)).writeAsBytesSync(List.filled(part.size, 0));
        }
      }
    }

    test('מחשב מחובר: בפתיחה בודק ומציג כפתור הורדה; ההורדה רק בלחיצה', () async {
      final m = _manifest(52, directFrom: [50, 51]);
      db.fakeRemote = _release(m);
      db.fakeSteps = StepsRelease(Uint8List(0), '', _steps(40, 52));
      await c.start();
      expect(c.online, isTrue);
      expect(c.phase, QuickPhase.ready);
      expect(c.action, QuickAction.download);
      expect(c.title, contains('52'));
      expect(c.detail, contains('להורדה'));
      expect(db.downloaded, isNull);
      await c.run();
      expect(c.phase, QuickPhase.done);
      expect(c.title, 'הכונן מוכן');
      expect(
        db.downloaded!.map((a) => a.parts.first.fileName),
        QuickUpdateController.driveSet(m, db.fakeSteps!.manifest).map((a) => a.parts.first.fileName),
      );
    });

    test('מחשב מחובר: הכונן כבר מעודכן — אין כפתור הורדה', () async {
      final m = _manifest(52);
      final steps = _steps(48, 52);
      db.fakeRemote = _release(m);
      db.fakeSteps = StepsRelease(Uint8List(0), '', steps);
      db.fakeMirror = _release(m);
      fillDrive(m, steps);
      await c.start();
      expect(c.phase, QuickPhase.done);
      expect(c.title, 'הכונן מעודכן');
    });

    for (final installed in [true, false]) {
      test('מחשב מחובר, הכונן מעודכן, המסד המקומי ${installed ? "מעודכן: אין" : "ישן: יש"} "עדכון במחשב זה"', () async {
        final m = _manifest(52);
        final steps = _steps(48, 52);
        db.fakeRemote = _release(m);
        db.fakeSteps = StepsRelease(Uint8List(0), '', steps);
        db.fakeMirror = _release(m);
        fillDrive(m, steps);
        db.attachedPath = existing('local/$dbLibraryId.db');
        db.installed = installed;
        await c.start();
        expect(c.phase, QuickPhase.done);
        expect(c.canUpdateThisComputer, !installed);
      });
    }

    test('מחשב מחובר: כל הקבצים בכונן אבל המניפסט ישן — מציעים הורדה', () async {
      final m = _manifest(52);
      db.fakeRemote = _release(m);
      db.fakeMirror = _release(_manifest(51));
      fillDrive(m, null);
      await c.start();
      expect(c.phase, QuickPhase.ready);
      expect(c.detail, isEmpty);
    });

    test('מחשב מחובר: הורדה שנכשלה, ואז "נסו שוב" בודק מחדש', () async {
      db.fakeRemote = _release(_manifest(52));
      db.downloadOk = false;
      await c.start();
      await c.run();
      expect(c.phase, QuickPhase.failed);
      db.downloadOk = true;
      await c.start();
      expect(c.phase, QuickPhase.ready);
      await c.run();
      expect(c.phase, QuickPhase.done);
    });

    test('בלי רשת ובלי קבצים בכונן: הסבר, כולל שגיאת הרשת', () async {
      db.fakeRemoteError = 'חסום';
      await c.start();
      expect(c.online, isFalse);
      expect(c.phase, QuickPhase.failed);
      expect(c.message, contains('במחשב מחובר'));
      expect(c.message, contains('חסום'));
    });

    test('בלי רשת, פעם ראשונה: ברירת המחדל כבר נבחרה, ו"התקנה" מתקין שם בלי לשאול', () async {
      db.fakeMirror = _release(_manifest(52));
      db.initialTarget = p.join(tmp.path, 'none', 'x.db');
      await c.start();
      expect(c.phase, QuickPhase.ready);
      expect(c.action, QuickAction.install);
      expect(c.installFolder, c.proposedFolder);
      expect(db.installed, isFalse);
      await c.run();
      expect(db.targetDb, p.join(c.proposedFolder, '$dbLibraryId.db'));
      expect(db.installed, isTrue);
      expect(c.phase, QuickPhase.done);
      expect(c.title, 'המסד עודכן');
    });

    test('בלי רשת, פעם ראשונה: "שינוי" מחליף את המיקום, ו"התקנה" מתקין במיקום החדש', () async {
      db.fakeMirror = _release(_manifest(52));
      db.initialTarget = p.join(tmp.path, 'none', 'x.db');
      await c.start();
      final folder = p.join(tmp.path, 'chosen');
      c.changeFolder(folder);
      expect(c.installFolder, folder);
      expect(db.installed, isFalse, reason: 'שינוי המיקום לבדו לא מתקין');
      await c.run();
      expect(db.targetDb, p.join(folder, '$dbLibraryId.db'));
      expect(db.installed, isTrue);
    });

    test('מחשב מחובר: אחרי ההורדה "עדכון במחשב זה" מעדכן את המסד המקומי מהכונן', () async {
      final m = _manifest(52);
      db.fakeRemote = _release(m);
      db.fakeMirror = _release(m);
      db.attachedPath = existing('local.db');
      await c.start();
      await c.run();
      expect(c.title, 'הכונן מוכן');
      expect(c.canUpdateThisComputer, isTrue);
      await c.updateThisComputer();
      expect(db.installed, isTrue);
      expect(c.phase, QuickPhase.done);
      expect(c.title, 'המסד עודכן');
      expect(c.canUpdateThisComputer, isFalse, reason: 'לא מציעים שוב אחרי העדכון המקומי');
    });

    test('מחשב מחובר: "עדכון במחשב זה" כשהמסד לא מותקן כאן — מסך התקנה עם ברירת מחדל', () async {
      final m = _manifest(52);
      db.fakeRemote = _release(m);
      db.fakeMirror = _release(m);
      db.initialTarget = p.join(tmp.path, 'none', 'x.db');
      await c.start();
      await c.run();
      await c.updateThisComputer();
      expect(c.phase, QuickPhase.ready);
      expect(c.action, QuickAction.install);
      expect(db.installed, isFalse);
      await c.run();
      expect(db.installed, isTrue);
      expect(c.phase, QuickPhase.done);
    });

    test('בלי רשת, מסד מצורף לאוצריא: כפתור עדכון, והעדכון רק בלחיצה', () async {
      db.fakeMirror = _release(_manifest(52));
      final attached = existing(p.join('otz', '$dbLibraryId.db'));
      db.attachedPath = attached;
      await c.start();
      expect(db.targetDb, attached);
      expect(c.phase, QuickPhase.ready);
      expect(c.action, QuickAction.update);
      expect(db.installed, isFalse);
      await c.run();
      expect(db.installed, isTrue);
      expect(c.phase, QuickPhase.done);
    });

    test('בלי רשת, המסד כבר מעודכן: אין כפתור', () async {
      db.fakeMirror = _release(_manifest(52));
      db.attachedPath = existing('otz.db');
      db.installed = true;
      await c.start();
      expect(c.phase, QuickPhase.done);
      expect(c.title, 'המסד מעודכן');
      expect(c.warning, isNull);
    });

    test('בחירת תיקייה: לחיצה כפולה נבלעת', () async {
      db.fakeMirror = _release(_manifest(52));
      db.initialTarget = p.join(tmp.path, 'none', 'x.db');
      await c.start();
      final first = c.installTo(p.join(tmp.path, 'a'));
      expect(c.phase, QuickPhase.working);
      expect(c.running, isTrue);
      await c.installTo(p.join(tmp.path, 'b'));
      await first;
      expect(db.targetDb, p.join(tmp.path, 'a', '$dbLibraryId.db'));
    });

    test('העדכון לא התחיל (בלי הודעה): הודעה ברורה', () async {
      db.fakeMirror = _release(_manifest(52));
      db.attachedPath = existing('otz.db');
      db.installNoop = true;
      await c.start();
      await c.run();
      expect(c.phase, QuickPhase.failed);
      expect(c.message, contains('לא התחיל'));
    });

    test('עצירה בידי המשתמש: כשל רך; "נסו שוב" ואז עדכון מצליח', () async {
      db.fakeMirror = _release(_manifest(52));
      db.attachedPath = existing('otz.db');
      db.installStopMessage = 'הפעולה נעצרה. המסד הקיים לא שונה.';
      await c.start();
      await c.run();
      expect(c.phase, QuickPhase.failed);
      expect(c.stoppedByUser, isTrue);
      db.installStopMessage = null;
      await c.start();
      expect(c.phase, QuickPhase.ready);
      await c.run();
      expect(c.phase, QuickPhase.done);
    });

    test('אחרי dispose תהליך שרץ לא זורק', () async {
      db.fakeMirror = _release(_manifest(52));
      db.attachedPath = existing('otz.db');
      final run = c.start();
      c.dispose();
      await run;
      expect(c.phase, isNot(QuickPhase.done));
      c = QuickUpdateController(mirrorDir: tmp.path, db: _FakeDb());
    });

    test('הבקר לא מזהה את המסד המקומי מעצמו (חוסך חישוב SHA במחשב המחובר)', () {
      expect(db.autoInspect, isFalse);
    });
  });

  group('שמירת ההגדרות במצב מהיר', () {
    test('תיקיית המראה הננעצת לא דורסת את זו שנשמרה', () async {
      final cfg = Directory(p.join(tmp.path, 'cfg'))..createSync();
      final settings = File(p.join(cfg.path, 'db_settings.json'));
      settings.writeAsStringSync(jsonEncode({'mirrorDir': 'D:/saved', 'targetDb': p.join(tmp.path, 'a.db')}));
      final db = _NoNetDb(cfg.path);
      await db.init(pinMirrorDir: p.join(tmp.path, 'pinned'));
      expect(db.mirrorDir, p.join(tmp.path, 'pinned'));
      await db.setTarget(p.join(tmp.path, 'b.db'));
      final j = jsonDecode(settings.readAsStringSync()) as Map<String, dynamic>;
      expect(j['mirrorDir'], 'D:/saved');
      expect(j['targetDb'], p.join(tmp.path, 'b.db'));
      db.dispose();
    });

    test('בלי תיקייה שמורה: נשמר ריק (ברירת המחדל), לא התיקייה הננעצת', () async {
      final cfg = Directory(p.join(tmp.path, 'cfg'))..createSync();
      final settings = File(p.join(cfg.path, 'db_settings.json'));
      settings.writeAsStringSync(jsonEncode({'targetDb': p.join(tmp.path, 'a.db')}));
      final db = _NoNetDb(cfg.path);
      await db.init(pinMirrorDir: p.join(tmp.path, 'pinned'));
      await db.setTarget(p.join(tmp.path, 'b.db'));
      final j = jsonDecode(settings.readAsStringSync()) as Map<String, dynamic>;
      expect(j['mirrorDir'], '');
      db.dispose();
    });
  });

  group('המסך', () {
    Widget host(Widget child) => MaterialApp(
      theme: quickTheme(),
      builder: (context, ch) => Directionality(textDirection: TextDirection.rtl, child: ch!),
      home: child,
    );

    Future<void> settle(WidgetTester t, QuickUpdateController c, Future<void> Function() action) async {
      await t.runAsync(action);
      await t.pump();
    }

    ButtonStyleButton buttonWith(WidgetTester t, String text) =>
        t.widget<ButtonStyleButton>(find.ancestor(of: find.text(text), matching: find.bySubtype<ButtonStyleButton>()));

    testWidgets('פעם ראשונה: ברירת המחדל מוצגת, "שינוי" מחליף אותה בלי להתקין, "התקנה" מתקין', (t) async {
      await t.binding.setSurfaceSize(const Size(quickWindowWidth, quickWindowHeight));
      final db = _FakeDb()
        ..fakeMirror = _release(_manifest(52))
        ..initialTarget = p.join(tmp.path, 'none', 'x.db');
      final c = QuickUpdateController(mirrorDir: tmp.path, db: db, findOtzariaDb: () async => null);
      String? askedAt;
      await t.pumpWidget(
        host(
          QuickUpdateScreen(
            controller: c,
            autoStart: false,
            onClose: () {},
            pickFolder: (dir) async {
              askedAt = dir;
              return p.join(tmp.path, 'chosen');
            },
          ),
        ),
      );
      await settle(t, c, c.start);
      expect(find.text('המסד לא מותקן במחשב הזה'), findsOneWidget);
      expect(find.text(c.proposedFolder), findsOneWidget);
      expect(buttonWith(t, 'התקנה').onPressed, isNotNull);

      await t.tap(find.text('שינוי'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump();
      expect(askedAt, c.proposedFolder);
      expect(db.installed, isFalse);
      expect(find.text(p.join(tmp.path, 'chosen')), findsOneWidget);

      await t.tap(find.text('התקנה'));
      for (var i = 0; i < 400 && c.phase != QuickPhase.done; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump();
      }
      await t.pump();
      expect(db.targetDb, p.join(tmp.path, 'chosen', '$dbLibraryId.db'));
      expect(db.installed, isTrue);
      expect(find.text('המסד עודכן'), findsOneWidget);
      expect(find.text('סגירה'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('מחשב מחובר: כפתור "הורדה" אחד, ובסיום "הכונן מוכן"', (t) async {
      await t.binding.setSurfaceSize(const Size(quickWindowWidth, quickWindowHeight));
      final db = _FakeDb()..fakeRemote = _release(_manifest(52));
      final c = QuickUpdateController(mirrorDir: tmp.path, db: db);
      var closed = false;
      await t.pumpWidget(host(QuickUpdateScreen(controller: c, autoStart: false, onClose: () => closed = true)));
      await settle(t, c, c.start);
      expect(find.text('גרסה 52 זמינה'), findsOneWidget);
      expect(find.bySubtype<ButtonStyleButton>(), findsOneWidget);
      expect(buttonWith(t, 'הורדה').onPressed, isNotNull);
      await t.tap(find.text('הורדה'));
      for (var i = 0; i < 400 && c.phase != QuickPhase.done; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump();
      }
      await t.pump();
      expect(find.text('הכונן מוכן'), findsOneWidget);
      expect(buttonWith(t, 'עדכון במחשב זה').onPressed, isNotNull);
      await t.tap(find.text('סגירה'));
      await t.pump();
      expect(closed, isTrue);
      expect(t.takeException(), isNull);
    });

    testWidgets('ההבהרה שהמסד אינו חלק מאוצריא מוצגת תמיד', (t) async {
      await t.binding.setSurfaceSize(const Size(quickWindowWidth, quickWindowHeight));
      final c = QuickUpdateController(mirrorDir: tmp.path, db: _FakeDb());
      await t.pumpWidget(host(QuickUpdateScreen(controller: c, autoStart: false, onClose: () {})));
      expect(find.textContaining('המסד אינו חלק מתוכנת אוצריא'), findsOneWidget);
      expect(find.textContaining('אין לפנות לאוצריא'), findsOneWidget);
      await settle(t, c, c.start);
      expect(c.phase, QuickPhase.failed);
      expect(find.textContaining('המסד אינו חלק מתוכנת אוצריא'), findsOneWidget);
      expect(find.text('נסו שוב'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
