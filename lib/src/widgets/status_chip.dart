import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../theme/app_tokens.dart';

/// תגית סטטוס: "מעודכן" / "יש עדכון" / "לא הורד".
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});

  final ItemStatus status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, bg, fg) = switch (status) {
      ItemStatus.ok => ('מעודכן', cs.primaryContainer, cs.onPrimaryContainer),
      ItemStatus.update => ('יש עדכון', cs.tertiaryContainer, cs.onTertiaryContainer),
      ItemStatus.none => ('לא הורד', cs.surfaceContainerHighest, cs.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceSM, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: AppTokens.borderRadiusAll),
      child: Text(label, style: TextStyle(color: fg, fontSize: AppTokens.fontSM, fontWeight: FontWeight.w600)),
    );
  }
}
