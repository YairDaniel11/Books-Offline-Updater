import 'package:flutter/material.dart';

import '../db/db_controller.dart';
import '../theme/app_tokens.dart';

/// התקדמות הפעולה הנוכחית של המסד, עם כפתור "עצור".
class DbProgressPanel extends StatelessWidget {
  const DbProgressPanel({super.key, required this.db});
  final DbController db;

  @override
  Widget build(BuildContext context) {
    final a = db.activity;
    if (a == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final pct = a.progress == null ? null : (a.progress! * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: Text(a.title, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
          if (pct != null) Text('$pct%', style: theme.textTheme.titleLarge),
        ]),
        if (a.detail.isNotEmpty) ...[
          const SizedBox(height: AppTokens.spaceXS),
          Text(a.detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
        const SizedBox(height: AppTokens.spaceMD),
        Semantics(
          label: 'התקדמות',
          value: pct == null ? null : '$pct%',
          child: ClipRRect(
            borderRadius: AppTokens.borderRadiusAll,
            child: LinearProgressIndicator(value: a.progress, minHeight: 12),
          ),
        ),
        const SizedBox(height: AppTokens.spaceSM),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(onPressed: a.cancelled ? null : db.cancel, child: Text(a.cancelled ? 'עוצר...' : 'עצור')),
        ),
      ],
    );
  }
}

/// תוצאת הפעולה האחרונה: הצלחה או כשל, עם הצעד הבא ("אפשר לפתוח את אוצריא").
class DbResultPanel extends StatelessWidget {
  const DbResultPanel({super.key, required this.db, this.nextStep});
  final DbController db;

  /// שורת הצעד הבא שמוצגת רק בהצלחה.
  final String? nextStep;

  @override
  Widget build(BuildContext context) {
    final msg = db.message;
    if (msg == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final err = db.messageIsError;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final okBg = dark ? const Color(0xFF1B3A1F) : const Color(0xFFDCEFDD);
    final okFg = dark ? const Color(0xFFA5D6A7) : const Color(0xFF1B5E20);
    final fg = err ? cs.onErrorContainer : okFg;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsetsDirectional.only(start: AppTokens.spaceMD, end: AppTokens.spaceXS),
        decoration: BoxDecoration(color: err ? cs.errorContainer : okBg, borderRadius: AppTokens.borderRadiusAll),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: AppTokens.spaceMD),
            child: Icon(err ? Icons.error_outline : Icons.check_circle, color: fg, size: 28),
          ),
          const SizedBox(width: AppTokens.spaceMD),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppTokens.spaceMD),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(err ? 'לא הצלחנו' : 'הושלם',
                    style: TextStyle(color: fg, fontSize: AppTokens.fontXL, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                SelectableText(msg, style: TextStyle(color: fg, fontSize: AppTokens.fontLG)),
                if (!err && nextStep != null) ...[
                  const SizedBox(height: 4),
                  Text(nextStep!, style: TextStyle(color: fg, fontSize: AppTokens.fontLG, fontWeight: FontWeight.w600)),
                ],
              ]),
            ),
          ),
          IconButton(tooltip: 'סגור', icon: Icon(Icons.close, color: fg, size: 20), onPressed: db.clearMessage),
        ]),
      ),
    );
  }
}
