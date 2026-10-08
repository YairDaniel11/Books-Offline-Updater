import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'info_icon.dart';

/// כרטיס סטנדרטי עם רדיוס 8, ריפוד ואופציונלית כותרת.
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.title, this.icon, this.padding, this.info});

  final Widget child;
  final String? title;
  final IconData? icon;
  final EdgeInsetsGeometry? padding;

  /// הסבר שמוצג באייקון מידע ליד הכותרת.
  final String? info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: padding ?? const EdgeInsets.all(AppTokens.spaceMD),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null) ...[
              Row(children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: AppTokens.spaceSM),
                ],
                Expanded(
                  child: Text(title!,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                ),
                if (info != null) InfoIcon(info!),
              ]),
              const SizedBox(height: AppTokens.spaceMD),
            ],
            child,
          ],
        ),
      ),
    );
  }
}
