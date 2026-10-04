import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../theme/app_tokens.dart';
import 'app_card.dart';

/// כרטיס התקדמות של פעולה ארוכה, עם כפתור "עצור".
class ActivityCard extends StatelessWidget {
  const ActivityCard({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final a = controller.activity;
    if (a == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(a.title, style: theme.textTheme.titleMedium)),
            TextButton(
              onPressed: a.cancelled ? null : controller.cancelActivity,
              child: Text(a.cancelled ? 'עוצר...' : 'עצור'),
            ),
          ]),
          if (a.detail.isNotEmpty) ...[
            const SizedBox(height: AppTokens.spaceXS),
            Text(a.detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
