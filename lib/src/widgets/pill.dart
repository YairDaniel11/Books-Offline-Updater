import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// גוון של תגית סטטוס: תקין (ירוק), דורש תשומת לב (כתום), ניטרלי (אפור), בעיה (אדום).
enum PillTone { good, warn, neutral, bad }

/// תגית סטטוס קטנה וצבעונית. הצבע לבדו אינו נושא את המשמעות: יש גם אייקון וטקסט.
class Pill extends StatelessWidget {
  const Pill(this.label, this.tone, {super.key});

  final String label;
  final PillTone tone;

  static (Color bg, Color fg, IconData icon) colors(BuildContext context, PillTone tone) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    return switch (tone) {
      PillTone.good => (
          dark ? const Color(0xFF1B3A1F) : const Color(0xFFDCEFDD),
          dark ? const Color(0xFFA5D6A7) : const Color(0xFF1B5E20),
          Icons.check_circle_outline,
        ),
      PillTone.warn => (
          dark ? const Color(0xFF4A3410) : const Color(0xFFFFE8C2),
          dark ? const Color(0xFFFFCC80) : const Color(0xFF8A4B00),
          Icons.arrow_circle_down_outlined,
        ),
      PillTone.neutral => (cs.surfaceContainerHighest, cs.onSurfaceVariant, Icons.remove_circle_outline),
      PillTone.bad => (cs.errorContainer, cs.onErrorContainer, Icons.error_outline),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon) = colors(context, tone);
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceSM + 2, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label, style: TextStyle(color: fg, fontSize: AppTokens.fontMD, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }
}
