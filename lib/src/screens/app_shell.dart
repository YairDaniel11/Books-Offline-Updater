import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../controllers/app_controller.dart';
import '../theme/app_tokens.dart';
import '../widgets/activity_card.dart';
import '../widgets/message_banner.dart';
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

  void _goTo(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (c.fatalError != null) return _FatalScreen(controller: c);
    if (c.pak == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final screens = <Widget>[
      HomeScreen(controller: c, onNavigate: _goTo),
      LibraryScreen(controller: c),
      ExtractScreen(controller: c),
      SettingsScreen(controller: c),
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
