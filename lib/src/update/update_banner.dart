import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../theme/app_tokens.dart';
import 'app_update.dart';

/// התראה על גרסה חדשה של התוכנה, עם הורדה והפעלה מחדש.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.update});

  final UpdateController update;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: update,
      builder: (context, _) {
        if (!update.showBanner || update.info == null) return const SizedBox.shrink();
        final i = update.info!;
        final cs = Theme.of(context).colorScheme;
        final fg = cs.onPrimaryContainer;
        final downloading = update.state == UpdateState.downloading;
        final restarting = update.state == UpdateState.restarting;
        final can = update.canSelfUpdate;

        final String text;
        if (restarting) {
          text = 'ההורדה הסתיימה. התוכנה נסגרת ותיפתח מחדש בגרסה ${i.version}...';
        } else if (downloading) {
          text = 'מוריד את גרסה ${i.version}...';
        } else if (update.state == UpdateState.error && update.error != null) {
          text = update.error!;
        } else {
          text = 'יש גרסה חדשה של התוכנה: ${i.version} (הגרסה שלך: ${appVersion.isEmpty ? 'פיתוח' : appVersion})';
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(AppTokens.spaceMD, AppTokens.spaceMD, AppTokens.spaceMD, 0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
              child: Container(
                padding: const EdgeInsets.all(AppTokens.spaceSM),
                decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: AppTokens.borderRadiusAll),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Icon(FluentIcons.arrow_circle_up_24_regular, color: fg),
                      const SizedBox(width: AppTokens.spaceSM),
                      Expanded(child: Text(text, style: TextStyle(color: fg))),
                      if (downloading)
                        TextButton(onPressed: update.cancelDownload, child: const Text('בטל'))
                      else if (!restarting) ...[
                        if (can)
                          FilledButton(
                            onPressed: update.downloadAndRestart,
                            child: Text(update.state == UpdateState.error ? 'נסה שוב' : 'הורד ועדכן'),
                          )
                        else
                          Text('הורידו ידנית מדף ה-Releases', style: TextStyle(color: fg)),
                        TextButton(onPressed: update.dismiss, child: const Text('אחר כך')),
                      ],
                    ]),
                    if (downloading || restarting) ...[
                      const SizedBox(height: AppTokens.spaceSM),
                      ClipRRect(
                        borderRadius: AppTokens.borderRadiusAll,
                        child: LinearProgressIndicator(value: restarting ? null : update.progress),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
