import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../db/db_controller.dart';
import '../theme/app_tokens.dart';
import '../vectors/vectors_controller.dart';

/// כרטיס וקטורי החיפוש: [prepare] מציג הורדה (מחשב מחובר), אחרת התקנה (מחשב חסום).
class VectorsCard extends StatelessWidget {
  const VectorsCard({super.key, required this.vectors, required this.prepare});

  final VectorsController vectors;
  final bool prepare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListenableBuilder(
      listenable: vectors,
      builder: (context, _) {
        final a = vectors.activity;
        final r = vectors.remote?.manifest;
        final mm = vectors.mirror?.manifest;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spaceMD),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('וקטורי חיפוש לפי משמעות',
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(vectorsCredit, style: muted),
              const SizedBox(height: AppTokens.spaceSM),
              if (vectors.message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTokens.spaceSM),
                  child: Row(children: [
                    Icon(vectors.messageIsError ? Icons.error_outline : Icons.check_circle,
                        color: vectors.messageIsError ? theme.colorScheme.error : Colors.green),
                    const SizedBox(width: AppTokens.spaceSM),
                    Expanded(child: SelectableText(vectors.message!)),
                    IconButton(onPressed: vectors.clearMessage, icon: const Icon(Icons.close, size: 20)),
                  ]),
                ),
              if (a != null) ...[
                Row(children: [
                  Expanded(child: Text(a.title, style: theme.textTheme.titleMedium)),
                  if (a.progress != null)
                    Text('${(a.progress! * 100).toStringAsFixed(1)}%',
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                ]),
                if (a.detail.isNotEmpty) Text(a.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                const SizedBox(height: AppTokens.spaceSM),
                LinearProgressIndicator(value: a.progress, minHeight: 10),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                      onPressed: a.cancelled ? null : vectors.cancel, child: Text(a.cancelled ? 'עוצר...' : 'עצור')),
                ),
              ] else if (prepare) ...[
                Text(
                  r == null
                      ? (vectors.checking ? 'בודק...' : (vectors.remoteError ?? 'ההכנה זמינה רק עם חיבור לרשת.'))
                      : 'מורידים את קובץ הוקטורים כמו שהוא (${DbController.formatBytes(r.downloadSize)}), למסד גרסה ${r.dbVersion}.',
                  style: muted,
                ),
                const SizedBox(height: AppTokens.spaceSM),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton(
                    onPressed: r != null && !vectors.preparedComplete ? vectors.prepare : null,
                    child: Text(vectors.preparedComplete ? 'הוקטורים מוכנים' : 'הורדת הוקטורים'),
                  ),
                ),
              ] else ...[
                Text(
                  mm == null
                      ? 'בתיקיית החבילה אין וקטורים. הכינו אותם במחשב מחובר.'
                      : vectors.preparedComplete
                          ? 'בחבילה וקטורים למסד גרסה ${mm.dbVersion} (${mm.segment.slots} וקטורים). '
                              'התקינו קודם את המסד, ואחר כך את הוקטורים. אוצריא חייבת להיות סגורה.'
                          : 'הוקטורים בחבילה חלקיים. הכינו אותם מחדש.',
                  style: muted,
                ),
                const SizedBox(height: AppTokens.spaceXS),
                Text('תיקיית הוקטורים של אוצריא: ${vectors.vectorsDir ?? 'לא נמצאה'}', style: muted),
                const SizedBox(height: AppTokens.spaceSM),
                Wrap(spacing: AppTokens.spaceSM, runSpacing: AppTokens.spaceSM, children: [
                  FilledButton(onPressed: vectors.preparedComplete ? vectors.install : null, child: const Text('התקנת הוקטורים')),
                  OutlinedButton(
                    onPressed: () async {
                      final d = await FilePicker.getDirectoryPath(dialogTitle: 'בחירת תיקיית הוקטורים של אוצריא (vectors)');
                      if (d != null) await vectors.setVectorsDir(d);
                    },
                    child: const Text('בחירת תיקיית וקטורים'),
                  ),
                ]),
              ],
            ]),
          ),
        );
      },
    );
  }
}
