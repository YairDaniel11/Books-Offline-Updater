import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_localizations/flutter_localizations.dart';

import 'dart:io';

import 'src/controllers/app_controller.dart';
import 'src/db/db_controller.dart' show dbMirrorDirName;
import 'src/quick/quick_log.dart';
import 'src/quick/quick_update_controller.dart';
import 'src/quick/quick_update_screen.dart';
import 'src/quick/quick_window.dart';
import 'src/quick/windows_registration.dart';
import 'src/vectors/vectors_controller.dart';
import 'src/services/app_paths.dart';
import 'src/update/app_update.dart' show appVersion;
import 'src/services/single_instance.dart';
import 'src/screens/app_shell.dart';
import 'src/theme/app_theme.dart';

// נשמר לכל חיי התהליך; המערכת משחררת אותו בסיום או בקריסה.
// ignore: unused_element
SingleInstance? _instanceLock;

Future<void> main(List<String> args) async {
  // "הסרה" מהגדרות Windows: התוכנה ניידת, ולכן מוחקים רק את הרישום שלה ויוצאים בלי חלון.
  if (args.contains(WindowsRegistration.unregisterArg)) {
    WindowsRegistration.unregister();
    exit(0);
  }
  WidgetsFlutterBinding.ensureInitialized();
  // מתוך עדכוני אוצריא (או --quick): חלון קטן לעדכון המסד בלבד.
  final fromOtzariaUpdates = AppPaths.launchedFromOtzariaUpdates();
  final quick = args.contains('--quick') || fromOtzariaUpdates;
  final lock = await SingleInstance.acquire(p.join(AppPaths.userConfigDir(), 'app.lock'));
  if (lock == null) {
    if (quick) {
      _startQuickLog(args);
      QuickLog.warn('התוכנה כבר פתוחה בחלון אחר');
      QuickWindow.setUp(width: quickWindowWidth, height: quickWindowHeight, title: 'עדכון מסד הספרים');
      runApp(const _QuickAlreadyRunningApp());
    } else {
      runApp(const _AlreadyRunningApp());
    }
    return;
  }
  _instanceLock = lock;
  if (quick) {
    _startQuickLog(args);
    if (fromOtzariaUpdates) _registerForOtzariaUpdates();
    QuickWindow.setUp(width: quickWindowWidth, height: quickWindowHeight, title: 'עדכון מסד הספרים');
    if (QuickWindow.instance == null) QuickLog.warn('החלון הקומפקטי לא הוגדר (נשאר החלון הרגיל)');
    runApp(QuickUpdateApp(mirrorDir: p.join(AppPaths.programDir(), dbMirrorDirName)));
    return;
  }
  runApp(const OfflineUpdateApp());
}

/// רישום ב-Windows, כדי שעדכוני אוצריא תלמד את ה-exe שלנו ו"הפעלה" תפעיל אותו (ראו [WindowsRegistration]).
/// נכתב בכל הפעלה: הכונן הנייד עשוי לקבל אות אחרת, והנתיב ברישום מתעדכן.
void _registerForOtzariaUpdates() {
  final exe = AppPaths.selfUpdateTarget();
  if (exe == null) {
    QuickLog.warn('רישום ב-Windows: לא זוהה ה-exe המקורי, לא נרשם');
    return;
  }
  final ok = WindowsRegistration.register(exePath: exe, version: appVersion);
  QuickLog.info('רישום ב-Windows: ${ok ? "נרשם" : "נכשל"} ($exe)');
}

/// לוג ליד התוכנה, ותפיסת שגיאות לא צפויות אליו.
void _startQuickLog(List<String> args) {
  final dir = AppPaths.programDir();
  QuickLog.init(p.join(dir, 'logs'));
  QuickLog.info(
    '─── הפעלה: גרסה ${appVersion.isEmpty ? '(פיתוח)' : appVersion}, '
    '${Platform.operatingSystem} ${Platform.operatingSystemVersion}, תיקייה: $dir, exe: ${Platform.resolvedExecutable}, '
    'TEMP: ${Platform.environment['TEMP']}, ארגומנטים: $args',
  );
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    QuickLog.error('שגיאת ממשק', details.exception, details.stack);
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    QuickLog.error('שגיאה לא צפויה', error, stack);
    return false;
  };
}

class QuickUpdateApp extends StatefulWidget {
  const QuickUpdateApp({super.key, required this.mirrorDir});
  final String mirrorDir;

  @override
  State<QuickUpdateApp> createState() => _QuickUpdateAppState();
}

class _QuickUpdateAppState extends State<QuickUpdateApp> {
  late final QuickUpdateController _quick = QuickUpdateController(
    mirrorDir: widget.mirrorDir,
    smartSearch: VectorsController.new,
  )..smartSearchSettingsPath = p.join(AppPaths.userConfigDir(), 'quick_settings.json');

  @override
  void dispose() {
    _quick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _quickApp(QuickUpdateScreen(controller: _quick));
}

/// MaterialApp של החלון הקומפקטי. הגדלת הטקסט של Windows מוגבלת ל-130%, כדי שהחלון (בגודל קבוע) יכיל אותה.
Widget _quickApp(Widget home) => MaterialApp(
  title: 'עדכון מסד הספרים',
  debugShowCheckedModeBanner: false,
  theme: quickTheme(),
  locale: const Locale('he', 'IL'),
  supportedLocales: const [Locale('he', 'IL')],
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  builder: (context, child) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: 1.3,
    child: Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink()),
  ),
  home: home,
);

/// התוכנה כבר פתוחה, והפעם הופעלה מתוך עדכוני אוצריא: הודעה בחלון הקומפקטי, ויציאה אוטומטית.
class _QuickAlreadyRunningApp extends StatefulWidget {
  const _QuickAlreadyRunningApp();

  @override
  State<_QuickAlreadyRunningApp> createState() => _QuickAlreadyRunningAppState();
}

class _QuickAlreadyRunningAppState extends State<_QuickAlreadyRunningApp> {
  @override
  void initState() {
    super.initState();
    // עדכוני אוצריא ממתינה לסיום התהליך; לא משאירים אותה תקועה אם המשתמש לא סוגר.
    Future<void>.delayed(const Duration(seconds: 20), () => exit(0));
  }

  @override
  Widget build(BuildContext context) => _quickApp(QuickAlreadyRunningScreen(onClose: () => exit(0)));
}

class _AlreadyRunningApp extends StatefulWidget {
  const _AlreadyRunningApp();

  @override
  State<_AlreadyRunningApp> createState() => _AlreadyRunningAppState();
}

class _AlreadyRunningAppState extends State<_AlreadyRunningApp> {
  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(seconds: 10), () => exit(0));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('he', 'IL'),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'התוכנה כבר פתוחה. עברו לחלון הקיים.\nפתיחה כפולה עלולה לפגוע במסד הספרים.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: () => exit(0), child: const Text('סגור')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OfflineUpdateApp extends StatefulWidget {
  const OfflineUpdateApp({super.key});

  @override
  State<OfflineUpdateApp> createState() => _OfflineUpdateAppState();
}

class _OfflineUpdateAppState extends State<OfflineUpdateApp> {
  final AppController _controller = AppController();

  @override
  void initState() {
    super.initState();
    _controller.init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => MaterialApp(
        title: 'עדכון אופליין למאגר ספרים',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: _controller.themeMode,
        locale: const Locale('he', 'IL'),
        supportedLocales: const [Locale('he', 'IL')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink()),
        home: AppShell(controller: _controller),
      ),
    );
  }
}
