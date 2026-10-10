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
import 'copy_screen.dart';
import 'db_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'txt_books_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

/// אינדקסי הלשוניות בסרגל הצד.
abstract final class Tabs {
  static const home = 0, db = 1, txt = 2, copy = 3, settings = 4;
}

class _AppShellState extends State<AppShell> {
  int _index = Tabs.home;
  late final DbController _db = DbController(widget.controller);
  bool _dbStarted = false;

  /// נעול: רק מסך העתקת הספרים, בלי סרגל הצד, עד הקלדת הסיסמה.
  bool _locked = false;
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

  void _goTo(int i) => setState(() => _index = i);

  void _lockNow() => setState(() {
        _locked = true;
        _index = Tabs.copy;
      });

  Future<void> _unlock() async {
    final ctrl = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          void submit() {
            if (widget.controller.checkPassword(ctrl.text)) {
              Navigator.pop(ctx, true);
            } else {
              setSt(() => err = 'הסיסמה שגויה');
            }
          }

          return AlertDialog(
            title: const Text('פתיחת הנעילה'),
            content: TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(labelText: 'סיסמה', errorText: err),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
              FilledButton(onPressed: submit, child: const Text('פתח')),
            ],
          );
        },
      ),
    );
    if (ok == true) setState(() => _locked = false);
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
      // ההגדרות נטענו עם המאגר: מסך הפתיחה והנעילה נקבעים כאן, פעם אחת.
      _locked = c.lockHash != null;
      _index = _locked
          ? Tabs.copy
          : switch (c.startScreen) {
              StartScreen.home => Tabs.home,
              StartScreen.db => Tabs.db,
              StartScreen.copy => Tabs.copy,
            };
      WidgetsBinding.instance.addPostFrameCallback((_) => _db.init());
    }

    final screens = <Widget>[
      HomeScreen(controller: c, db: _db, onNavigate: _goTo),
      DbScreen(db: _db, app: c),
      TxtBooksScreen(controller: c, onGoDb: () => _goTo(Tabs.db)),
      CopyScreen(db: _db, app: c, locked: _locked),
      SettingsScreen(controller: c, update: _update, onLockNow: _lockNow),
    ];

    return Scaffold(
      body: Row(
        children: [
          if (_locked)
            Padding(
              padding: const EdgeInsets.all(AppTokens.spaceSM),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: IconButton(
                  tooltip: 'פתיחת הנעילה',
                  icon: const Icon(FluentIcons.lock_closed_24_regular),
                  onPressed: _unlock,
                ),
              ),
            )
          else
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
                icon: Icon(FluentIcons.database_24_regular),
                selectedIcon: Icon(FluentIcons.database_24_filled),
                label: Text('מסד ספרים (DB)', textAlign: TextAlign.center),
              ),
              NavigationRailDestination(
                icon: Icon(FluentIcons.document_text_24_regular),
                selectedIcon: Icon(FluentIcons.document_text_24_filled),
                label: Text('ספרים בודדים (TXT)', textAlign: TextAlign.center),
              ),
              NavigationRailDestination(
                icon: Icon(FluentIcons.copy_arrow_right_24_regular),
                selectedIcon: Icon(FluentIcons.copy_arrow_right_24_filled),
                label: Text('העתקת הספרים', textAlign: TextAlign.center),
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
                if (!_locked) UpdateBanner(update: _update),
                if (!_locked)
                  _DbUpdateBanner(
                    db: _db,
                    onUpdate: () {
                      _goTo(Tabs.home);
                      _db.updateNow();
                    },
                  ),
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

/// התראה בולטת בראש כל המסכים כשיש גרסה חדשה של מסד הספרים.
class _DbUpdateBanner extends StatefulWidget {
  const _DbUpdateBanner({required this.db, required this.onUpdate});
  final DbController db;
  final VoidCallback onUpdate;

  @override
  State<_DbUpdateBanner> createState() => _DbUpdateBannerState();
}

class _DbUpdateBannerState extends State<_DbUpdateBanner> {
  int? _dismissedVersion;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.db,
      builder: (context, _) {
        final db = widget.db;
        final v = db.remote?.manifest.version;
        if (!db.updateAvailable || db.busy || v == null || _dismissedVersion == v) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final cs = theme.colorScheme;
        final from = db.local?.version;
        return Padding(
          padding: const EdgeInsets.fromLTRB(AppTokens.spaceMD, AppTokens.spaceMD, AppTokens.spaceMD, 0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
              child: Container(
                padding: const EdgeInsets.all(AppTokens.spaceMD),
                decoration: BoxDecoration(color: cs.primary, borderRadius: AppTokens.borderRadiusAll),
                child: Row(children: [
                  Icon(FluentIcons.alert_badge_24_filled, color: cs.onPrimary, size: 32),
                  const SizedBox(width: AppTokens.spaceMD),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('יש עדכון למסד הספרים',
                            style: theme.textTheme.titleMedium?.copyWith(color: cs.onPrimary, fontWeight: FontWeight.w700)),
                        Text(
                          from != null ? 'גרסה $v זמינה (אצלך גרסה $from).' : 'גרסה $v זמינה.',
                          style: TextStyle(color: cs.onPrimary),
                        ),
                      ],
                    ),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: cs.onPrimary, foregroundColor: cs.primary),
                    onPressed: widget.onUpdate,
                    child: const Text('עדכן עכשיו'),
                  ),
                  const SizedBox(width: AppTokens.spaceXS),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: cs.onPrimary),
                    onPressed: () => setState(() => _dismissedVersion = v),
                    child: const Text('אחר כך'),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
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
