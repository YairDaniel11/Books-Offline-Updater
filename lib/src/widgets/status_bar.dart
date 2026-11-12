import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../theme/app_tokens.dart';

/// פס מצב דק בתחתית המסך: רשת, גרסת הכונן, נעילה וגרסת התוכנה.
class AppStatusBar extends StatelessWidget {
  const AppStatusBar({
    super.key,
    required this.online,
    required this.driveVersion,
    required this.locked,
    required this.lockEnabled,
    required this.appVersion,
  });

  final bool online;

  /// גרסת המסד שבכונן (בתיקיית הקבצים), או null כשלא נמצאו קבצים.
  final int? driveVersion;

  /// נעול כרגע.
  final bool locked;

  /// האם הוגדרה סיסמת נעילה בכלל.
  final bool lockEnabled;
  final String appVersion;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(color: cs.onSurfaceVariant, fontSize: AppTokens.fontMD);
    Widget item(IconData icon, String text, {Color? color}) => Semantics(
          label: text,
          excludeSemantics: true,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: color ?? cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(text, style: style),
          ]),
        );
    return Material(
      color: cs.surfaceContainer,
      child: Container(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: cs.outlineVariant))),
        padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceMD, vertical: 6),
        child: Wrap(
          spacing: AppTokens.spaceMD,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            online
                ? item(FluentIcons.cloud_checkmark_24_regular, 'מחובר לרשת', color: const Color(0xFF2E7D32))
                : item(FluentIcons.cloud_off_24_regular, 'לא מחובר לרשת'),
            item(FluentIcons.usb_stick_24_regular,
                driveVersion == null ? 'כונן: לא נמצאו קבצים' : 'כונן: גרסה $driveVersion'),
            if (lockEnabled)
              item(locked ? FluentIcons.lock_closed_24_regular : FluentIcons.lock_open_24_regular,
                  locked ? 'נעול' : 'לא נעול'),
            item(FluentIcons.info_24_regular, appVersion.isEmpty ? 'גרסת פיתוח' : 'תוכנה: $appVersion'),
          ],
        ),
      ),
    );
  }
}
