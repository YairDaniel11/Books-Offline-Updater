import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// חלון קומפקטי בלי מסגרת של Windows (כמו מסייע ההורדות של אוצריא): גודל קבוע, ממורכז,
/// ופס כותרת שמצויר בתוכנה. בכל כשל נשאר החלון הרגיל, בלי לקרוס.
class QuickWindow {
  QuickWindow._(this._hwnd);

  final int _hwnd;

  static QuickWindow? _instance;
  static QuickWindow? get instance => _instance;

  static const _wsCaption = 0x00C00000;
  static const _wsThickFrame = 0x00040000;
  static const _wsMaximizeBox = 0x00010000;
  static const _gwlStyle = -16;
  static const _swpNoZOrder = 0x0004;
  static const _swpFrameChanged = 0x0020;
  static const _swpNoActivate = 0x0010;

  static final _user32 = DynamicLibrary.open('user32.dll');

  /// מכין את החלון לפני שהוא מוצג (החלון של Flutter נוצר מוסתר ומוצג אחרי הפריים הראשון).
  static void setUp({required double width, required double height, String? title}) {
    if (!Platform.isWindows) return;
    try {
      final hwnd = _findOwnWindow();
      if (hwnd == 0) return;
      final w = QuickWindow._(hwnd);
      w._apply(width, height);
      if (title != null) w._setTitle(title);
      _instance = w;
    } catch (_) {}
  }

  /// הכותרת בשורת המשימות וב-Alt+Tab (MaterialApp.title לא משנה אותה בווינדוס).
  void _setTitle(String title) {
    final t = title.toNativeUtf16();
    try {
      _user32.lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>), int Function(int, Pointer<Utf16>)>(
        'SetWindowTextW',
      )(_hwnd, t);
    } finally {
      calloc.free(t);
    }
  }

  static int _findOwnWindow() {
    final findEx = _user32
        .lookupFunction<
          IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
          int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
        >('FindWindowExW');
    final threadPid = _user32
        .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
          'GetWindowThreadProcessId',
        );
    final me = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId')();
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      var h = 0;
      while (true) {
        h = findEx(0, h, cls, nullptr);
        if (h == 0) return 0;
        threadPid(h, pid);
        if (pid.value == me) return h;
      }
    } finally {
      calloc.free(cls);
      calloc.free(pid);
    }
  }

  void _apply(double width, double height) {
    final getLong = _user32.lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>('GetWindowLongPtrW');
    final setLong = _user32.lookupFunction<IntPtr Function(IntPtr, Int32, IntPtr), int Function(int, int, int)>(
      'SetWindowLongPtrW',
    );
    final setPos = _user32
        .lookupFunction<
          Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
          int Function(int, int, int, int, int, int, int)
        >('SetWindowPos');
    final getDpi = _user32.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('GetDpiForWindow');
    final monitorFrom = _user32.lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>(
      'MonitorFromWindow',
    );
    final monitorInfo = _user32
        .lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('GetMonitorInfoW');

    final style = getLong(_hwnd, _gwlStyle);
    setLong(_hwnd, _gwlStyle, style & ~(_wsCaption | _wsThickFrame | _wsMaximizeBox));

    final dpi = getDpi(_hwnd);
    final scale = dpi == 0 ? 1.0 : dpi / 96.0;
    var w = (width * scale).round();
    var h = (height * scale).round();

    // ממרכזים באזור העבודה של המסך (בלי שורת המשימות). במסך נמוך מהחלון — מקטינים אותו,
    // כדי שפס הכותרת והכפתורים לא ייצאו מהמסך (אי אפשר לשנות את גודלו ידנית).
    var x = 100, y = 100;
    final info = calloc<Uint8>(40);
    try {
      info.cast<Uint32>().value = 40;
      if (monitorInfo(monitorFrom(_hwnd, 2 /* MONITOR_DEFAULTTONEAREST */), info) != 0) {
        final r = info.cast<Int32>();
        final left = r[5], top = r[6], right = r[7], bottom = r[8]; // rcWork
        w = w.clamp(1, right - left);
        h = h.clamp(1, bottom - top);
        x = left + ((right - left - w) ~/ 2);
        y = top + ((bottom - top - h) ~/ 2);
      }
    } finally {
      calloc.free(info);
    }
    setPos(_hwnd, 0, x, y, w, h, _swpNoZOrder | _swpFrameChanged | _swpNoActivate);
    _roundCorners();
  }

  /// פינות מעוגלות וצל של Windows 11 (במערכות ישנות פשוט אין השפעה).
  void _roundCorners() {
    try {
      final dwm = DynamicLibrary.open('dwmapi.dll');
      final setAttr = dwm
          .lookupFunction<
            Int32 Function(IntPtr, Uint32, Pointer<Uint32>, Uint32),
            int Function(int, int, Pointer<Uint32>, int)
          >('DwmSetWindowAttribute');
      final v = calloc<Uint32>()..value = 2; // DWMWCP_ROUND
      try {
        setAttr(_hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, v, 4);
      } finally {
        calloc.free(v);
      }
    } catch (_) {}
  }

  /// גרירת החלון מפס הכותרת שלנו.
  void startDrag() {
    try {
      _user32.lookupFunction<Int32 Function(), int Function()>('ReleaseCapture')();
      // Post ולא Send: Send היה מריץ את לולאת הגרירה של Windows בתוך הקריאה ומקפיא את הממשק עד שחרור העכבר.
      _user32.lookupFunction<Int32 Function(IntPtr, Uint32, IntPtr, IntPtr), int Function(int, int, int, int)>(
        'PostMessageW',
      )(_hwnd, 0x00A1 /* WM_NCLBUTTONDOWN */, 2 /* HTCAPTION */, 0);
    } catch (_) {}
  }

  void minimize() {
    try {
      _user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow')(_hwnd, 6);
    } catch (_) {}
  }
}
