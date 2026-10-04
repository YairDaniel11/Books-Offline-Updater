import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../controllers/app_controller.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_card.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller, required this.onNavigate});

  final AppController controller;

  /// מעבר ללשונית לפי אינדקס (2 = חילוץ).
  final ValueChanged<int> onNavigate;

  static String _date(int? epochSeconds) {
    if (epochSeconds == null) return 'עדיין לא עודכן';
    final d = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final pak = c.pak;
        final s = c.summary;
        final busy = c.busy;
        final canNetwork = c.online && !c.readOnly;
        final updates = c.pendingTargets(onlyUpdates: true);
        final notDownloaded = c.pendingTargets(onlyUpdates: false).length - updates.length;
        final theme = Theme.of(context);

        Widget row(String k, String v) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 110, child: Text(k, style: TextStyle(color: theme.colorScheme.onSurfaceVariant))),
                  Expanded(child: SelectableText(v)),
                ],
              ),
            );

        return ListView(
          padding: const EdgeInsets.all(AppTokens.spaceMD),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!c.online) ...[
                      _OfflineBanner(controller: c),
                      const SizedBox(height: AppTokens.spaceMD),
                    ],
                    AppCard(
                      title: 'מצב המאגר',
                      icon: FluentIcons.database_24_regular,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          row('קובץ המאגר', pak?.path ?? ''),
                          row('גודל', pak == null ? '' : AppController.formatBytes(pak.fileLength)),
                          row('מספר קבצים', '${c.pakFileCount}'),
                          row('עדכון אחרון', _date(c.lastUpdated)),
                          if (c.hasData)
                            row('סיכום', '${s.ok} מעודכנים, ${s.update} עם עדכון, ${s.none} שלא הורדו'),
                          if (c.readOnly) row('מצב', 'לקריאה בלבד'),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceMD),
                    AppCard(
                      title: 'עדכון מהרשת',
                      icon: FluentIcons.cloud_arrow_down_24_regular,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: AppTokens.spaceSM,
                            runSpacing: AppTokens.spaceSM,
                            children: [
                              // "הורד הכול": כל מה שעוד לא ירד (וגם עדכונים), בלחיצה אחת.
                              if (!c.hasData || notDownloaded > 0)
                                FilledButton.icon(
                                  onPressed: canNetwork && !busy && !c.checkingOnline
                                      ? () => c.downloadTargets(
                                            c.pendingTargets(onlyUpdates: false),
                                            title: 'מוריד את כל המאגר',
                                            includeLinks: true,
                                          )
                                      : null,
                                  icon: const Icon(FluentIcons.arrow_download_24_regular),
                                  label: Text(c.hasData ? 'הורד את כל המאגר ($notDownloaded לא הורדו)' : 'הורד את כל המאגר'),
                                ),
                              if (c.hasData && updates.isNotEmpty && notDownloaded == 0)
                                FilledButton.icon(
                                  onPressed: canNetwork && !busy
                                      ? () => c.downloadTargets(
                                            updates,
                                            title: 'מוריד עדכונים',
                                            includeLinks: true,
                                          )
                                      : null,
                                  icon: const Icon(FluentIcons.arrow_download_24_regular),
                                  label: Text('הורד עדכונים (${updates.length})'),
                                ),
                              if (c.hasData && updates.isNotEmpty && notDownloaded > 0)
                                OutlinedButton.icon(
                                  onPressed: canNetwork && !busy
                                      ? () => c.downloadTargets(
                                            updates,
                                            title: 'מוריד עדכונים',
                                            includeLinks: true,
                                          )
                                      : null,
                                  icon: const Icon(FluentIcons.arrow_download_24_regular),
                                  label: Text('הורד רק עדכונים (${updates.length})'),
                                ),
                              OutlinedButton.icon(
                                onPressed: c.online && !busy && !c.checkingOnline ? c.checkOnline : null,
                                icon: const Icon(FluentIcons.arrow_sync_24_regular),
                                label: const Text('בדוק עדכונים'),
                              ),
                            ],
                          ),
                          if (!canNetwork) ...[
                            const SizedBox(height: AppTokens.spaceSM),
                            Text(
                              c.readOnly ? 'קובץ המאגר לקריאה בלבד, לא ניתן לעדכן.' : 'העדכון זמין רק עם חיבור לרשת.',
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: AppTokens.spaceMD),
                    AppCard(
                      title: 'חילוץ למחשב',
                      icon: FluentIcons.folder_arrow_right_24_regular,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'חילוץ הספרים מקובץ המאגר אל תיקייה במחשב, גם ללא חיבור לרשת.',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: AppTokens.spaceMD),
                          FilledButton.tonalIcon(
                            onPressed: () => onNavigate(2),
                            icon: const Icon(FluentIcons.arrow_left_24_regular),
                            label: const Text('למסך החילוץ'),
                          ),
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

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppTokens.spaceSM),
      decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: AppTokens.borderRadiusAll),
      child: Row(children: [
        Icon(FluentIcons.cloud_off_24_regular, color: cs.onTertiaryContainer),
        const SizedBox(width: AppTokens.spaceSM),
        Expanded(
          child: Text('אין חיבור לרשת — מצב חילוץ', style: TextStyle(color: cs.onTertiaryContainer)),
        ),
        TextButton(
          onPressed: controller.checkingOnline ? null : controller.checkOnline,
          child: Text(controller.checkingOnline ? 'בודק...' : 'נסה שוב'),
        ),
      ]),
    );
  }
}
