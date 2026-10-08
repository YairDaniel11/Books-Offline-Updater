import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:path/path.dart' as p;

import '../controllers/app_controller.dart';
import '../db/db_controller.dart';
import '../db/db_manifest.dart';
import '../db/db_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/info_icon.dart';

const _defaultDbFileName = 'otzarya-unofficial-books.db';

/// לשונית "מסד ספרים (DB)": עדכון בלחיצה אחת, ש"ס וגשל, ומחשב בלי אינטרנט.
class DbScreen extends StatelessWidget {
  const DbScreen({super.key, required this.db, required this.app});

  final DbController db;
  final AppController app;

  Future<void> _pickMirror() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'בחירת תיקיית קבצי המסד');
    if (dir != null) await db.setMirrorDir(dir);
  }

  Future<void> _pickExistingDb() async {
    final f = await FilePicker.pickFile(dialogTitle: 'בחירת קובץ המסד');
    if (f?.path != null) await db.setTarget(f!.path!);
  }

  Future<void> _pickNewDbFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'בחירת תיקייה למסד החדש');
    if (dir != null) await db.setTarget(p.join(dir, _defaultDbFileName));
  }

  Future<void> _detectFromFile() async {
    final f = await FilePicker.pickFile(dialogTitle: 'בחירת עותק של המסד של המחשב השני');
    if (f?.path != null) await db.detectVersionFrom(f!.path!);
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
                    if (db.message != null) ...[
                      _Banner(db: db),
                      const SizedBox(height: AppTokens.spaceSM),
                    ],
                    if (db.activity != null) ...[
                      _ActivityCard(db: db),
                      const SizedBox(height: AppTokens.spaceMD),
                    ],
                    _MyDbCard(db: db, onPickExisting: _pickExistingDb, onPickNew: _pickNewDbFolder),
                    const SizedBox(height: AppTokens.spaceMD),
                    _ShasCard(db: db, app: app),
                    const SizedBox(height: AppTokens.spaceMD),
                    _OfflineCard(db: db, onDetect: _detectFromFile),
                    const SizedBox(height: AppTokens.spaceMD),
                    _TechnicalDetails(db: db, onPickMirror: _pickMirror),
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

TextStyle? _muted(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

Widget _row(BuildContext context, String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(k, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Expanded(child: SelectableText(v)),
        ],
      ),
    );

/// כפתור אחד לבחירת מיקום המסד: קובץ קיים, או יצירת מסד חדש בתיקייה.
class _PickLocationButton extends StatelessWidget {
  const _PickLocationButton({required this.db, required this.label, required this.onPickExisting, required this.onPickNew});
  final DbController db;
  final String label;
  final VoidCallback onPickExisting;
  final VoidCallback onPickNew;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(FluentIcons.document_24_regular),
          onPressed: onPickExisting,
          child: const Text('יש לי קובץ מסד'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(FluentIcons.add_24_regular),
          onPressed: onPickNew,
          child: const Text('אין לי מסד: צור חדש בתיקייה'),
        ),
      ],
      builder: (context, controller, _) => OutlinedButton.icon(
        onPressed: db.busy ? null : () => controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(FluentIcons.folder_open_24_regular),
        label: Text(label),
      ),
    );
  }
}

/// המסד במחשב הזה: מיקום נבחר פעם אחת (ונזכר), ועדכון בלחיצה אחת שבוחר לבד מה להוריד.
class _MyDbCard extends StatelessWidget {
  const _MyDbCard({required this.db, required this.onPickExisting, required this.onPickNew});
  final DbController db;
  final VoidCallback onPickExisting;
  final VoidCallback onPickNew;

  @override
  Widget build(BuildContext context) {
    final r = db.remote?.manifest;
    final info = db.local;
    final String status;
    if (db.targetDb.isEmpty) {
      status = 'עדיין לא נבחר מיקום למסד.';
    } else if (!File(db.targetDb).existsSync()) {
      status = r == null ? 'המסד עדיין לא קיים בנתיב הזה.' : 'המסד עדיין לא קיים בנתיב הזה. יורד ויותקן המסד העדכני.';
    } else if (db.inspecting) {
      status = 'מזהה את גרסת המסד...';
    } else if (info == null) {
      status = '';
    } else if (info.state == LocalDbState.current) {
      status = 'המסד מעודכן (גרסה ${info.version}).';
    } else if (info.state == LocalDbState.hasDelta) {
      status = 'גרסה ${info.version}. יש עדכון לגרסה ${r?.version ?? ''}.';
    } else {
      status = 'גרסת המסד אינה מזוהה. יוחלף במסד העדכני.';
    }
    final upToDate = info?.state == LocalDbState.current;
    final latest = r == null ? (db.checking ? 'בודק...' : (db.remoteError ?? 'לא נבדק')) : 'גרסה ${r.version}';
    return AppCard(
      title: 'המסד במחשב הזה',
      icon: FluentIcons.database_24_regular,
      info: 'בוחרים פעם אחת את מיקום המסד, והוא נזכר במחשב הזה. התוכנה מזהה את הגרסה ומורידה רק מה שדרוש '
          '(עדכון קטן, או המסד המלא כשאין ברירה). אוצריא חייבת להיות סגורה בזמן העדכון, והקובץ הקיים '
          'מוחלף רק אחרי שהחדש אומת.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(context, 'מיקום', db.targetDb.isEmpty ? 'לא נבחר' : db.targetDb),
          if (status.isNotEmpty) _row(context, 'מצב', status),
          _row(context, 'גרסה עדכנית', latest),
          const SizedBox(height: AppTokens.spaceSM),
          Wrap(
            spacing: AppTokens.spaceSM,
            runSpacing: AppTokens.spaceSM,
            children: [
              FilledButton.icon(
                onPressed: db.targetDb.isNotEmpty && r != null && !db.busy && !db.inspecting && !upToDate ? db.updateNow : null,
                icon: const Icon(FluentIcons.arrow_download_24_regular),
                label: Text(db.targetDb.isNotEmpty && !File(db.targetDb).existsSync() ? 'הורד והתקן' : 'עדכן את המסד'),
              ),
              _PickLocationButton(
                db: db,
                label: db.targetDb.isEmpty ? 'בחר מיקום המסד' : 'שנה מיקום',
                onPickExisting: onPickExisting,
                onPickNew: onPickNew,
              ),
              OutlinedButton.icon(
                onPressed: db.checking || db.busy ? null : db.checkRemote,
                icon: const Icon(FluentIcons.arrow_sync_24_regular),
                label: Text(db.checking ? 'בודק...' : 'בדוק גרסה'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// ש"ס וגשל אינם בתוך המסד: מורדים לצד קובץ המסד ומחולצים לתיקייה "תלמוד בבלי", לפי סדרים.
class _ShasCard extends StatelessWidget {
  const _ShasCard({required this.db, required this.app});
  final DbController db;
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final item = app.shasItem;
    final dir = db.shasDestDir;
    final upToDate = item != null && db.shasDownloaded && db.shasHash == item.hash;
    final can = item != null && dir != null && app.online && !app.busy && !db.busy;
    return AppCard(
      title: 'ש"ס וגשל',
      icon: FluentIcons.book_24_regular,
      info: 'ש"ס וגשל אינם כלולים במסד. הם יורדים לצד קובץ המסד, לתיקייה בשם "תלמוד בבלי", מחולקים לפי סדרים.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (dir != null) _row(context, 'תיקיית יעד', p.join(dir, 'תלמוד בבלי')),
          const SizedBox(height: AppTokens.spaceSM),
          Wrap(
            spacing: AppTokens.spaceSM,
            runSpacing: AppTokens.spaceSM,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: can && !upToDate ? db.downloadShas : null,
                icon: const Icon(FluentIcons.arrow_download_24_regular),
                label: Text(db.shasDownloaded && !upToDate ? 'עדכן את ש"ס וגשל' : 'הורד את ש"ס וגשל'),
              ),
              if (upToDate) Text('ש"ס וגשל מעודכנים', style: _muted(context)),
              if (dir == null) Text('בחרו קודם את מיקום המסד', style: _muted(context)),
              if (dir != null && item == null)
                Text(app.online ? 'לא נמצא ברשימת הספרים' : 'זמין רק עם חיבור לרשת', style: _muted(context)),
            ],
          ),
        ],
      ),
    );
  }
}

/// מחשב בלי אינטרנט: במחשב מחובר מכינים קבצים, ובמחשב הלא מחובר מתקינים אותם.
class _OfflineCard extends StatelessWidget {
  const _OfflineCard({required this.db, required this.onDetect});
  final DbController db;
  final VoidCallback onDetect;

  @override
  Widget build(BuildContext context) {
    final r = db.remote?.manifest;
    final can = r != null && !db.busy;
    final bytes = db.downloadBytes;
    final sel = db.selectedDownload;
    final delta = sel.isNotEmpty && sel.first.isDelta;
    final plan = db.plan;
    final cs = Theme.of(context).colorScheme;
    final sub = Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600);

    return AppCard(
      title: 'מחשב בלי אינטרנט',
      icon: FluentIcons.cloud_off_24_regular,
      info: 'שני שלבים: במחשב מחובר מכינים קבצים בתיקייה, מעבירים אותה (למשל בדיסק און קי) למחשב שאין בו רשת, '
          'ושם מתקינים ממנה. אם יש עותק של המסד של המחשב השני, בחרו אותו והתוכנה תוריד רק את מה שחסר לו; '
          'בלי עותק יורד המסד המלא.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('1. במחשב מחובר: הכנת קבצים', style: sub),
          const SizedBox(height: AppTokens.spaceSM),
          Wrap(
            spacing: AppTokens.spaceSM,
            runSpacing: AppTokens.spaceSM,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: can && !db.inspecting ? onDetect : null,
                icon: const Icon(FluentIcons.search_24_regular),
                label: Text(db.inspecting ? 'מזהה...' : 'בחר עותק של המסד של המחשב השני'),
              ),
              if (db.fromVersion != null)
                TextButton(onPressed: db.busy ? null : db.clearTransferVersion, child: const Text('אין לו מסד')),
            ],
          ),
          const SizedBox(height: AppTokens.spaceSM),
          Text(r == null
              ? 'ההכנה זמינה רק עם חיבור לרשת.'
              : delta
                  ? 'יורד: עדכון מגרסה ${db.fromVersion} לגרסה ${r.version}.'
                  : 'יורד: המסד המלא (גרסה ${r.version}).'),
          const SizedBox(height: AppTokens.spaceSM),
          FilledButton.icon(
            onPressed: can && sel.isNotEmpty ? db.download : null,
            icon: const Icon(FluentIcons.arrow_download_24_regular),
            label: Text(bytes == 0 && sel.isNotEmpty ? 'הכול כבר הורד' : 'הכן קבצים (${DbController.formatBytes(bytes)})'),
          ),
          const Padding(padding: EdgeInsets.symmetric(vertical: AppTokens.spaceMD), child: Divider(height: 1)),
          Text('2. במחשב בלי אינטרנט: התקנה', style: sub),
          const SizedBox(height: AppTokens.spaceSM),
          if (db.inspecting)
            const LinearProgressIndicator()
          else if (plan != null)
            Text(plan.message, style: TextStyle(color: plan.action == InstallAction.blocked ? cs.error : null))
          else if (db.mirror == null)
            Text('בתיקייה עדיין אין קבצים. העבירו אליה את הקבצים שהוכנו, או בחרו תיקייה אחרת בפרטים הטכניים.',
                style: _muted(context))
          else if (db.targetDb.isEmpty)
            Text('בחרו למעלה את מיקום המסד.', style: _muted(context)),
          const SizedBox(height: AppTokens.spaceSM),
          FilledButton.icon(
            onPressed: plan != null && plan.canRun && !db.busy && !db.inspecting ? db.install : null,
            icon: const Icon(FluentIcons.checkmark_24_regular),
            label: Text(plan?.action == InstallAction.delta ? 'עדכן את המסד מהקבצים' : 'התקן את המסד מהקבצים'),
          ),
        ],
      ),
    );
  }
}

/// פרטים למתקדמים בלבד: גדלים, קבצים שנשמרו ותיקיית הקבצים. סגור כברירת מחדל.
class _TechnicalDetails extends StatelessWidget {
  const _TechnicalDetails({required this.db, required this.onPickMirror});
  final DbController db;
  final VoidCallback onPickMirror;

  static String _status(DbArtifact a, String dir) {
    final s = DbService.partsStatus(a, dir);
    if (s.present == s.total) return 'קיים (${DbController.formatBytes(a.downloadSize)})';
    if (s.present == 0) return 'לא הורד';
    return 'חלקי (${s.present} מתוך ${s.total} חלקים)';
  }

  @override
  Widget build(BuildContext context) {
    final r = db.remote?.manifest;
    final m = db.mirror?.manifest;
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(FluentIcons.wrench_24_regular),
          title: const Text('פרטים טכניים'),
          childrenPadding: const EdgeInsets.fromLTRB(AppTokens.spaceMD, 0, AppTokens.spaceMD, AppTokens.spaceMD),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (r != null) ...[
              _row(context, 'גרסה ברשת', '${r.version}'),
              _row(context, 'מסד מלא', DbController.formatBytes(r.full.downloadSize)),
              if (r.deltas.isNotEmpty)
                _row(context, 'קבצי עדכון',
                    r.deltas.map((d) => 'מגרסה ${d.fromVersion}: ${DbController.formatBytes(d.downloadSize)}').join('\n')),
              if (r.notes.isNotEmpty) _row(context, 'הערות', r.notes),
              _row(context, 'אימות', 'הקבצים אומתו כמקוריים'),
            ],
            const SizedBox(height: AppTokens.spaceSM),
            Row(children: [
              Text('תיקיית קבצי המסד', style: Theme.of(context).textTheme.titleSmall),
              const InfoIcon('כאן נשמרים הקבצים שמורידים להעברה. את התיקייה מעבירים למחשב שאין בו רשת ומתקינים ממנה.'),
            ]),
            _row(context, 'מיקום', db.mirrorDir),
            if (m != null) ...[
              _row(context, 'גרסה בתיקייה', '${m.version}'),
              _row(context, 'מסד מלא', _status(m.full, db.mirrorDir)),
              for (final d in m.deltas) _row(context, 'עדכון מגרסה ${d.fromVersion}', _status(d, db.mirrorDir)),
            ] else
              _row(context, 'מצב', db.mirrorError ?? 'עדיין לא הורדו כאן קבצים'),
            const SizedBox(height: AppTokens.spaceSM),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: db.busy ? null : onPickMirror,
                icon: const Icon(FluentIcons.folder_open_24_regular),
                label: const Text('שנה תיקייה'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.db});
  final DbController db;

  @override
  Widget build(BuildContext context) {
    final a = db.activity!;
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(a.title, style: theme.textTheme.titleMedium)),
            TextButton(
              onPressed: a.cancelled ? null : db.cancel,
              child: Text(a.cancelled ? 'עוצר...' : 'עצור'),
            ),
          ]),
          if (a.detail.isNotEmpty) ...[
            const SizedBox(height: AppTokens.spaceXS),
            Text(a.detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: _muted(context)),
          ],
          const SizedBox(height: AppTokens.spaceSM),
          ClipRRect(
            borderRadius: AppTokens.borderRadiusAll,
            child: LinearProgressIndicator(value: a.progress),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.db});
  final DbController db;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final err = db.messageIsError;
    final bg = err ? cs.errorContainer : cs.secondaryContainer;
    final fg = err ? cs.onErrorContainer : cs.onSecondaryContainer;
    return Container(
      padding: const EdgeInsetsDirectional.only(start: AppTokens.spaceMD, end: AppTokens.spaceXS),
      decoration: BoxDecoration(color: bg, borderRadius: AppTokens.borderRadiusAll),
      child: Row(children: [
        Icon(err ? Icons.error_outline : Icons.check_circle_outline, color: fg, size: 20),
        const SizedBox(width: AppTokens.spaceSM),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceSM),
            child: SelectableText(db.message!, style: TextStyle(color: fg)),
          ),
        ),
        IconButton(
          tooltip: 'סגור',
          icon: Icon(Icons.close, color: fg, size: 20),
          onPressed: db.clearMessage,
        ),
      ]),
    );
  }
}
