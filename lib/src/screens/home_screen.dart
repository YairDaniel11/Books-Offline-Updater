import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../controllers/app_controller.dart';
import '../db/db_controller.dart';
import '../db/db_service.dart' show LocalDbState;
import '../theme/app_tokens.dart';
import '../widgets/db_job_panel.dart';
import '../widgets/pill.dart';
import 'tabs.dart';

/// מה המחשב הזה צריך עכשיו: תשובה אחת בלבד לדף הבית.
enum HeroKind { checking, needsLocation, offline, notInstalled, updateAvailable, upToDate }

HeroKind heroKindOf(DbController db) {
  if (db.targetDb.isEmpty) return HeroKind.needsLocation;
  if (db.remote == null) return db.checking || db.inspecting ? HeroKind.checking : HeroKind.offline;
  if (!File(db.targetDb).existsSync()) return HeroKind.notInstalled;
  if (db.inspecting || db.local == null) return HeroKind.checking;
  return db.local!.state == LocalDbState.current ? HeroKind.upToDate : HeroKind.updateAvailable;
}

/// דף הבית: כרטיס אחד גדול שאומר מה המחשב הזה צריך, כפתור ראשי אחד, ומתחתיו מצב העדכונים וקיצורים.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller, required this.db, required this.onNavigate});

  final AppController controller;
  final DbController db;

  /// מעבר למסך משנה לפי [Tabs].
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, db]),
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(AppTokens.spaceMD),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (db.message != null && db.activity == null) ...[
                      DbResultPanel(db: db, nextStep: 'אפשר לפתוח את אוצריא.'),
                      const SizedBox(height: AppTokens.spaceMD),
                    ],
                    _Hero(db: db, onNavigate: onNavigate),
                    const SizedBox(height: AppTokens.spaceMD),
                    _StatusRow(db: db),
                    const SizedBox(height: AppTokens.spaceLG),
                    _Tiles(onNavigate: onNavigate),
                    const SizedBox(height: AppTokens.spaceSM),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: () => onNavigate(Tabs.txt),
                        icon: const Icon(FluentIcons.document_text_24_regular),
                        label: const Text('צריך רק ספר אחד? ספרים בודדים'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.db, required this.onNavigate});
  final DbController db;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final kind = heroKindOf(db);
    final m = db.remote?.manifest;
    final from = db.local?.version;

    if (db.activity != null) {
      return Card(
        child: Padding(padding: const EdgeInsets.all(AppTokens.spaceLG), child: DbProgressPanel(db: db)),
      );
    }

    final (IconData icon, String title, String body) = switch (kind) {
      HeroKind.checking => (FluentIcons.arrow_sync_24_regular, 'בודק מה יש במחשב הזה...', 'רק רגע.'),
      HeroKind.needsLocation => (
          FluentIcons.folder_open_24_regular,
          'צריך לבחור איפה להתקין את הספרים',
          'בחרו פעם אחת מקום למסד הספרים, והתוכנה תזכור אותו.',
        ),
      HeroKind.offline => (
          FluentIcons.cloud_off_24_regular,
          'אין חיבור לרשת',
          db.mirror != null
              ? 'אי אפשר לבדוק עדכונים כרגע. יש קבצי ספרים בכונן: אפשר להעתיק אותם למחשב הזה.'
              : 'אי אפשר לבדוק עדכונים כרגע. אפשר להתחבר לרשת, או להעתיק את הספרים מכונן שהוכן במחשב אחר.',
        ),
      HeroKind.notInstalled => (
          FluentIcons.database_24_regular,
          'מסד הספרים עוד לא מותקן',
          'לחיצה אחת מורידה ומתקינה את הספרים (גרסה ${m?.version}). הם יופיעו באוצריא מעצמם.',
        ),
      HeroKind.updateAvailable => (
          FluentIcons.alert_badge_24_filled,
          'יש עדכון למסד הספרים',
          from != null
              ? 'גרסה ${m?.version} זמינה (במחשב הזה: גרסה $from). יורד רק מה שחסר.'
              : 'גרסה ${m?.version} זמינה. התוכנה תוריד רק מה שדרוש.',
        ),
      HeroKind.upToDate => (
          FluentIcons.checkmark_circle_24_filled,
          'הכול מעודכן במחשב הזה',
          'יש לכם את הספרים העדכניים (גרסה ${m?.version}). אין צורך לעשות דבר.',
        ),
    };

    final good = kind == HeroKind.upToDate;
    final (goodBg, goodFg, _) = Pill.colors(context, PillTone.good);
    final bg = good ? goodBg : (kind == HeroKind.offline ? cs.tertiaryContainer : cs.primaryContainer);
    final fg = good ? goodFg : (kind == HeroKind.offline ? cs.onTertiaryContainer : cs.onPrimaryContainer);

    final VoidCallback? action;
    final String actionLabel;
    final IconData actionIcon;
    switch (kind) {
      case HeroKind.needsLocation:
        action = () => onNavigate(Tabs.db);
        actionLabel = 'בחירת מקום';
        actionIcon = FluentIcons.folder_open_24_regular;
      case HeroKind.offline:
        if (db.mirror != null) {
          action = () => onNavigate(Tabs.copy);
          actionLabel = 'העתקה מהכונן';
          actionIcon = FluentIcons.copy_arrow_right_24_regular;
        } else {
          action = db.checking ? null : db.checkRemote;
          actionLabel = 'נסו שוב';
          actionIcon = FluentIcons.arrow_sync_24_regular;
        }
      case HeroKind.notInstalled:
        action = db.busy ? null : db.updateNow;
        actionLabel = 'הורדה והתקנה';
        actionIcon = FluentIcons.arrow_download_24_regular;
      case HeroKind.updateAvailable:
        action = db.busy ? null : db.updateNow;
        actionLabel = 'עדכן עכשיו';
        actionIcon = FluentIcons.arrow_download_24_regular;
      case HeroKind.checking:
      case HeroKind.upToDate:
        action = null;
        actionLabel = '';
        actionIcon = Icons.check;
    }

    return Semantics(
      container: true,
      label: '$title. $body',
      child: Container(
        padding: const EdgeInsets.all(AppTokens.spaceLG),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              ExcludeSemantics(child: Icon(icon, size: 40, color: fg)),
              const SizedBox(width: AppTokens.spaceMD),
              Expanded(
                child: Text(title,
                    style: theme.textTheme.headlineSmall?.copyWith(color: fg, fontWeight: FontWeight.w800)),
              ),
            ]),
            const SizedBox(height: AppTokens.spaceSM),
            ExcludeSemantics(
              child: Text(body, style: theme.textTheme.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w400)),
            ),
            if (actionLabel.isNotEmpty) ...[
              const SizedBox(height: AppTokens.spaceLG),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: action,
                  icon: Icon(actionIcon),
                  label: Text(actionLabel, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: AppTokens.spaceMD),
              Row(children: [
                Icon(FluentIcons.info_24_regular, size: 18, color: fg),
                const SizedBox(width: AppTokens.spaceSM),
                Expanded(
                  child: Text('לפני שמתחילים, סגור את אוצריא.',
                      style: TextStyle(color: fg, fontSize: AppTokens.fontLG, fontWeight: FontWeight.w600)),
                ),
              ]),
            ],
            if (kind == HeroKind.upToDate) ...[
              const SizedBox(height: AppTokens.spaceSM),
              Text('אם אתם רוצים לוודא, לחצו "בדוק שוב" למטה.', style: TextStyle(color: fg)),
            ],
          ],
        ),
      ),
    );
  }
}

/// "מצב העדכונים": המחשב הזה מול הכונן, עם תגיות צבעוניות וכפתור "בדוק שוב".
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.db});
  final DbController db;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = heroKindOf(db);
    final remoteV = db.remote?.manifest.version;
    final driveV = db.mirror?.manifest.version;
    final localV = db.local?.version ?? (db.local?.state == LocalDbState.current ? remoteV : null);

    final Pill computer = switch (kind) {
      HeroKind.checking => const Pill('בודק...', PillTone.neutral),
      HeroKind.needsLocation || HeroKind.notInstalled => const Pill('לא מותקן', PillTone.warn),
      HeroKind.upToDate => Pill(localV != null ? 'גרסה $localV · מעודכן' : 'מעודכן', PillTone.good),
      HeroKind.updateAvailable =>
        Pill(localV != null ? 'גרסה $localV · יש עדכון' : 'גרסה לא מזוהה · יש עדכון', PillTone.warn),
      HeroKind.offline => const Pill('לא נבדק', PillTone.neutral),
    };

    final Pill drive;
    if (driveV == null) {
      drive = const Pill('לא נמצאו קבצים', PillTone.neutral);
    } else if ((localV != null && driveV > localV) || kind == HeroKind.notInstalled) {
      drive = Pill('גרסה $driveV · אפשר להעתיק', PillTone.warn);
    } else {
      drive = Pill('גרסה $driveV', PillTone.good);
    }

    Widget line(String label, Widget pill) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 130, child: Text(label, style: theme.textTheme.titleSmall)),
            Flexible(child: Align(alignment: AlignmentDirectional.centerStart, child: pill)),
          ]),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceMD),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                  child: Text('מצב העדכונים',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              TextButton.icon(
                onPressed: db.checking || db.busy || db.inspecting
                    ? null
                    : () async {
                        await db.refreshMirror();
                        await db.checkRemote();
                        if (db.targetDb.isNotEmpty) await db.inspectTarget();
                      },
                icon: const Icon(FluentIcons.arrow_sync_24_regular),
                label: Text(db.checking ? 'בודק...' : 'בדוק שוב'),
              ),
            ]),
            line('המחשב הזה', computer),
            line('הכונן', drive),
            if (remoteV != null) line('הגרסה האחרונה', Pill('גרסה $remoteV', PillTone.neutral)),
          ],
        ),
      ),
    );
  }
}

class _Tiles extends StatelessWidget {
  const _Tiles({required this.onNavigate});
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _Tile(
        icon: FluentIcons.usb_stick_24_regular,
        title: 'הכנה למחשב בלי אינטרנט',
        subtitle: 'מורידים כאן, ומעבירים בכונן למחשב אחר.',
        onTap: () => onNavigate(Tabs.prepare),
      ),
      _Tile(
        icon: FluentIcons.copy_arrow_right_24_regular,
        title: 'העתקה מהכונן',
        subtitle: 'במחשב בלי אינטרנט: מעתיקים את הספרים מהכונן.',
        onTap: () => onNavigate(Tabs.copy),
      ),
      _Tile(
        icon: FluentIcons.options_24_regular,
        title: 'אפשרויות מסד הספרים',
        subtitle: 'מיקום הקובץ, ש"ס וגשל ופרטים למתקדמים.',
        onTap: () => onNavigate(Tabs.db),
      ),
    ];
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 640;
      if (!wide) {
        return Column(children: [
          for (final t in tiles) Padding(padding: const EdgeInsets.only(bottom: AppTokens.spaceSM), child: t),
        ]);
      }
      return IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: AppTokens.spaceSM),
            Expanded(child: tiles[i]),
          ],
        ]),
      );
    });
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: true,
        label: '$title. $subtitle',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppTokens.spaceMD),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 28, color: theme.colorScheme.primary),
                const SizedBox(height: AppTokens.spaceSM),
                Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
