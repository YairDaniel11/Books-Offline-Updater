import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../controllers/app_controller.dart';
import '../db/db_controller.dart';
import '../theme/app_tokens.dart';
import '../update/app_update.dart';
import '../update/update_banner.dart';
import '../widgets/activity_card.dart';
import '../widgets/message_banner.dart';
import 'db_screen.dart';
import 'extract_screen.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  late final DbController _db = DbController(widget.controller);
  bool _dbStarted = false;
  late final UpdateController _update = UpdateController(beforeRestart: () async => widget.controller.pak?.close());

  @override
  void initState() {
    super.initState();
    UpdateController.cleanupLeftovers();
    _update.check();
  }

  @override
  void dispose() {
    _update.dispose();
    _db.dispose();
    super.dispose();
  }

  void _goTo(int i) {
    setState(() => _index = i);
    // בדיקת הרשת של המסד רק כשנכנסים ללשונית (לא בכל פתיחה של התוכנה).
    if (i == 3 && !_dbStarted) {
      _dbStarted = true;
      _db.init();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (c.fatalError != null) return _FatalScreen(controller: c);
    if (c.pak == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // תיקיית הנתונים ידועה רק אחרי שהמאגר נפתח; מאתחלים את המסד פעם אחת כדי שדף הבית יציג את הגרסה.
    if (!_dbStarted) {
      _dbStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _db.init());
    }

    final screens = <Widget>[
      HomeScreen(controller: c, db: _db, onNavigate: _goTo),
      LibraryScreen(controller: c),
      ExtractScreen(controller: c),
      DbScreen(db: _db),
      SettingsScreen(controller: c, update: _update),
    ];

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: _goTo,
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(FluentIcons.home_24_regular),
                selectedIcon: Icon(FluentIcons.home_24_filled),
                label: Text('בית'),
              ),
              NavigationRailDestination(
                icon: Icon(FluentIcons.library_24_regular),
                selectedIcon: Icon(FluentIcons.library_24_filled),
                label: Text('ספרייה'),
              ),
              NavigationRailDestination(
                icon: Icon(FluentIcons.arrow_download_24_regular),
                selectedIcon: Icon(FluentIcons.arrow_download_24_filled),
                label: Text('חילוץ'),
              ),
              NavigationRailDestination(
                icon: Icon(FluentIcons.database_24_regular),
                selectedIcon: Icon(FluentIcons.database_24_filled),
                label: Text('מסד'),
              ),
              NavigationRailDestination(
                icon: Icon(FluentIcons.settings_24_regular),
                selectedIcon: Icon(FluentIcons.settings_24_filled),
                label: Text('הגדרות'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                UpdateBanner(update: _update),
                if (c.lastMessage != null || c.activity != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(AppTokens.spaceMD, AppTokens.spaceXL, AppTokens.spaceMD, 0),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (c.lastMessage != null) ...[
                              MessageBanner(controller: c),
                              const SizedBox(height: AppTokens.spaceSM),
                            ],
                            if (c.activity != null) ActivityCard(controller: c),
                          ],
                        ),
                      ),
                    ),
                  ),
                Expanded(child: IndexedStack(index: _index, children: screens)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FatalScreen extends StatelessWidget {
  const _FatalScreen({required this.controller});

  final AppController controller;

  Future<void> _pick() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'בחירת תיקיית המאגר');
    if (dir != null) await controller.changeDataDir(dir);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spaceLG),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.error_circle_24_regular, size: 48, color: cs.error),
                const SizedBox(height: AppTokens.spaceMD),
                SelectableText(controller.fatalError!, textAlign: TextAlign.center),
                const SizedBox(height: AppTokens.spaceLG),
                FilledButton.icon(
                  onPressed: _pick,
                  icon: const Icon(FluentIcons.folder_open_24_regular),
                  label: const Text('בחר תיקייה אחרת'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
