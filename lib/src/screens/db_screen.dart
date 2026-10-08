import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:path/path.dart' as p;

import '../db/db_controller.dart';
import '../db/db_manifest.dart';
import '../db/db_service.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_card.dart';

const _defaultDbFileName = 'otzarya-unofficial-books.db';

/// לשונית "מסד אוצריא": הורדה למראה במחשב מחובר, והתקנה/עדכון ממנה במחשב חסום.
class DbScreen extends StatelessWidget {
  const DbScreen({super.key, required this.db});

  final DbController db;

  Future<void> _pickMirror() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'בחירת תיקיית המסד (מראה)');
    if (dir != null) await db.setMirrorDir(dir);
  }

  Future<void> _pickExistingDb() async {
    final f = await FilePicker.pickFile(dialogTitle: 'בחירת קובץ המסד הקיים');
    if (f?.path != null) await db.setTarget(f!.path!);
  }

  Future<void> _pickNewDbFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'בחירת תיקייה למסד החדש');
    if (dir != null) await db.setTarget(p.join(dir, _defaultDbFileName));
  }

  Future<void> _detectFromFile() async {
    final f = await FilePicker.pickFile(dialogTitle: 'בחירת קובץ המסד הקיים (לזיהוי הגרסה)');
    if (f?.path != null) await db.detectVersionFrom(f!.path!);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: db,
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
                    _LatestCard(db: db),
                    const SizedBox(height: AppTokens.spaceMD),
                    _MirrorCard(db: db, onPick: _pickMirror),
                    const SizedBox(height: AppTokens.spaceMD),
                    _DownloadCard(db: db, onDetect: _detectFromFile),
                    const SizedBox(height: AppTokens.spaceMD),
                    _InstallCard(db: db, onPickExisting: _pickExistingDb, onPickNew: _pickNewDbFolder),
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

TextStyle? _muted(BuildContext context) => Theme.of(context)
    .textTheme
    .bodySmall
    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

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

class _LatestCard extends StatelessWidget {
  const _LatestCard({required this.db});
  final DbController db;

  @override
  Widget build(BuildContext context) {
    final r = db.remote?.manifest;
    return AppCard(
      title: 'הגרסה העדכנית ברשת',
      icon: FluentIcons.cloud_24_regular,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (r != null) ...[
            _row(context, 'גרסה', '${r.version}  (חתימה אומתה)'),
            _row(context, 'מסד מלא', DbController.formatBytes(r.full.downloadSize)),
            if (r.deltas.isNotEmpty)
              _row(
                context,
                'קבצי עדכון',
                r.deltas
                    .map((d) => 'מגרסה ${d.fromVersion}: ${DbController.formatBytes(d.downloadSize)}')
                    .join('\n'),
              ),
            if (r.notes.isNotEmpty) _row(context, 'הערות', r.notes),
          ] else if (db.checking)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppTokens.spaceSM),
              child: LinearProgressIndicator(),
            )
          else
            Text(db.remoteError ?? 'לא נבדק', style: _muted(context)),
          const SizedBox(height: AppTokens.spaceSM),
          OutlinedButton.icon(
            onPressed: db.checking || db.busy ? null : db.checkRemote,
            icon: const Icon(FluentIcons.arrow_sync_24_regular),
            label: Text(db.checking ? 'בודק...' : 'בדוק גרסה'),
          ),
        ],
      ),
    );
  }
}

class _MirrorCard extends StatelessWidget {
  const _MirrorCard({required this.db, required this.onPick});
  final DbController db;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final m = db.mirror?.manifest;
    return AppCard(
      title: 'תיקיית המסד (מראה)',
      icon: FluentIcons.folder_24_regular,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'כאן נשמרים קבצי ההורדה. את התיקייה מעבירים (למשל בדיסק און קי) למחשב החסום ומתקינים ממנה.',
            style: _muted(context),
          ),
          const SizedBox(height: AppTokens.spaceSM),
          _row(context, 'מיקום', db.mirrorDir),
          if (m != null) ...[
            _row(context, 'גרסה במראה', '${m.version}'),
            _row(context, 'מסד מלא', _status(m.full, db.mirrorDir)),
            for (final d in m.deltas) _row(context, 'עדכון מגרסה ${d.fromVersion}', _status(d, db.mirrorDir)),
          ] else
            _row(context, 'מצב', db.mirrorError ?? 'התיקייה ריקה (אין בה מניפסט)'),
          const SizedBox(height: AppTokens.spaceSM),
          OutlinedButton.icon(
            onPressed: db.busy ? null : onPick,
            icon: const Icon(FluentIcons.folder_open_24_regular),
            label: const Text('שנה תיקייה'),
          ),
        ],
      ),
    );
  }

  static String _status(DbArtifact a, String dir) {
    final s = DbService.partsStatus(a, dir);
    if (s.present == s.total) return 'קיים (${DbController.formatBytes(a.downloadSize)})';
    if (s.present == 0) return 'לא הורד';
    return 'חלקי (${s.present} מתוך ${s.total} חלקים)';
  }
}

class _DownloadCard extends StatelessWidget {
  const _DownloadCard({required this.db, required this.onDetect});
  final DbController db;
  final VoidCallback onDetect;

  @override
  Widget build(BuildContext context) {
    final r = db.remote?.manifest;
    final can = r != null && !db.busy;
    final bytes = db.downloadBytes;
    return AppCard(
      title: 'הורדה (מחשב מחובר)',
      icon: FluentIcons.arrow_download_24_regular,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<DbDownloadMode>(
            segments: const [
              ButtonSegment(
                value: DbDownloadMode.updatesOnly,
                icon: Icon(FluentIcons.arrow_sync_24_regular),
                label: Text('קבצי עדכון בלבד'),
              ),
              ButtonSegment(
                value: DbDownloadMode.full,
                icon: Icon(FluentIcons.database_24_regular),
                label: Text('המסד המלא'),
              ),
            ],
            selected: {db.mode},
            onSelectionChanged: db.busy ? null : (s) => db.setMode(s.first),
          ),
          const SizedBox(height: AppTokens.spaceSM),
          if (db.mode == DbDownloadMode.updatesOnly) ...[
            Text(
              'קובץ עדכון קטן בהרבה מהמסד המלא, אך מתאים רק למסד שבגרסה מסוימת. בחרו את הגרסה שמותקנת במחשב החסום, '
              'או זהו אותה מקובץ המסד.',
              style: _muted(context),
            ),
            const SizedBox(height: AppTokens.spaceSM),
            if (r != null && r.deltas.isEmpty)
              Text('אין כרגע קובצי עדכון. יש להוריד את המסד המלא.', style: _muted(context))
            else
              Wrap(
                spacing: AppTokens.spaceSM,
                runSpacing: AppTokens.spaceSM,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<int?>(
                    value: db.fromVersion,
                    onChanged: db.busy ? null : db.setFromVersion,
                    items: [
                      const DropdownMenuItem<int?>(value: null, child: Text('כל קובצי העדכון')),
                      for (final d in r?.deltas ?? const <DbArtifact>[])
                        DropdownMenuItem<int?>(
                          value: d.fromVersion,
                          child: Text('מגרסה ${d.fromVersion} (${DbController.formatBytes(d.downloadSize)})'),
                        ),
                    ],
                  ),
                  OutlinedButton.icon(
                    onPressed: can && !db.inspecting ? onDetect : null,
                    icon: const Icon(FluentIcons.search_24_regular),
                    label: Text(db.inspecting ? 'מזהה...' : 'זהה גרסה מקובץ מסד'),
                  ),
                ],
              ),
          ] else
            Text(
              'המסד המלא מתאים לכל מחשב, גם לזה שאין בו מסד קודם או שהגרסה שלו אינה מוכרת.',
              style: _muted(context),
            ),
          const SizedBox(height: AppTokens.spaceMD),
          FilledButton.icon(
            onPressed: can && db.selectedDownload.isNotEmpty ? db.download : null,
            icon: const Icon(FluentIcons.arrow_download_24_regular),
            label: Text(bytes == 0 && db.selectedDownload.isNotEmpty
                ? 'הכול כבר הורד (בדוק שוב)'
                : 'הורד (${DbController.formatBytes(bytes)})'),
          ),
          if (r == null) ...[
            const SizedBox(height: AppTokens.spaceSM),
            Text('ההורדה זמינה רק עם חיבור לרשת.', style: _muted(context)),
          ],
        ],
      ),
    );
  }
}

class _InstallCard extends StatelessWidget {
  const _InstallCard({required this.db, required this.onPickExisting, required this.onPickNew});
  final DbController db;
  final VoidCallback onPickExisting;
  final VoidCallback onPickNew;

  @override
  Widget build(BuildContext context) {
    final plan = db.plan;
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      title: 'התקנה ועדכון (גם ללא רשת)',
      icon: FluentIcons.database_24_regular,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'בחרו את קובץ המסד לעדכון, או תיקייה שבה ייווצר מסד חדש. התוכנה מזהה את הגרסה ומחילה את קובץ העדכון '
            'המתאים (או מחליפה במסד המלא), ומאמתת את התוצאה לפני שהיא מחליפה את הקובץ.',
            style: _muted(context),
          ),
          const SizedBox(height: AppTokens.spaceSM),
          _row(context, 'קובץ המסד', db.targetDb.isEmpty ? 'לא נבחר' : db.targetDb),
          if (db.local != null)
            _row(
              context,
              'גרסה נוכחית',
              switch (db.local!.state) {
                LocalDbState.current => '${db.local!.version} (עדכנית)',
                LocalDbState.hasDelta => '${db.local!.version}',
                LocalDbState.unknown => 'לא מזוהה',
              },
            ),
          const SizedBox(height: AppTokens.spaceSM),
          Wrap(
            spacing: AppTokens.spaceSM,
            runSpacing: AppTokens.spaceSM,
            children: [
              OutlinedButton.icon(
                onPressed: db.busy ? null : onPickExisting,
                icon: const Icon(FluentIcons.document_24_regular),
                label: const Text('בחר מסד קיים'),
              ),
              OutlinedButton.icon(
                onPressed: db.busy ? null : onPickNew,
                icon: const Icon(FluentIcons.add_24_regular),
                label: const Text('מסד חדש בתיקייה...'),
              ),
            ],
          ),
          if (db.inspecting) ...[
            const SizedBox(height: AppTokens.spaceSM),
            const LinearProgressIndicator(),
            const SizedBox(height: AppTokens.spaceXS),
            Text('מזהה את גרסת המסד...', style: _muted(context)),
          ] else if (plan != null) ...[
            const SizedBox(height: AppTokens.spaceMD),
            Text(plan.message,
                style: TextStyle(color: plan.action == InstallAction.blocked ? cs.error : null)),
          ] else if (db.mirror == null) ...[
            const SizedBox(height: AppTokens.spaceMD),
            Text('בתיקיית המראה אין מניפסט. הורידו קבצים או בחרו תיקייה אחרת.', style: _muted(context)),
          ],
          const SizedBox(height: AppTokens.spaceMD),
          FilledButton.icon(
            onPressed: plan != null && plan.canRun && !db.busy && !db.inspecting ? db.install : null,
            icon: const Icon(FluentIcons.checkmark_24_regular),
            label: Text(plan?.action == InstallAction.delta ? 'עדכן את המסד' : 'התקן את המסד'),
          ),
          const SizedBox(height: AppTokens.spaceSM),
          Text(
            'אוצריא חייבת להיות סגורה בזמן העדכון. הקובץ הישן נשאר במקומו עד שהחדש אומת.',
            style: _muted(context),
          ),
        ],
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
