import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../controllers/app_controller.dart';
import '../db/db_controller.dart';
import '../db/db_service.dart' show LocalDbState;
import '../theme/app_tokens.dart';
import '../widgets/app_card.dart';

/// דף הבית: פעולה אחת בולטת (עדכון המסד), ואפשרות משנית לספרים בודדים בפורמט TXT.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller, required this.db, required this.onNavigate});

  final AppController controller;
  final DbController db;

  /// מעבר ללשונית לפי אינדקס (1 = מסד ספרים, 2 = ספרים בודדים TXT).
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, db]),
      builder: (context, _) {
        final c = controller;
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
                    _DbCard(db: db, onNavigate: onNavigate),
                    const SizedBox(height: AppTokens.spaceMD),
                    AppCard(
                      title: 'ספרים בודדים (TXT)',
                      icon: FluentIcons.document_text_24_regular,
                      info: 'זו אינה הדרך הפשוטה. היא מתאימה למי שרוצה ספר מסוים בלבד, בפורמט TXT, ולא את כל המסד. '
                          'לרוב המשתמשים מומלץ מסד הספרים.',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'לבחירת ספר מסוים בלבד, בפורמט TXT.',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: AppTokens.spaceMD),
                          OutlinedButton.icon(
                            onPressed: () => onNavigate(2),
                            icon: const Icon(FluentIcons.arrow_left_24_regular),
                            label: const Text('לספרים בפורמט TXT'),
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
          child: Text('אין חיבור לרשת', style: TextStyle(color: cs.onTertiaryContainer)),
        ),
        TextButton(
          onPressed: controller.checkingOnline ? null : controller.checkOnline,
          child: Text(controller.checkingOnline ? 'בודק...' : 'נסה שוב'),
        ),
      ]),
    );
  }
}

/// עדכון המסד מדף הבית: לחיצה אחת, והתוכנה בוחרת לבד מה להוריד.
class _DbCard extends StatelessWidget {
  const _DbCard({required this.db, required this.onNavigate});

  final DbController db;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final m = db.remote?.manifest;
    final a = db.activity;
    return AppCard(
      title: 'מסד ספרים מותאמים לאוצריא (DB)',
      icon: FluentIcons.database_24_regular,
      info: 'מסד מוכן של הספרים. התוכנה מזהה את הגרסה שבמחשב ומורידה רק מה שדרוש. '
          'בוחרים פעם אחת את מיקום המסד, והוא נזכר במחשב הזה.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            m != null
                ? 'גרסה ${m.version} זמינה.'
                : db.checking
                    ? 'בודק גרסה...'
                    : (db.remoteError ?? 'להורדה ולעדכון של המסד.'),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppTokens.spaceMD),
          Wrap(
            spacing: AppTokens.spaceSM,
            runSpacing: AppTokens.spaceSM,
            children: [
              if (db.targetDb.isEmpty)
                FilledButton.icon(
                  onPressed: () => onNavigate(1),
                  icon: const Icon(FluentIcons.folder_open_24_regular),
                  label: const Text('הגדרת מיקום המסד'),
                )
              else
                FilledButton.icon(
                  onPressed: m != null && !db.busy && !db.inspecting && db.local?.state != LocalDbState.current ? db.updateNow : null,
                  icon: const Icon(FluentIcons.arrow_download_24_regular),
                  label: Text(db.local?.state == LocalDbState.current
                      ? 'המסד מעודכן'
                      : (File(db.targetDb).existsSync() ? 'עדכן את המסד' : 'הורד והתקן את המסד')),
                ),
              OutlinedButton.icon(
                onPressed: () => onNavigate(1),
                icon: const Icon(FluentIcons.settings_24_regular),
                label: const Text('כל אפשרויות המסד'),
              ),
            ],
          ),
          if (a != null) ...[
            const SizedBox(height: AppTokens.spaceMD),
            Row(children: [
              Expanded(child: Text(a.title)),
              TextButton(onPressed: a.cancelled ? null : db.cancel, child: Text(a.cancelled ? 'עוצר...' : 'עצור')),
            ]),
            if (a.detail.isNotEmpty) Text(a.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint),
            const SizedBox(height: AppTokens.spaceSM),
            ClipRRect(borderRadius: AppTokens.borderRadiusAll, child: LinearProgressIndicator(value: a.progress)),
          ] else if (db.message != null) ...[
            const SizedBox(height: AppTokens.spaceSM),
            Text(db.message!, style: db.messageIsError ? hint?.copyWith(color: theme.colorScheme.error) : hint),
          ],
        ],
      ),
    );
  }
}
