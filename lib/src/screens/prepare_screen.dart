import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../db/db_controller.dart';
import '../theme/app_tokens.dart';
import '../widgets/db_job_panel.dart';

enum _Source { none, version, copy }

/// הכנת קבצים למחשב בלי אינטרנט: שואלים "מה יש במחשב השני?" ומורידים רק את מה שחסר לו.
class PrepareScreen extends StatefulWidget {
  const PrepareScreen({super.key, required this.db});

  final DbController db;

  @override
  State<PrepareScreen> createState() => _PrepareScreenState();
}

class _PrepareScreenState extends State<PrepareScreen> {
  DbController get db => widget.db;
  _Source _source = _Source.none;

  void _choose(_Source s) {
    if (db.busy) return;
    setState(() => _source = s);
    switch (s) {
      case _Source.none:
        db.clearTransferVersion();
      case _Source.version:
        final opts = db.versionOptions;
        if (opts.isNotEmpty && !opts.any((o) => o.version == db.fromVersion)) db.setFromVersion(opts.first.version);
      case _Source.copy:
        db.clearTransferVersion();
    }
  }

  Future<void> _detect() async {
    final f = await FilePicker.pickFile(dialogTitle: 'בחירת עותק של המסד של המחשב השני');
    if (f?.path != null) await db.detectVersionFrom(f!.path!);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: db,
      builder: (context, _) {
        final r = db.remote?.manifest;
        final sel = db.selectedDownload;
        final bytes = db.downloadBytes;
        final ready = sel.isNotEmpty && bytes == 0;
        final can = r != null && !db.busy && sel.isNotEmpty;
        final opts = db.versionOptions;
        final delta = sel.isNotEmpty && sel.first.isDelta;
        return ListView(
          padding: const EdgeInsets.all(AppTokens.spaceMD),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('מה יש במחשב השני?', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text('לפי התשובה, התוכנה תוריד רק את מה שהמחשב השני צריך, ותחסוך זמן ונפח.',
                        style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: AppTokens.spaceMD),
                    _Option(
                      selected: _source == _Source.none,
                      title: 'אין לו מסד ספרים',
                      subtitle: 'יורד מסד הספרים המלא.',
                      onTap: () => _choose(_Source.none),
                    ),
                    _Option(
                      selected: _source == _Source.version,
                      title: 'אני יודע איזו גרסה יש לו',
                      subtitle: opts.isEmpty ? 'אין כרגע גרסאות לבחירה (צריך חיבור לרשת).' : null,
                      onTap: opts.isEmpty ? null : () => _choose(_Source.version),
                      child: _source == _Source.version && opts.isNotEmpty
                          ? Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: DropdownButton<int>(
                                value: opts.any((o) => o.version == db.fromVersion) ? db.fromVersion : null,
                                hint: const Text('בחרו גרסה'),
                                onChanged: db.busy ? null : (v) => db.setFromVersion(v),
                                items: [
                                  for (final o in opts)
                                    DropdownMenuItem<int>(
                                      value: o.version,
                                      child: Text('גרסה ${o.version} (יורדים ${DbController.formatBytes(o.bytes)})'),
                                    ),
                                ],
                              ),
                            )
                          : null,
                    ),
                    _Option(
                      selected: _source == _Source.copy,
                      title: 'יש לי עותק של המסד שלו',
                      subtitle: 'התוכנה תזהה לבד את הגרסה לפי הקובץ.',
                      onTap: () => _choose(_Source.copy),
                      child: _source == _Source.copy
                          ? Wrap(spacing: AppTokens.spaceSM, runSpacing: AppTokens.spaceSM, crossAxisAlignment: WrapCrossAlignment.center, children: [
                              OutlinedButton.icon(
                                onPressed: r != null && !db.busy && !db.inspecting ? _detect : null,
                                icon: const Icon(FluentIcons.search_24_regular),
                                label: Text(db.inspecting ? 'מזהה...' : 'בחירת הקובץ'),
                              ),
                              if (db.fromVersion != null) Text('זוהתה גרסה ${db.fromVersion}'),
                            ])
                          : null,
                    ),
                    const SizedBox(height: AppTokens.spaceMD),
                    if (db.activity != null)
                      Card(child: Padding(padding: const EdgeInsets.all(AppTokens.spaceLG), child: DbProgressPanel(db: db)))
                    else ...[
                      if (db.message != null) ...[
                        DbResultPanel(
                          db: db,
                          nextStep: 'עכשיו מעבירים את התוכנה יחד עם התיקייה "$dbMirrorDirName" (למשל בדיסק און קי) למחשב השני.',
                        ),
                        const SizedBox(height: AppTokens.spaceMD),
                      ],
                      Text(
                        r == null
                            ? 'ההכנה זמינה רק עם חיבור לרשת.'
                            : delta
                                ? 'יורד: עדכון מגרסה ${db.fromVersion} לגרסה ${r.version}.'
                                : 'יורד: מסד הספרים המלא (גרסה ${r.version}).',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppTokens.spaceSM),
                      SizedBox(
                        height: 56,
                        child: FilledButton.icon(
                          onPressed: can && !ready ? db.download : null,
                          icon: Icon(ready ? Icons.check : FluentIcons.arrow_download_24_regular),
                          label: Text(
                            ready ? 'הקבצים מוכנים' : 'הורדה והכנת הקבצים (${DbController.formatBytes(bytes)})',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      if (ready && db.message == null) ...[
                        const SizedBox(height: AppTokens.spaceSM),
                        Text('הקבצים מוכנים. העבירו את התוכנה יחד עם התיקייה "$dbMirrorDirName" למחשב השני.',
                            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ],
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

/// אפשרות בחירה גדולה בסגנון רדיו, עם תיאור ותוכן נוסף כשהיא נבחרה.
class _Option extends StatelessWidget {
  const _Option({required this.selected, required this.title, required this.onTap, this.subtitle, this.child});
  final bool selected;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.spaceSM),
      child: Material(
        color: selected ? cs.primaryContainer : cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: AppTokens.borderRadiusAll,
          side: BorderSide(color: selected ? cs.primary : cs.outlineVariant, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: AppTokens.borderRadiusAll,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spaceMD),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(
                inMutuallyExclusiveGroup: true,
                checked: selected,
                label: title,
                excludeSemantics: true,
                child: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: onTap == null ? cs.outline : cs.primary),
              ),
              const SizedBox(width: AppTokens.spaceMD),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  if (subtitle != null)
                    Text(subtitle!, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                  if (child != null) ...[const SizedBox(height: AppTokens.spaceSM), child!],
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
