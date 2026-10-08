import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../controllers/app_controller.dart';
import '../theme/app_tokens.dart';
import '../widgets/info_icon.dart';
import 'extract_screen.dart';
import 'library_screen.dart';

/// ספרים בודדים בפורמט TXT: בחירה והורדה של ספרים מסוימים, וחילוץ שלהם למחשב.
/// מסומן במפורש כדרך שאינה הפשוטה; הדרך המומלצת היא מסד הספרים.
class TxtBooksScreen extends StatefulWidget {
  const TxtBooksScreen({super.key, required this.controller, required this.onGoDb});

  final AppController controller;
  final VoidCallback onGoDb;

  @override
  State<TxtBooksScreen> createState() => _TxtBooksScreenState();
}

class _TxtBooksScreenState extends State<TxtBooksScreen> {
  int _tab = 0;

  AppController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppTokens.spaceMD, AppTokens.spaceMD, AppTokens.spaceMD, 0),
              child: Container(
                padding: const EdgeInsets.all(AppTokens.spaceSM),
                decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: AppTokens.borderRadiusAll),
                child: Row(children: [
                  Icon(FluentIcons.info_24_regular, color: cs.onTertiaryContainer),
                  const SizedBox(width: AppTokens.spaceSM),
                  Expanded(
                    child: Text(
                      'זו אינה הדרך הפשוטה. החלק הזה מתאים למי שרוצה ספר מסוים בלבד, בפורמט TXT. '
                      'לרוב המשתמשים מומלץ מסד הספרים.',
                      style: TextStyle(color: cs.onTertiaryContainer),
                    ),
                  ),
                  TextButton(onPressed: widget.onGoDb, child: const Text('למסד הספרים')),
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppTokens.spaceMD, AppTokens.spaceMD, AppTokens.spaceMD, 0),
              child: ListenableBuilder(
                listenable: c,
                builder: (context, _) => Wrap(
                  spacing: AppTokens.spaceSM,
                  runSpacing: AppTokens.spaceSM,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<int>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 0, icon: Icon(FluentIcons.library_24_regular), label: Text('בחירה והורדה')),
                        ButtonSegment(value: 1, icon: Icon(FluentIcons.arrow_download_24_regular), label: Text('חילוץ למחשב')),
                      ],
                      selected: {_tab},
                      onSelectionChanged: (s) => setState(() => _tab = s.first),
                    ),
                    if (_tab == 0) ...[
                      OutlinedButton.icon(
                        onPressed: c.online && !c.busy && !c.checkingOnline ? c.checkOnline : null,
                        icon: const Icon(FluentIcons.arrow_sync_24_regular),
                        label: const Text('בדוק עדכונים'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: c.online && !c.readOnly && !c.busy && !c.checkingOnline && c.hasData
                            ? () => c.downloadTargets(
                                  c.pendingTargets(onlyUpdates: false),
                                  title: 'מוריד את כל המאגר',
                                  includeLinks: true,
                                )
                            : null,
                        icon: const Icon(FluentIcons.arrow_download_24_regular),
                        label: const Text('הורד את כל הספרים'),
                      ),
                      const InfoIcon('הורדת כל הספרים בפורמט TXT לקובץ אחד (קובץ המאגר), שאפשר לחלץ ממנו אחר כך. '
                          'אם צריך ספר אחד בלבד, בחרו אותו מהרשימה.'),
                    ],
                  ],
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  LibraryScreen(controller: c),
                  ExtractScreen(controller: c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
