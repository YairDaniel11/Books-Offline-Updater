import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../theme/app_tokens.dart';

/// מציג את ההודעה האחרונה של הקונטרולר, עם כפתור סגירה.
class MessageBanner extends StatelessWidget {
  const MessageBanner({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final msg = controller.lastMessage;
    if (msg == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final err = controller.lastMessageIsError;
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
            child: SelectableText(msg, style: TextStyle(color: fg)),
          ),
        ),
        IconButton(
          tooltip: 'סגור',
          icon: Icon(Icons.close, color: fg, size: 20),
          onPressed: controller.clearMessage,
        ),
      ]),
    );
  }
}
