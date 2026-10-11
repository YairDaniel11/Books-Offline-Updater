import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:path/path.dart' as p;

import '../controllers/app_controller.dart';
import '../db/db_controller.dart';
import '../db/db_manifest.dart' show dbLibraryId;
import '../theme/app_tokens.dart';
import '../widgets/activity_card.dart';
import '../widgets/app_card.dart';
import '../widgets/message_banner.dart';
import 'extract_screen.dart';

/// "העתקת הספרים": המסך של המחשב שאין בו אינטרנט. כפתור אחד גדול שמעתיק את המסד
/// ישר למקום שבו אוצריא שומרת אותו, עם התקדמות גדולה וברורה מול העיניים.
class CopyScreen extends StatelessWidget {
  const CopyScreen({super.key, required this.db, required this.app, required this.locked});

  final DbController db;
  final AppController app;

  /// כשהתוכנה נעולה מסתירים את האפשרויות שמשנות מיקומים.
  final bool locked;

  Future<void> _pickTarget() async {
    final f = await FilePicker.pickFile(dialogTitle: 'בחירת קובץ המסד של אוצריא');
    if (f?.path != null) await db.setTarget(f!.path!);
  }

  /// מחשב שאין בו מסד: בוחרים תיקייה, והמסד ייווצר בה.
  Future<void> _pickNewFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'בחירת תיקייה למסד');
    if (dir != null) await db.setTarget(p.join(dir, '$dbLibraryId.db'));
  }

  Future<void> _pickMirror() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'בחירת התיקייה שבה נמצאים קבצי הספרים');
    if (dir != null) await db.setMirrorDir(dir);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([db, app]),
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(AppTokens.spaceMD),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DbCopyCard(
                      db: db,
                      locked: locked,
                      onPickTarget: _pickTarget,
                      onPickNewFolder: _pickNewFolder,
                      onPickMirror: _pickMirror,
                    ),
                    if (app.pakFileCount > 0) ...[
                      const SizedBox(height: AppTokens.spaceMD),
                      _TxtCopyCard(app: app, db: db),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DbCopyCard extends StatelessWidget {
  const _DbCopyCard({
    required this.db,
    required this.locked,
    required this.onPickTarget,
    required this.onPickNewFolder,
    required this.onPickMirror,
  });
  final DbController db;
  final bool locked;
  final VoidCallback onPickTarget;
  final VoidCallback onPickNewFolder;
  final VoidCallback onPickMirror;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m = db.mirror?.manifest;
    final plan = db.plan;
    final a = db.activity;

    // מצב אחד ברור, בצבע: מעודכן (ירוק), יש מה להעתיק (בולט), או בעיה.
    final _Status status;
    if (db.mirror == null) {
      status = _Status.problem(
        'לא נמצאו קבצי ספרים להעתקה.',
        'ודאו שהתיקייה "$dbMirrorDirName" נמצאת ליד התוכנה (בדיסק און קי).',
      );
    } else if (db.targetDb.isEmpty) {
      status = _Status.problem(
        'לא נמצאה אוצריא במחשב הזה.',
        'התקינו את אוצריא והפעילו אותה פעם אחת, או בחרו ידנית את קובץ המסד.',
      );
    } else if (db.inspecting || (plan == null && a == null)) {
      status = _Status.working('בודק את הספרים שבמחשב...');
    } else if (plan == null) {
      status = _Status.working('');
    } else {
      switch (plan.action) {
        case InstallAction.none:
          status = _Status.ok('הספרים במחשב הזה מעודכנים', 'גרסה ${m?.version}. אין צורך לעשות דבר.');
        case InstallAction.full when !File(db.targetDb).existsSync():
          status = _Status.update(
            'הספרים עוד לא מותקנים במחשב הזה',
            'לחצו על הכפתור כדי להתקין (גרסה ${m?.version}). הספרים יופיעו באוצריא מעצמם.',
          );
        case InstallAction.delta:
        case InstallAction.full:
          final from = db.local?.version;
          status = _Status.update(
            'יש ספרים חדשים להעתקה',
            from != null ? 'גרסה ${m?.version} (במחשב הזה: גרסה $from).' : 'גרסה ${m?.version}.',
          );
        case InstallAction.blocked:
          status = _Status.problem('אי אפשר להעתיק', plan.message);
      }
    }

    final can = plan != null && plan.canRun && !db.busy && !db.inspecting;

    return AppCard(
      title: 'העתקת הספרים לאוצריא',
      icon: FluentIcons.copy_arrow_right_24_regular,
      info: 'מעתיק את מסד הספרים שהובא בדיסק און קי ישר למקום שבו אוצריא שומרת אותו. '
          'יש לסגור את אוצריא לפני ההעתקה. המסד הקיים מוחלף רק אחרי שהחדש נבדק ונמצא תקין.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (a == null) _StatusBox(status: status),
          if (a != null) _BigProgress(db: db),
          if (a == null && db.message != null) ...[
            const SizedBox(height: AppTokens.spaceMD),
            _ResultBox(text: db.message!, error: db.messageIsError, onClose: db.clearMessage),
          ],
          const SizedBox(height: AppTokens.spaceLG),
          SizedBox(
            height: 64,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                shape: const RoundedRectangleBorder(borderRadius: AppTokens.borderRadiusAll),
              ),
              onPressed: can ? db.install : null,
              icon: const Icon(FluentIcons.arrow_download_24_filled, size: 28),
              label: const Text('העתק את הספרים לאוצריא'),
            ),
          ),
          const SizedBox(height: AppTokens.spaceSM),
          Text(
            'לפני ההעתקה יש לסגור את אוצריא.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          if (!locked) ...[
            const SizedBox(height: AppTokens.spaceMD),
            const Divider(height: 1),
            const SizedBox(height: AppTokens.spaceSM),
            _PathRow(
              label: 'קובץ המסד של אוצריא',
              value: db.targetDb.isEmpty ? 'לא נמצא' : db.targetDb,
              menu: [
                ('יש לי קובץ מסד', FluentIcons.document_24_regular, onPickTarget),
                ('אין מסד: בחר תיקייה למסד החדש', FluentIcons.folder_add_24_regular, onPickNewFolder),
              ],
              enabled: !db.busy,
              extra: db.otzariaDbPath != null && db.otzariaDbPath != db.targetDb && !db.busy
                  ? TextButton(onPressed: db.useOtzariaLocation, child: const Text('השתמש במיקום של אוצריא'))
                  : null,
            ),
            _PathRow(
              label: 'קבצי הספרים להעתקה',
              value: db.mirrorDir,
              menu: [('בחר תיקייה', FluentIcons.folder_open_24_regular, onPickMirror)],
              enabled: !db.busy,
            ),
          ],
        ],
      ),
    );
  }
}

enum _Kind { ok, update, problem, working }

class _Status {
  _Status(this.kind, this.title, this.detail);
  _Status.ok(String t, String d) : this(_Kind.ok, t, d);
  _Status.update(String t, String d) : this(_Kind.update, t, d);
  _Status.problem(String t, String d) : this(_Kind.problem, t, d);
  _Status.working(String t) : this(_Kind.working, t, '');
  final _Kind kind;
  final String title;
  final String detail;
}

class _StatusBox extends StatelessWidget {
  const _StatusBox({required this.status});
  final _Status status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final (Color bg, Color fg, IconData icon) = switch (status.kind) {
      _Kind.ok => (
          dark ? const Color(0xFF1E3A24) : const Color(0xFFE3F4E6),
          dark ? const Color(0xFFB8E6C1) : const Color(0xFF1B5E20),
          FluentIcons.checkmark_circle_24_filled,
        ),
      _Kind.update => (cs.primaryContainer, cs.onPrimaryContainer, FluentIcons.arrow_circle_down_24_filled),
      _Kind.problem => (cs.errorContainer, cs.onErrorContainer, FluentIcons.warning_24_filled),
      _Kind.working => (cs.surfaceContainerHighest, cs.onSurfaceVariant, FluentIcons.hourglass_half_24_regular),
    };
    return Container(
      padding: const EdgeInsets.all(AppTokens.spaceMD),
      decoration: BoxDecoration(color: bg, borderRadius: AppTokens.borderRadiusAll),
      child: Row(children: [
        Icon(icon, color: fg, size: 40),
        const SizedBox(width: AppTokens.spaceMD),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(status.title, style: theme.textTheme.titleLarge?.copyWith(color: fg, fontWeight: FontWeight.w600)),
              if (status.detail.isNotEmpty) ...[
                const SizedBox(height: AppTokens.spaceXS),
                Text(status.detail, style: theme.textTheme.bodyLarge?.copyWith(color: fg)),
              ],
            ],
          ),
        ),
        if (status.kind == _Kind.working)
          SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3, color: fg)),
      ]),
    );
  }
}

/// התקדמות גדולה: אחוזים בגדול, פס עבה וכפתור עצירה.
class _BigProgress extends StatelessWidget {
  const _BigProgress({required this.db});
  final DbController db;

  @override
  Widget build(BuildContext context) {
    final a = db.activity!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final pct = a.progress == null ? null : (a.progress! * 100).floor();
    return Container(
      padding: const EdgeInsets.all(AppTokens.spaceMD),
      decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: AppTokens.borderRadiusAll),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: Text(a.title,
                  style: theme.textTheme.titleLarge?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w600)),
            ),
            if (pct != null)
              Text('$pct%',
                  style: theme.textTheme.headlineMedium?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: AppTokens.spaceSM),
          ClipRRect(
            borderRadius: AppTokens.borderRadiusAll,
            child: LinearProgressIndicator(value: a.progress, minHeight: 14),
          ),
          const SizedBox(height: AppTokens.spaceSM),
          Row(children: [
            Expanded(
              child: Text(
                a.detail.isEmpty ? 'נא לא לסגור את התוכנה.' : '${a.detail}. נא לא לסגור את התוכנה.',
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.onPrimaryContainer),
              ),
            ),
            TextButton(onPressed: a.cancelled ? null : db.cancel, child: Text(a.cancelled ? 'עוצר...' : 'עצור')),
          ]),
        ],
      ),
    );
  }
}

class _ResultBox extends StatelessWidget {
  const _ResultBox({required this.text, required this.error, required this.onClose});
  final String text;
  final bool error;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = error ? cs.errorContainer : cs.secondaryContainer;
    final fg = error ? cs.onErrorContainer : cs.onSecondaryContainer;
    return Container(
      padding: const EdgeInsetsDirectional.only(start: AppTokens.spaceMD, end: AppTokens.spaceXS),
      decoration: BoxDecoration(color: bg, borderRadius: AppTokens.borderRadiusAll),
      child: Row(children: [
        Icon(error ? FluentIcons.error_circle_24_regular : FluentIcons.checkmark_circle_24_regular, color: fg),
        const SizedBox(width: AppTokens.spaceSM),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceSM),
            child: SelectableText(text, style: TextStyle(color: fg, fontSize: AppTokens.fontLG)),
          ),
        ),
        IconButton(tooltip: 'סגור', icon: Icon(Icons.close, color: fg, size: 20), onPressed: onClose),
      ]),
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({required this.label, required this.value, required this.menu, required this.enabled, this.extra});
  final String label;
  final String value;

  /// אפשרויות כפתור "שנה": אחת = לחיצה ישירה, כמה = תפריט.
  final List<(String, IconData, VoidCallback)> menu;
  final bool enabled;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 150, child: Text(label, style: muted)),
        Expanded(child: SelectableText(value, style: muted)),
        ?extra,
        if (menu.length == 1)
          TextButton(onPressed: enabled ? menu.first.$3 : null, child: const Text('שנה'))
        else
          MenuAnchor(
            menuChildren: [
              for (final (text, icon, onTap) in menu)
                MenuItemButton(leadingIcon: Icon(icon), onPressed: onTap, child: Text(text)),
            ],
            builder: (context, c, _) => TextButton(
              onPressed: enabled ? () => c.isOpen ? c.close() : c.open() : null,
              child: const Text('שנה'),
            ),
          ),
      ]),
    );
  }
}

/// ספרים בפורמט TXT מתוך קובץ המאגר: חילוץ הכול לתיקייה, או בחירת ספרים מסוימים.
class _TxtCopyCard extends StatelessWidget {
  const _TxtCopyCard({required this.app, required this.db});
  final AppController app;
  final DbController db;

  Future<void> _extractAll() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'בחירת התיקייה שאליה יועתקו הספרים',
      initialDirectory: db.targetDb.isEmpty ? null : p.dirname(db.targetDb),
    );
    if (dir != null) await app.extract(dir);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return AppCard(
      title: 'ספרים בפורמט TXT',
      icon: FluentIcons.document_text_24_regular,
      info: 'רק למי שהביאו לו ספרים בפורמט TXT (קובץ המאגר). מי שמשתמש במסד הספרים אינו צריך את זה.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${app.pakFileCount} קבצים מוכנים להעתקה.', style: muted),
          const SizedBox(height: AppTokens.spaceSM),
          Wrap(
            spacing: AppTokens.spaceSM,
            runSpacing: AppTokens.spaceSM,
            children: [
              OutlinedButton.icon(
                onPressed: app.busy ? null : _extractAll,
                icon: const Icon(FluentIcons.folder_arrow_right_24_regular),
                label: const Text('העתק את כל ספרי ה-TXT...'),
              ),
              TextButton.icon(
                onPressed: app.busy
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => Scaffold(
                            appBar: AppBar(title: const Text('בחירת ספרים להעתקה')),
                            body: ListenableBuilder(
                              listenable: app,
                              builder: (context, _) => Column(children: [
                                if (app.lastMessage != null || app.activity != null)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        AppTokens.spaceMD, AppTokens.spaceMD, AppTokens.spaceMD, 0),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
                                      child: app.activity != null
                                          ? ActivityCard(controller: app)
                                          : MessageBanner(controller: app),
                                    ),
                                  ),
                                Expanded(child: ExtractScreen(controller: app)),
                              ]),
                            ),
                          ),
                        )),
                icon: const Icon(FluentIcons.checkbox_checked_24_regular),
                label: const Text('בחירת ספרים מסוימים'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
