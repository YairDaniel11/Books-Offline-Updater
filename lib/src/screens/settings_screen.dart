import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../controllers/app_controller.dart';
import '../theme/app_tokens.dart';
import '../update/app_update.dart';
import '../widgets/app_card.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller, required this.update});

  final AppController controller;
  final UpdateController update;

  Future<void> _pickDir() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'בחירת מיקום המאגר');
    if (dir != null) await controller.changeDataDir(dir);
  }

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('איפוס סטטוס הורדות'),
        content: const Text('כל הספרים יסומנו כלא הורדו, וההורדה הבאה תוריד אותם מחדש. הקבצים במאגר לא יימחקו. להמשיך?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('אפס')),
        ],
      ),
    );
    if (ok == true) await controller.resetStatuses();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, update]),
      builder: (context, _) {
        final c = controller;
        final theme = Theme.of(context);
        final busy = c.busy;
        final dead = c.pak?.deadBytes ?? 0;
        final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

        return ListView(
          padding: const EdgeInsets.all(AppTokens.spaceMD),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppCard(
                      title: 'ערכת נושא',
                      icon: FluentIcons.paint_brush_24_regular,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: SegmentedButton<ThemeMode>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: ThemeMode.system, label: Text('מערכת')),
                            ButtonSegment(value: ThemeMode.light, label: Text('בהיר')),
                            ButtonSegment(value: ThemeMode.dark, label: Text('כהה')),
                          ],
                          selected: {c.themeMode},
                          onSelectionChanged: (s) => c.setThemeMode(s.first),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceMD),
                    Card(
                      child: Theme(
                        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          leading: const Icon(FluentIcons.document_text_24_regular),
                          title: const Text('הגדרות לספרים בפורמט TXT (למתקדמים)'),
                          subtitle: const Text('רלוונטי רק למי שמוריד ספרים בפורמט TXT, ולא למסד הספרים'),
                          childrenPadding: const EdgeInsets.all(AppTokens.spaceSM),
                          children: [
                    AppCard(
                      title: 'הורדות (ספרים בפורמט TXT)',
                      icon: FluentIcons.arrow_download_24_regular,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('ההגדרות כאן רלוונטיות רק למי שמוריד את הספרים בפורמט TXT, ולא למסד הספרים.', style: hint),
                          const SizedBox(height: AppTokens.spaceSM),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('התעלם משס וגשל'),
                            subtitle: const Text('לא להוריד ולא לעדכן את תיקיית "שס וגשל"'),
                            value: c.ignoreShas,
                            onChanged: busy ? null : c.setIgnoreShas,
                          ),
                          const Divider(),
                          const SizedBox(height: AppTokens.spaceSM),
                          OutlinedButton.icon(
                            onPressed: busy ? null : () => _confirmReset(context),
                            icon: const Icon(FluentIcons.arrow_reset_24_regular),
                            label: const Text('אפס סטטוס הורדות'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceMD),
                    AppCard(
                      title: 'מיקום המאגר',
                      icon: FluentIcons.folder_24_regular,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(c.dataDir),
                          const SizedBox(height: AppTokens.spaceMD),
                          Wrap(
                            spacing: AppTokens.spaceSM,
                            runSpacing: AppTokens.spaceSM,
                            children: [
                              OutlinedButton.icon(
                                onPressed: busy ? null : _pickDir,
                                icon: const Icon(FluentIcons.folder_open_24_regular),
                                label: const Text('שנה מיקום'),
                              ),
                              TextButton(
                                onPressed: busy ? null : () => c.changeDataDir(null),
                                child: const Text('חזור למיקום ליד התוכנה'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceMD),
                    AppCard(
                      title: 'קובץ המאגר',
                      icon: FluentIcons.database_24_regular,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('מקום מיותר בקובץ: ${AppController.formatBytes(dead)}'),
                          const SizedBox(height: 4),
                          Text('צמצום כותב את הקובץ מחדש ומשחרר מקום של קבצים ישנים שהוחלפו.', style: hint),
                          const SizedBox(height: AppTokens.spaceMD),
                          OutlinedButton.icon(
                            onPressed: busy || c.readOnly ? null : c.compactNow,
                            icon: const Icon(FluentIcons.arrow_minimize_24_regular),
                            label: const Text('צמצם את קובץ המאגר'),
                          ),
                        ],
                      ),
                    ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceMD),
                    AppCard(
                      title: 'אודות',
                      icon: FluentIcons.info_24_regular,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('עדכון אופליין למאגר ספרים'),
                          const SizedBox(height: 4),
                          Text(appVersion.isEmpty ? 'גרסת פיתוח' : 'גרסה $appVersion', style: hint),
                          const SizedBox(height: AppTokens.spaceSM),
                          Wrap(
                            spacing: AppTokens.spaceSM,
                            runSpacing: AppTokens.spaceSM,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              OutlinedButton.icon(
                                onPressed: update.state == UpdateState.checking || update.state == UpdateState.downloading
                                    ? null
                                    : () => update.check(manual: true),
                                icon: const Icon(FluentIcons.arrow_sync_24_regular),
                                label: Text(update.state == UpdateState.checking ? 'בודק...' : 'בדוק גרסה חדשה של התוכנה'),
                              ),
                              if (update.state == UpdateState.idle && appVersion.isNotEmpty) Text('התוכנה מעודכנת', style: hint),
                              if (update.state == UpdateState.error && update.error != null && update.info == null)
                                Text(update.error!, style: hint?.copyWith(color: theme.colorScheme.error)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text('מוריד את מאגר הספרים מ-GitHub לקובץ יחיד, ומחלץ אותו למחשבים ללא רשת.', style: hint),
                        ],
                      ),
                    ),
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
