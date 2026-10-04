import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/controllers/app_controller.dart';
import 'src/screens/app_shell.dart';
import 'src/theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OfflineUpdateApp());
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
