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
import 'src/services/app_paths.dart';
import 'src/update/app_update.dart' show appVersion;
import 'src/services/single_instance.dart';
import 'src/screens/app_shell.dart';
import 'src/theme/app_theme.dart';

// נשמר לכל חיי התהליך; המערכת משחררת אותו בסיום או בקריסה.
// ignore: unused_element
SingleInstance? _instanceLock;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final lock = await SingleInstance.acquire(p.join(AppPaths.userConfigDir(), 'app.lock'));
  if (lock == null) {
    runApp(const _AlreadyRunningApp());
    return;
  }
  _instanceLock = lock;
  // מתוך עדכוני אוצריא (או --quick): חלון קטן לעדכון המסד בלבד.
  if (args.contains('--quick') || AppPaths.launchedFromOtzariaUpdates()) {
    _startQuickLog(args);
    QuickWindow.setUp(width: quickWindowWidth, height: quickWindowHeight, title: 'עדכון מסד הספרים');
    if (QuickWindow.instance == null) QuickLog.warn('החלון הקומפקטי לא הוגדר (נשאר החלון הרגיל)');
    runApp(QuickUpdateApp(mirrorDir: p.join(AppPaths.programDir(), dbMirrorDirName)));
    return;
  }
  runApp(const OfflineUpdateApp());
}

/// לוג ליד התוכנה, ותפיסת שגיאות לא צפויות אליו.
void _startQuickLog(List<String> args) {
  final dir = AppPaths.programDir();
  QuickLog.init(p.join(dir, 'logs'));
  QuickLog.info(
    '─── הפעלה: גרסה ${appVersion.isEmpty ? '(פיתוח)' : appVersion}, '
    'Windows ${Platform.operatingSystemVersion}, תיקייה: $dir, exe: ${Platform.resolvedExecutable}, '
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
  late final QuickUpdateController _quick = QuickUpdateController(mirrorDir: widget.mirrorDir);

  @override
  void dispose() {
    _quick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink()),
      home: QuickUpdateScreen(controller: _quick),
    );
  }
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
