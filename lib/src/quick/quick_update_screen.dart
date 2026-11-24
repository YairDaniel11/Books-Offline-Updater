import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// מיקוד המסך עצמו: Enter מפעיל את הכפתור הראשי רק כשאף כפתור אחר לא ממוקד.
  final FocusNode _rootFocus = FocusNode(debugLabel: 'quick-root');

  @override
  void initState() {
    super.initState();
    _lifecycle;
    c.db.confirm = _confirm;
    c.askSmartSearch = _askSmartSearch;
    c.addListener(_syncTaskbar);
    if (widget.autoStart) WidgetsBinding.instance.addPostFrameCallback((_) => c.start());
  }

  @override
  void dispose() {
    c.removeListener(_syncTaskbar);
    QuickWindow.instance?.clearProgress();
    _lifecycle.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  // ─── שורת המשימות ─────────────────────────────────────────────────

  QuickPhase? _lastPhase;

  /// התקדמות על כפתור התוכנה בשורת המשימות, והבהוב בסיום כשהחלון ממוזער או ברקע.
  void _syncTaskbar() {
    _keepFocus();
    final w = QuickWindow.instance;
    final phase = c.phase;
    final prev = _lastPhase;
    _lastPhase = phase;
    if (w == null) return;
    switch (phase) {
      case QuickPhase.working:
        final a = c.activity;
        final value = a?.progress ?? (c.db.inspecting ? c.db.inspectProgress : null);
        w.setProgress(value, paused: a?.cancelled == true);
      case QuickPhase.failed:
        if (prev != QuickPhase.failed) w.setProgress(1, error: !c.stoppedByUser, paused: c.stoppedByUser);
      case QuickPhase.checking:
      case QuickPhase.ready:
      case QuickPhase.done:
        if (prev != phase) w.clearProgress();
    }
    if (prev == QuickPhase.working && (phase == QuickPhase.done || phase == QuickPhase.failed)) {
      w.flashIfInactive();
    }
  }

  // ─── מקלדת ────────────────────────────────────────────────────────

  /// הפעולה של הכפתור הראשי במצב הנוכחי (או `null` כשאין).
  VoidCallback? get _primaryAction {
    if (c.running) return null;
    switch (c.phase) {
      case QuickPhase.ready:
        return c.action == null ? null : c.run;
      case QuickPhase.done:
        if (c.canRetrySmartSearch) return c.retrySmartSearch;
        return c.canUpdateThisComputer ? c.updateThisComputer : _close;
      case QuickPhase.failed:
        return c.start;
      case QuickPhase.checking:
      case QuickPhase.working:
        return null;
    }
  }

  /// כפתור ממוקד שנעלם (המצב התחלף) משאיר את המיקוד על ה-scope של הדף, ואז Enter/Esc לא מגיעים
  /// ל-[_onKey]. מחזירים את המיקוד למסך — רק כשאין דיאלוג פתוח מעליו.
  void _keepFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      final f = FocusManager.instance.primaryFocus;
      if (f == null || f is FocusScopeNode || f.context == null) _rootFocus.requestFocus();
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    final enter = e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter;
    // כשכפתור ממוקד (Tab), Enter מפעיל אותו עצמו ולא את הכפתור הראשי.
    if (enter && FocusManager.instance.primaryFocus == _rootFocus) {
      final action = _primaryAction;
      if (action != null) {
        action();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
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

  bool _closing = false;

  Future<void> _close() async {
    // Esc כפול או Esc ואז X: לא פותחים שני דיאלוגים של "לסגור בכל זאת?".
    if (_closing) return;
    _closing = true;
    final ok = await _mayClose();
    _closing = false;
    if (!ok) return;
    final cb = widget.onClose;
    if (cb != null) {
      cb();
    } else {
      exit(0);
    }
  }

  Future<SmartSearchAnswer?> _askSmartSearch(String size) async {
    if (!mounted) return null;
    return showDialog<SmartSearchAnswer>(context: context, builder: (ctx) => _SmartSearchDialog(size: size));
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
        body: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          // לא עוצרים עליו ב-Tab (הוא אינו פקד גלוי).
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: Column(
            children: [
              // פס כותרת מצויר רק כשהחלון הקומפקטי של Windows הוגדר. ב-Mac (או כשההגדרה נכשלה) יש מסגרת מערכת רגילה.
              if (QuickWindow.instance != null) _TitleBar(onClose: _close),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    // מסך נמוך (או טקסט מוגדל): מקטינים את הכותרת הגדולה כדי שהמצב והכפתורים ייכנסו.
                    final hero = box.maxHeight >= 540
                        ? _HeroSize.full
                        : (box.maxHeight >= 420 ? _HeroSize.compact : _HeroSize.none);
                    return Padding(
                      padding: EdgeInsets.fromLTRB(24, hero == _HeroSize.full ? 16 : 10, 24, 14),
                      child: Column(
                        children: [
                          _Hero(size: hero),
                          Expanded(child: _StateArea(child: _state())),
                          ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: _buttonHeight),
                            child: _buttons(),
                          ),
                          const SizedBox(height: 12),
                          const _Disclaimer(),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _state() {
    switch (c.phase) {
      case QuickPhase.checking:
        final inspecting = c.db.inspecting;
        final prog = c.checkingProgress;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (inspecting)
              SizedBox(
                width: 220,
                child: Row(
                  children: [
                    Expanded(child: _Bar(value: prog)),
                    if (prog != null) ...[
                      const SizedBox(width: 10),
                      Text('${(prog * 100).round()}%', style: _faint),
                    ],
                  ],
                ),
              )
            else
              const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(height: 14),
            Text(c.checkingText, textAlign: TextAlign.center, style: _muted),
            if (c.canSkipNetwork) ...[
              const SizedBox(height: 6),
              const Text(
                'השרת לא עונה. אפשר לדלג ולעדכן מהקבצים שבכונן.',
                textAlign: TextAlign.center,
                style: _faint,
              ),
            ],
          ],
        );
      case QuickPhase.ready:
        final notes = c.releaseNotes;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Lines(title: c.title, detail: c.detail),
            if (c.action == QuickAction.install) ...[
              const SizedBox(height: 16),
              _Location(path: c.installFolder, onChange: c.running ? null : _changeLocation),
            ],
            if (c.showsSmartSearchChoice) ...[const SizedBox(height: 8), _smartChoice()],
            if (notes.isNotEmpty) ...[const SizedBox(height: 14), _ReleaseNotes(text: notes)],
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
            if (c.showsSmartSearchChoice) ...[const SizedBox(height: 8), _smartChoice()],
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
            // אזור המצב כולו נגלל, כך שהודעה ארוכה לא נחתכת.
            SelectableText(
              c.message.isEmpty ? 'הפעולה לא הושלמה.' : c.message,
              textAlign: TextAlign.center,
              style: _muted,
            ),
            if (!soft)
              Wrap(
                alignment: WrapAlignment.center,
                children: [
                  if (QuickLog.path != null && (Platform.isWindows || Platform.isMacOS))
                    _LinkButton(text: 'פתיחת קובץ הלוג', onPressed: _openLog),
                  _LinkButton(text: 'העתקת פרטי התקלה', onPressed: _copyDetails),
                ],
              ),
          ],
        );
    }
  }

  /// הבחירה השמורה בחיפוש החכם, עם "שינוי" (חוזרים לשאול).
  Widget _smartChoice() => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(c.smartSearchChoice == true ? 'החיפוש החכם יורד תמיד' : 'החיפוש החכם לא יורד', style: _faint),
      _LinkButton(text: 'שינוי', onPressed: () => c.setSmartSearchChoice(null)),
    ],
  );

  /// מעתיק את ההודעה, הפרטים הטכניים ומיקום הלוג — לצירוף לדיווח על תקלה.
  Future<void> _copyDetails() async {
    final text = [
      c.message,
      if (c.errorDetails != null) c.errorDetails!,
      if (QuickLog.path != null) 'קובץ הלוג: ${QuickLog.path}',
    ].join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('פרטי התקלה הועתקו'), duration: Duration(seconds: 2)),
    );
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
        if (c.canSkipNetwork) return _GhostButton(text: 'דילוג – עדכון מהכונן', onPressed: c.skipNetwork);
        return const SizedBox.shrink();
      case QuickPhase.ready:
        return switch (c.action) {
          QuickAction.download => _PrimaryButton(text: 'הורדה', onPressed: c.running ? null : c.run),
          QuickAction.update => _PrimaryButton(text: 'עדכון', onPressed: c.running ? null : c.run),
          QuickAction.install => _PrimaryButton(text: 'התקנה', onPressed: c.running ? null : c.run),
          null => const SizedBox.shrink(),
        };
      case QuickPhase.working:
        final a = c.activity;
        return _GhostButton(
          text: a?.cancelled == true ? 'עוצר...' : 'עצירה',
          onPressed: a == null || a.cancelled ? null : c.cancel,
        );
      case QuickPhase.done:
        if (c.canRetrySmartSearch) {
          return Row(
            children: [
              Expanded(
                flex: 3,
                child: _PrimaryButton(text: 'התקנת החיפוש החכם', onPressed: c.running ? null : c.retrySmartSearch),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: _GhostButton(text: 'סגירה', onPressed: _close),
              ),
            ],
          );
        }
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

const _buttonHeight = 44.0;

/// אזור המצב: ממורכז כשיש מקום, ונגלל כשהתוכן גבוה ממנו (הודעה ארוכה, מסך נמוך, טקסט מוגדל).
class _StateArea extends StatelessWidget {
  const _StateArea({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Center(
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: child),
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value});
  final double? value;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: LinearProgressIndicator(value: value, minHeight: 8, backgroundColor: QuickColors.track),
  );
}

class _LinkButton extends StatelessWidget {
  const _LinkButton({required this.text, required this.onPressed});
  final String text;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(foregroundColor: QuickColors.faint),
    child: Text(text, style: const TextStyle(fontSize: 12.5)),
  );
}

/// "מה חדש" בגרסה המוצעת, מתוך נתוני הגרסה.
class _ReleaseNotes extends StatelessWidget {
  const _ReleaseNotes({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: QuickColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: QuickColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'מה חדש',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: QuickColors.muted),
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 96),
            child: SingleChildScrollView(
              child: SelectableText(text, style: const TextStyle(fontSize: 12.5, color: QuickColors.muted, height: 1.4)),
            ),
          ),
        ],
      ),
    );
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
          if (win != null) _CaptionButton(glyph: '', tooltip: 'מזעור', onTap: win.minimize),
          _CaptionButton(glyph: '', tooltip: 'סגירה', onTap: onClose, danger: true),
        ],
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({required this.glyph, required this.tooltip, required this.onTap, this.danger = false});
  final String glyph;
  final String tooltip;
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
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
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
      ),
    );
  }
}

/// full: אייקון וכותרת מלאה. compact: כותרת קטנה בלבד. none: בלי (מסך נמוך מאוד).
enum _HeroSize { full, compact, none }

class _Hero extends StatelessWidget {
  const _Hero({required this.size});
  final _HeroSize size;

  @override
  Widget build(BuildContext context) {
    if (size == _HeroSize.none) return const SizedBox.shrink();
    final full = size == _HeroSize.full;
    return Column(
      children: [
        if (full) ...[
          // הרקע הלבן של האייקון נבלע בצבע הדף (multiply), כך שנשאר רק הספר המוזהב.
          Image.asset(
            'assets/icon.png',
            width: 84,
            height: 84,
            color: QuickColors.page,
            colorBlendMode: BlendMode.multiply,
            errorBuilder: (_, _, _) => const SizedBox(height: 84),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          'עדכון מסד הספרים',
          style: TextStyle(fontSize: full ? 24 : 19, fontWeight: FontWeight.w600, color: QuickColors.text),
        ),
        if (!full) ...[
          const SizedBox(height: 2),
          const Text('מאגר הספרים הלא רשמי', style: TextStyle(fontSize: 13, color: QuickColors.muted)),
        ] else ...[
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
    final a = c.activity;
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
        _Bar(value: value),
        const SizedBox(height: 8),
        Tooltip(
          message: a?.detail ?? '',
          child: Text(a?.detail ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: _faint),
        ),
        // גובה קבוע לשורת המהירות, כדי שהמסך לא יקפוץ כשההערכה מופיעה.
        const SizedBox(height: 2),
        Text(c.rateText, maxLines: 1, overflow: TextOverflow.ellipsis, style: _faint),
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

/// "להוריד גם את החיפוש החכם?" עם "לזכור את הבחירה". סגירה בלי בחירה מחזירה `null`.
class _SmartSearchDialog extends StatefulWidget {
  const _SmartSearchDialog({required this.size});
  final String size;

  @override
  State<_SmartSearchDialog> createState() => _SmartSearchDialogState();
}

class _SmartSearchDialogState extends State<_SmartSearchDialog> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    void answer(bool download) =>
        Navigator.of(context).pop(SmartSearchAnswer(download: download, remember: _remember));
    return AlertDialog(
      title: const Text('להוריד גם את החיפוש החכם?', style: _title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'חיפוש לפי משמעות בספרי המאגר, בתוך אוצריא'
            '${widget.size.isEmpty ? '' : ' (${widget.size})'}.\n'
            'במחשב ללא רשת הוא יותקן אוטומטית, אם החיפוש החכם של אוצריא מופעל שם.',
            style: _muted,
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: _remember,
            onChanged: (v) => setState(() => _remember = v ?? false),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('לזכור את הבחירה ולא לשאול שוב', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => answer(false), child: const Text('לא')),
        FilledButton(onPressed: () => answer(true), child: const Text('כן, להוריד')),
      ],
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
    // גובה מינימלי ולא קבוע: עם טקסט מוגדל הכפתור גדל במקום לחתוך את הכיתוב.
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, _buttonHeight)),
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
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, _buttonHeight),
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

/// התוכנה כבר פתוחה (בחלון אחר) כשמפעילים אותה מתוך עדכוני אוצריא: הודעה באותו חלון קומפקטי.
class QuickAlreadyRunningScreen extends StatelessWidget {
  const QuickAlreadyRunningScreen({super.key, required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): onClose,
          const SingleActivator(LogicalKeyboardKey.enter): onClose,
        },
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              if (QuickWindow.instance != null) _TitleBar(onClose: onClose),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 14),
                    child: Column(
                      children: [
                        _Hero(size: box.maxHeight >= 540 ? _HeroSize.full : _HeroSize.compact),
                        const Expanded(
                          child: _StateArea(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _Badge(ok: false, soft: true),
                                SizedBox(height: 12),
                                Text('התוכנה כבר פתוחה', style: _title),
                                SizedBox(height: 6),
                                Text(
                                  'עברו לחלון הפתוח, או סגרו אותו ונסו שוב.\nפתיחה כפולה עלולה לפגוע במסד הספרים.',
                                  textAlign: TextAlign.center,
                                  style: _muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                        _PrimaryButton(text: 'סגירה', onPressed: onClose),
                        const SizedBox(height: 12),
                        const _Disclaimer(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
