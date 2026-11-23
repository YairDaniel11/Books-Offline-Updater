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

  // ---- התקדמות בכפתור שורת המשימות (ITaskbarList3) ----

  static const _tbpfNoProgress = 0x0;
  static const _tbpfIndeterminate = 0x1;
  static const _tbpfNormal = 0x2;
  static const _tbpfError = 0x4;
  static const _tbpfPaused = 0x8;

  /// מצביע לאובייקט ה-COM (כתובת); 0 = עדיין לא נוצר.
  int _taskbar = 0;

  /// היצירה נכשלה פעם אחת - לא מנסים שוב בכל קריאה.
  bool _taskbarFailed = false;

  int? _lastFlags;
  double? _lastValue;

  /// פונקציה מתוך ה-vtable של אובייקט COM (מיקום במצביעים).
  Pointer<NativeFunction<T>> _vtblSlot<T extends Function>(int obj, int slot) {
    final vtbl = Pointer<IntPtr>.fromAddress(Pointer<IntPtr>.fromAddress(obj).value);
    return Pointer<NativeFunction<T>>.fromAddress(vtbl[slot]);
  }

  bool _ensureTaskbar() {
    if (_taskbar != 0) return true;
    if (_taskbarFailed) return false;
    final clsid = calloc<ComGuid>();
    final iid = calloc<ComGuid>();
    final out = calloc<IntPtr>();
    try {
      final ole = DynamicLibrary.open('ole32.dll');
      final coInit = ole.lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>(
        'CoInitializeEx',
      );
      final coCreate = ole
          .lookupFunction<
            Int32 Function(Pointer<ComGuid>, Pointer<Void>, Uint32, Pointer<ComGuid>, Pointer<IntPtr>),
            int Function(Pointer<ComGuid>, Pointer<Void>, int, Pointer<ComGuid>, Pointer<IntPtr>)
          >('CoCreateInstance');
      // S_OK / S_FALSE / RPC_E_CHANGED_MODE - בכולם ממשיכים.
      coInit(nullptr, 0x2 /* COINIT_APARTMENTTHREADED */);
      clsid.ref.set(0x56FDF344, 0xFD6D, 0x11D0, const [0x95, 0x8A, 0x00, 0x60, 0x97, 0xC9, 0xA0, 0x90]);
      iid.ref.set(0xEA1AFB91, 0x9E28, 0x4B86, const [0x90, 0xE9, 0x9E, 0x9F, 0x8A, 0x5E, 0xEF, 0xAF]);
      final hr = coCreate(clsid, nullptr, 1 /* CLSCTX_INPROC_SERVER */, iid, out);
      if (hr < 0 || out.value == 0) {
        _taskbarFailed = true;
        return false;
      }
      final obj = out.value;
      final hrInit = _vtblSlot<Int32 Function(IntPtr)>(obj, 3).asFunction<int Function(int)>()(obj);
      if (hrInit < 0) {
        _vtblSlot<Uint32 Function(IntPtr)>(obj, 2).asFunction<int Function(int)>()(obj);
        _taskbarFailed = true;
        return false;
      }
      _taskbar = obj;
      return true;
    } catch (_) {
      _taskbarFailed = true;
      return false;
    } finally {
      calloc.free(clsid);
      calloc.free(iid);
      calloc.free(out);
    }
  }

  /// התקדמות בכפתור שורת המשימות. [value] בין 0 ל-1; null = לא ידוע (אינדיקציה מתמשכת).
  void setProgress(double? value, {bool error = false, bool paused = false}) {
    if (!Platform.isWindows) return;
    try {
      final int flags;
      if (error) {
        flags = _tbpfError;
      } else if (paused) {
        flags = _tbpfPaused;
      } else if (value == null) {
        flags = _tbpfIndeterminate;
      } else {
        flags = _tbpfNormal;
      }
      final v = value?.clamp(0.0, 1.0).toDouble();
      if (flags == _lastFlags) {
        final last = _lastValue;
        // הצעד האחרון אל 0 או 1 תמיד נשלח, כדי שהפס לא ייעצר על 999/1000.
        if (v == last || (v != null && last != null && v > 0 && v < 1 && (v - last).abs() < 0.002)) return;
      }
      if (!_ensureTaskbar()) return;
      final obj = _taskbar;
      var hrState = 0, hrValue = 0;
      // מצב לפני ערך כשהמצב משתנה: אחרת SetProgressValue מחזיר לרגע "רגיל" ממצב שגיאה/השהיה.
      void setState() => hrState = _vtblSlot<Int32 Function(IntPtr, IntPtr, Int32)>(
        obj,
        10,
      ).asFunction<int Function(int, int, int)>()(obj, _hwnd, flags);
      if (flags != _lastFlags) setState();
      if (flags != _tbpfIndeterminate && v != null) {
        hrValue = _vtblSlot<Int32 Function(IntPtr, IntPtr, Uint64, Uint64)>(
          obj,
          9,
        ).asFunction<int Function(int, int, int, int)>()(obj, _hwnd, (v * 1000).round(), 1000);
      }
      // נכשל (למשל כפתור שורת המשימות עוד לא נוצר): לא שומרים, כדי שהקריאה הבאה תנסה שוב.
      if (hrState < 0 || hrValue < 0) return;
      _lastFlags = flags;
      _lastValue = v;
    } catch (_) {}
  }

  /// מנקה את ההתקדמות מכפתור שורת המשימות.
  void clearProgress() {
    if (!Platform.isWindows) return;
    try {
      _lastFlags = null;
      _lastValue = null;
      if (_taskbar == 0) return;
      final obj = _taskbar;
      _vtblSlot<Int32 Function(IntPtr, IntPtr, Int32)>(
        obj,
        10,
      ).asFunction<int Function(int, int, int)>()(obj, _hwnd, _tbpfNoProgress);
    } catch (_) {}
  }

  /// מהבהב בשורת המשימות עד שהמשתמש חוזר לחלון - רק אם החלון אינו בחזית.
  void flashIfInactive() {
    if (!Platform.isWindows) return;
    Pointer<FlashWInfo>? info;
    try {
      final fg = _user32.lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow')();
      if (fg == _hwnd) return;
      info = calloc<FlashWInfo>();
      info.ref
        ..cbSize = sizeOf<FlashWInfo>()
        ..hwnd = _hwnd
        ..dwFlags =
            2 /* FLASHW_TRAY: לחלון אין פס כותרת של המערכת */ | 0xC /* FLASHW_TIMERNOFG */
        ..uCount = 0
        ..dwTimeout = 0;
      _user32.lookupFunction<Int32 Function(Pointer<FlashWInfo>), int Function(Pointer<FlashWInfo>)>(
        'FlashWindowEx',
      )(info);
    } catch (_) {
    } finally {
      if (info != null) calloc.free(info);
    }
  }
}

/// GUID של COM (16 בתים).
final class ComGuid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;

  void set(int d1, int d2, int d3, List<int> d4) {
    data1 = d1;
    data2 = d2;
    data3 = d3;
    for (var i = 0; i < 8; i++) {
      data4[i] = d4[i];
    }
  }
}

/// FLASHWINFO של Windows (ב-x64 גודלו 32 בגלל ריפוד אחרי cbSize).
final class FlashWInfo extends Struct {
  @Uint32()
  external int cbSize;
  @IntPtr()
  external int hwnd;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int uCount;
  @Uint32()
  external int dwTimeout;
}
