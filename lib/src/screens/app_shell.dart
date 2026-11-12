import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/services.dart';

import '../controllers/app_controller.dart';
import '../db/db_controller.dart';
import '../theme/app_tokens.dart';
import '../update/app_update.dart';
import '../update/update_banner.dart';
import '../widgets/activity_card.dart';
import '../widgets/message_banner.dart';
import '../widgets/status_bar.dart';
import 'copy_screen.dart';
import 'db_screen.dart';
import 'home_screen.dart';
import 'prepare_screen.dart';
import 'tabs.dart';
import 'settings_screen.dart';
import 'txt_books_screen.dart';

export 'tabs.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
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
    _db.confirm = _confirmDialog;
  }

  Future<bool> _confirmDialog(String message) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('אישור'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('המשך')),
        ],
      ),
    );
    return ok == true;
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
            final waitBefore = widget.controller.unlockWait;
            if (waitBefore > Duration.zero) {
              setSt(() => err = 'יותר מדי ניסיונות. נסו שוב בעוד ${waitBefore.inSeconds + 1} שניות');
            } else if (widget.controller.checkPassword(ctrl.text)) {
              Navigator.pop(ctx, true);
            } else {
              final w = widget.controller.unlockWait;
              setSt(() => err = w > Duration.zero
                  ? 'הסיסמה שגויה. נסו שוב בעוד ${w.inSeconds + 1} שניות'
                  : 'הסיסמה שגויה');
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
      TxtBooksScreen(controller: c, onGoDb: () => _goTo(Tabs.home)),
      CopyScreen(db: _db, app: c, locked: _locked),
      SettingsScreen(controller: c, update: _update, onLockNow: _lockNow),
      PrepareScreen(db: _db),
    ];

    final isHome = _index == Tabs.home;
    return CallbackShortcuts(
      bindings: {
        // Esc חוזר לדף הבית ממסכי המשנה (לא כשהתוכנה נעולה).
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!_locked && !isHome) _goTo(Tabs.home);
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
            automaticallyImplyLeading: false,
            leading: _locked || isHome
                ? null
                : BackButton(onPressed: () => _goTo(Tabs.home)),
            title: Text(_locked ? 'העתקה מהכונן' : Tabs.title(_index)),
            actions: [
              if (_locked)
                IconButton(
                  tooltip: 'פתיחת הנעילה',
                  icon: const Icon(FluentIcons.lock_closed_24_regular),
                  onPressed: _unlock,
                )
              else if (_index != Tabs.settings)
                IconButton(
                  tooltip: 'הגדרות',
                  icon: const Icon(FluentIcons.settings_24_regular),
                  onPressed: () => _goTo(Tabs.settings),
                ),
              const SizedBox(width: AppTokens.spaceSM),
            ],
          ),
          bottomNavigationBar: ListenableBuilder(
            listenable: Listenable.merge([c, _db]),
            builder: (context, _) => AppStatusBar(
              online: c.online,
              driveVersion: _db.mirror?.manifest.version,
              locked: _locked,
              lockEnabled: c.lockHash != null,
              appVersion: appVersion,
            ),
          ),
          body: Column(
            children: [
              if (!_locked) UpdateBanner(update: _update),
              if (c.lastMessage != null || c.activity != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppTokens.spaceMD, AppTokens.spaceMD, AppTokens.spaceMD, 0),
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
