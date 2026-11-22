import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../db/db_controller.dart' show DbController;
import 'quick_log.dart';
import 'quick_update_controller.dart';
import 'quick_window.dart';

/// צבעי המסך, ברוח מסייע ההורדות של אוצריא.
class QuickColors {
  static const page = Color(0xFFF6EDE5);
  static const titleBar = Color(0xFFF3E6DA);
  static const titleBarBorder = Color(0xFFE1D4C8);
  static const captionHover = Color(0xFFEDE4DC);
  static const card = Color(0xFFFFF8F4);
  static const divider = Color(0xFFD3C4B4);
  static const primary = Color(0xFF805610);
  static const primaryHover = Color(0xFF6E4A0D);
  static const gold = Color(0xFFB08A3E);
  static const text = Color(0xFF201B13);
  static const muted = Color(0xFF4F4539);
  static const faint = Color(0xFF817567);
  static const track = Color(0xFFE8DCCD);
  static const tile = Color(0xFFFBDEBC);
  static const onTonal = Color(0xFF56442A);
  static const error = Color(0xFFBA1A1A);
  static const disabled = Color(0xFFDDD3CC);
  static const disabledText = Color(0xFFA59D95);
}

ThemeData quickTheme() {
  const scheme = ColorScheme.light(
    primary: QuickColors.primary,
    onPrimary: Colors.white,
    surface: QuickColors.card,
    onSurface: QuickColors.text,
    error: QuickColors.error,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: QuickColors.page,
    dialogTheme: const DialogThemeData(backgroundColor: QuickColors.card),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: QuickColors.primary),
  );
}

/// גודל החלון (בפיקסלים לוגיים), כמו מסייע ההורדות של אוצריא.
const quickWindowWidth = 400.0;
const quickWindowHeight = 620.0;

/// מסך יחיד של "עדכון מהיר": בדיקה אוטומטית בפתיחה, ואז כפתור אחד.
class QuickUpdateScreen extends StatefulWidget {
  const QuickUpdateScreen({super.key, required this.controller, this.autoStart = true, this.onClose, this.pickFolder});

  final QuickUpdateController controller;
  final bool autoStart;

  /// ברירת מחדל: יציאה מהתהליך (עדכוני אוצריא ממתינה לה).
  final VoidCallback? onClose;

  /// בחירת תיקייה (מוזרק בבדיקות). ברירת מחדל: חלון בחירת תיקייה של המערכת.
  final Future<String?> Function(String initialDirectory)? pickFolder;

  @override
  State<QuickUpdateScreen> createState() => _QuickUpdateScreenState();
}

class _QuickUpdateScreenState extends State<QuickUpdateScreen> {
  QuickUpdateController get c => widget.controller;

  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);

  @override
  void initState() {
    super.initState();
    _lifecycle;
    c.db.confirm = _confirm;
    if (widget.autoStart) WidgetsBinding.instance.addPostFrameCallback((_) => c.start());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<AppExitResponse> _onExitRequested() async => await _mayClose() ? AppExitResponse.exit : AppExitResponse.cancel;

  Future<bool> _mayClose() async {
    if (!c.running || !mounted) return true;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _Dialog(
        text: 'הפעולה עדיין רצה. לסגור בכל זאת?\nהמסד הקיים לא ייפגע, ואפשר להמשיך אחר כך.',
        okText: 'לסגור',
        cancelText: 'להישאר',
      ),
    );
    return ok == true;
  }

  Future<void> _close() async {
    if (!await _mayClose()) return;
    final cb = widget.onClose;
    if (cb != null) {
      cb();
    } else {
      exit(0);
    }
  }

  Future<bool> _confirm(String message) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => _Dialog(
        text: message == DbController.unknownDbConfirmText
            ? 'גרסת המסד במחשב הזה לא מזוהה, והוא יוחלף במסד המלא שבכונן.\n\n'
                  'אם המסד במחשב חדש יותר מזה שבכונן, הכינו קודם את הכונן מחדש במחשב מחובר.'
            : message,
        okText: 'להחליף',
        cancelText: 'ביטול',
      ),
    );
    return ok == true;
  }

  /// "שינוי": רק מחליף את המיקום שנבחר. ההתקנה עצמה בכפתור "התקנה".
  Future<void> _changeLocation() async {
    final initial = c.installFolder;
    final pick =
        widget.pickFolder ??
        (String dir) => FilePicker.getDirectoryPath(
          dialogTitle: 'בחירת מיקום למסד הספרים',
          initialDirectory: _nearestExisting(dir),
        );
    final folder = await pick(initial);
    if (folder != null) c.changeFolder(folder);
  }

  /// התיקייה הקרובה ביותר שקיימת (המוצעת אולי עוד לא נוצרה), כדי שחלון הבחירה ייפתח לידה.
  static String? _nearestExisting(String dir) {
    var d = dir;
    for (var i = 0; i < 4; i++) {
      if (Directory(d).existsSync()) return d;
      final parent = Directory(d).parent.path;
      if (parent == d) break;
      d = parent;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        body: Column(
          children: [
            // פס כותרת מצויר רק ב-Windows (שם החלון בלי מסגרת). ב-Mac יש מסגרת מערכת רגילה.
            if (!Platform.isMacOS) _TitleBar(onClose: _close),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                child: Column(
                  children: [
                    const _Hero(),
                    Expanded(child: Center(child: _state())),
                    SizedBox(height: 44, child: _buttons()),
                    const SizedBox(height: 14),
                    const _Disclaimer(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _state() {
    switch (c.phase) {
      case QuickPhase.checking:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(height: 14),
            Text(c.online == false ? 'בודק את המסד...' : 'בודק עדכונים...', style: _muted),
          ],
        );
      case QuickPhase.ready:
        if (c.action != QuickAction.install) return _Lines(title: c.title, detail: c.detail);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Lines(title: c.title, detail: c.detail),
            const SizedBox(height: 16),
            _Location(path: c.installFolder, onChange: c.running ? null : _changeLocation),
          ],
        );
      case QuickPhase.working:
        return _Progress(c: c);
      case QuickPhase.done:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Badge(ok: true),
            const SizedBox(height: 14),
            _Lines(title: c.title, detail: c.detail),
            if (c.warning != null) ...[const SizedBox(height: 12), _Note(text: c.warning!)],
          ],
        );
      case QuickPhase.failed:
        final soft = c.stoppedByUser;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Badge(ok: false, soft: soft),
            const SizedBox(height: 12),
            Text(soft ? 'הפעולה נעצרה' : 'לא הצלחנו', style: _title),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 110),
              child: SingleChildScrollView(
                child: SelectableText(
                  c.message.isEmpty ? 'הפעולה לא הושלמה.' : c.message,
                  textAlign: TextAlign.center,
                  style: _muted,
                ),
              ),
            ),
            if (QuickLog.path != null)
              TextButton(
                onPressed: _openLog,
                style: TextButton.styleFrom(foregroundColor: QuickColors.faint),
                child: const Text('פתיחת קובץ הלוג', style: TextStyle(fontSize: 12.5)),
              ),
          ],
        );
    }
  }

  /// מציג את קובץ הלוג בסייר הקבצים (כדי לצרף אותו לדיווח על תקלה).
  void _openLog() {
    final path = QuickLog.path;
    if (path == null) return;
    try {
      if (Platform.isMacOS) {
        Process.run('open', ['-R', path]);
      } else {
        Process.run('explorer.exe', ['/select,', path]);
      }
    } catch (e) {
      QuickLog.warn('פתיחת הלוג נכשלה: $e');
    }
  }

  Widget _buttons() {
    switch (c.phase) {
      case QuickPhase.checking:
        return const SizedBox.shrink();
      case QuickPhase.ready:
        return switch (c.action) {
          QuickAction.download => _PrimaryButton(text: 'הורדה', onPressed: c.running ? null : c.run),
          QuickAction.update => _PrimaryButton(text: 'עדכון', onPressed: c.running ? null : c.run),
          QuickAction.install => _PrimaryButton(text: 'התקנה', onPressed: c.running ? null : c.run),
          null => const SizedBox.shrink(),
        };
      case QuickPhase.working:
        final a = c.db.activity;
        return _GhostButton(
          text: a?.cancelled == true ? 'עוצר...' : 'עצירה',
          onPressed: a == null || a.cancelled ? null : c.db.cancel,
        );
      case QuickPhase.done:
        if (c.canUpdateThisComputer) {
          return Row(
            children: [
              Expanded(
                flex: 3,
                child: _PrimaryButton(text: 'עדכון במחשב זה', onPressed: c.running ? null : c.updateThisComputer),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _GhostButton(text: 'סגירה', onPressed: _close),
              ),
            ],
          );
        }
        return _PrimaryButton(text: 'סגירה', onPressed: _close);
      case QuickPhase.failed:
        return Row(
          children: [
            Expanded(
              child: _PrimaryButton(text: 'נסו שוב', onPressed: c.running ? null : c.start),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _GhostButton(text: 'סגירה', onPressed: _close),
            ),
          ],
        );
    }
  }
}

const _title = TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: QuickColors.text);
const _muted = TextStyle(fontSize: 13.5, color: QuickColors.muted, height: 1.4);
const _faint = TextStyle(fontSize: 13, color: QuickColors.faint);

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final win = QuickWindow.instance;
    return Container(
      height: 32,
      decoration: const BoxDecoration(
        color: QuickColors.titleBar,
        border: Border(bottom: BorderSide(color: QuickColors.titleBarBorder)),
      ),
      child: Row(
        children: [
          // אזור הגרירה: כל הפס חוץ מכפתורי החלון.
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: win == null ? null : (_) => win.startDrag(),
              child: const Padding(
                padding: EdgeInsetsDirectional.only(start: 12),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    'עדכון מסד הספרים',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: QuickColors.muted),
                  ),
                ),
              ),
            ),
          ),
          if (win != null) _CaptionButton(glyph: '', onTap: win.minimize),
          _CaptionButton(glyph: '', onTap: onClose, danger: true),
        ],
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({required this.glyph, required this.onTap, this.danger = false});
  final String glyph;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = !_hover ? Colors.transparent : (widget.danger ? const Color(0xFFC42B1C) : QuickColors.captionHover);
    final fg = _hover && widget.danger ? Colors.white : QuickColors.text;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: 32,
          color: bg,
          alignment: Alignment.center,
          child: Text(
            widget.glyph,
            style: TextStyle(
              fontFamily: 'Segoe Fluent Icons',
              fontFamilyFallback: const ['Segoe MDL2 Assets'],
              fontSize: 10,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // הרקע הלבן של האייקון נבלע בצבע הדף (multiply), כך שנשאר רק הספר המוזהב.
        Image.asset(
          'assets/icon.png',
          width: 104,
          height: 104,
          color: QuickColors.page,
          colorBlendMode: BlendMode.multiply,
          errorBuilder: (_, _, _) => const SizedBox(height: 104),
        ),
        const SizedBox(height: 10),
        const Text(
          'עדכון מסד הספרים',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, color: QuickColors.text),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _goldLine(),
            const SizedBox(width: 6),
            Transform.rotate(angle: 0.785398, child: Container(width: 6, height: 6, color: QuickColors.gold)),
            const SizedBox(width: 6),
            _goldLine(),
          ],
        ),
        const SizedBox(height: 8),
        const Text('מאגר הספרים הלא רשמי', style: TextStyle(fontSize: 15, color: QuickColors.muted)),
      ],
    );
  }

  static Widget _goldLine() => Container(
    width: 56,
    height: 1.2,
    decoration: const BoxDecoration(
      gradient: LinearGradient(colors: [Color(0x00B08A3E), QuickColors.gold, Color(0x00B08A3E)]),
    ),
  );
}

class _Lines extends StatelessWidget {
  const _Lines({required this.title, required this.detail});
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, textAlign: TextAlign.center, style: _title),
        if (detail.isNotEmpty) ...[const SizedBox(height: 4), Text(detail, textAlign: TextAlign.center, style: _faint)],
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.c});
  final QuickUpdateController c;

  @override
  Widget build(BuildContext context) {
    final a = c.db.activity;
    final inspecting = a == null && c.db.inspecting;
    final value = a?.progress ?? (inspecting ? c.db.inspectProgress : null);
    final title = a?.title ?? (inspecting ? 'מזהה את גרסת המסד' : 'מתכונן');
    final pct = value == null ? '' : '${(value * 100).round()}%';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: QuickColors.text),
              ),
            ),
            Text(pct, style: const TextStyle(fontSize: 15, color: QuickColors.muted)),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: value, minHeight: 8, backgroundColor: QuickColors.track),
        ),
        const SizedBox(height: 8),
        Text(a?.detail ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: _faint),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.ok, this.soft = false});
  final bool ok;
  final bool soft;

  @override
  Widget build(BuildContext context) {
    final color = ok || soft ? QuickColors.primary : QuickColors.error;
    final icon = ok ? Icons.check_rounded : (soft ? Icons.pause_rounded : Icons.priority_high_rounded);
    return Container(
      width: 72,
      height: 72,
      padding: const EdgeInsets.all(6),
      decoration: const BoxDecoration(color: Color(0xFFEFE8DF), shape: BoxShape.circle),
      child: Container(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 34),
      ),
    );
  }
}

/// מיקום ההתקנה שכבר נבחר (ברירת המחדל), עם כפתור קטן לשינוי.
class _Location extends StatelessWidget {
  const _Location({required this.path, required this.onChange});
  final String path;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.only(start: 12, end: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: QuickColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: QuickColors.divider),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 18, color: QuickColors.faint),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: path,
              child: Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12, color: QuickColors.muted),
              ),
            ),
          ),
          TextButton(
            onPressed: onChange,
            style: TextButton.styleFrom(foregroundColor: QuickColors.primary),
            child: const Text('שינוי', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: QuickColors.tile, borderRadius: BorderRadius.circular(8)),
      child: SelectableText(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12.5, color: QuickColors.onTonal),
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: QuickColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: QuickColors.divider),
      ),
      child: const Text(
        'המסד אינו חלק מתוכנת אוצריא ואינו באחריותה.\nאין לפנות לאוצריא בנושאים הקשורים למסד זה.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: QuickColors.muted, height: 1.4),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.text, required this.onPressed});
  final String text;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: FilledButton(
        onPressed: onPressed,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? QuickColors.disabled
                : s.contains(WidgetState.hovered)
                ? QuickColors.primaryHover
                : QuickColors.primary,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? QuickColors.disabledText : Colors.white,
          ),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
        child: Text(text),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({required this.text, required this.onPressed});
  final String text;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: QuickColors.primary,
          side: const BorderSide(color: QuickColors.divider),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        child: Text(text),
      ),
    );
  }
}

class _Dialog extends StatelessWidget {
  const _Dialog({required this.text, required this.okText, required this.cancelText});
  final String text;
  final String okText;
  final String cancelText;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      content: Text(text, style: const TextStyle(fontSize: 14, color: QuickColors.text, height: 1.4)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(cancelText)),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: QuickColors.primary),
          onPressed: () => Navigator.pop(context, true),
          child: Text(okText),
        ),
      ],
    );
  }
}
