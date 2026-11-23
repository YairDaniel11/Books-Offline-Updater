import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// רישום התוכנה ברשימת "אפליקציות מותקנות" של Windows (למשתמש הנוכחי, בלי הרשאות מנהל).
///
/// למה: עדכוני אוצריא מריצה את `BooksOfflineUpdate.exe` כ"מתקין", ואחר כך **לומדת** איפה התוכנה
/// הותקנה מרישום הסרה שנולד ברג'יסטרי. תוכנה ניידת לא רושמת כלום, ואז עדכוני אוצריא אימצה
/// רישום קיים של תוכנה אחרת ששמה דומה ("שירות הדיבור של אוצריא"), ו"הפעלה" הריצה אותה במקומנו.
/// עם הרישום הזה היא לומדת את התיקייה שלנו ואת `BooksOfflineUpdate.exe`, ו"הפעלה" מפעילה אותנו.
///
/// השם המוצג חייב להכיל `BooksOfflineUpdate` (בלי רווחים, אחרי נירמול): זה הרמז שעדכוני אוצריא
/// גוזרת משם קובץ ההתקנה, והארוך מבין הרמזים, ולכן הוא שמכריע את ההתאמה.
class WindowsRegistration {
  WindowsRegistration._();

  static const keyName = 'BooksOfflineUpdate';
  static const _uninstallPath = r'Software\Microsoft\Windows\CurrentVersion\Uninstall';
  static const keyPath = '$_uninstallPath\\$keyName';

  /// הארגומנט ש"הסרה" מ-Windows מפעילה: מוחק את הרישום בלבד (התוכנה עצמה ניידת, אין מה להסיר).
  static const unregisterArg = '--unregister';

  /// הערכים שנכתבים. [exePath]: ה-exe המקורי (לא העותק המחולץ בתיקייה הזמנית).
  static Map<String, Object> values({required String exePath, required String version}) => {
    'DisplayName': 'BooksOfflineUpdate - מאגר ספרים לא רשמי לאוצריא',
    if (version.isNotEmpty) 'DisplayVersion': version,
    'Publisher': 'Books-Offline-Updater',
    'InstallLocation': p.dirname(exePath),
    'DisplayIcon': exePath,
    'UninstallString': '"$exePath" $unregisterArg',
    'NoModify': 1,
    'NoRepair': 1,
  };

  static const _hkcu = 0x80000001;
  static const _keyWrite = 0x20006;
  static const _regSz = 1;
  static const _regDword = 4;

  static final _advapi = DynamicLibrary.open('advapi32.dll');

  /// כותב (או מעדכן) את הרישום. מחזיר `false` בכל כשל, בלי לזרוק: הרישום הוא תוספת, לא תנאי לעבודה.
  static bool register({required String exePath, required String version}) {
    if (!Platform.isWindows) return false;
    final create = _advapi.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Pointer<IntPtr>, Pointer<Uint32>),
      int Function(int, Pointer<Utf16>, int, Pointer<Utf16>, int, int, Pointer<Void>, Pointer<IntPtr>, Pointer<Uint32>)
    >('RegCreateKeyExW');
    final setValue = _advapi.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<Uint8>, Uint32),
      int Function(int, Pointer<Utf16>, int, int, Pointer<Uint8>, int)
    >('RegSetValueExW');
    final close = _advapi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey');

    final path = keyPath.toNativeUtf16();
    final hkey = calloc<IntPtr>();
    try {
      if (create(_hkcu, path, 0, nullptr, 0, _keyWrite, nullptr, hkey, nullptr) != 0) return false;
      var ok = true;
      try {
        for (final e in values(exePath: exePath, version: version).entries) {
          final name = e.key.toNativeUtf16();
          try {
            final v = e.value;
            if (v is int) {
              final data = calloc<Uint32>()..value = v;
              try {
                ok &= setValue(hkey.value, name, 0, _regDword, data.cast(), 4) == 0;
              } finally {
                calloc.free(data);
              }
            } else {
              final s = (v as String).toNativeUtf16();
              try {
                // גודל בבתים כולל ה-NUL שבסוף.
                ok &= setValue(hkey.value, name, 0, _regSz, s.cast(), (v.length + 1) * 2) == 0;
              } finally {
                calloc.free(s);
              }
            }
          } finally {
            calloc.free(name);
          }
        }
      } finally {
        close(hkey.value);
      }
      return ok;
    } catch (_) {
      return false;
    } finally {
      calloc.free(path);
      calloc.free(hkey);
    }
  }

  /// מוחק את הרישום ("הסרה" מהגדרות Windows). `true` גם כשהוא כבר לא היה קיים.
  static bool unregister() {
    if (!Platform.isWindows) return false;
    final path = keyPath.toNativeUtf16();
    try {
      final delete = _advapi.lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>), int Function(int, Pointer<Utf16>)>(
        'RegDeleteKeyW',
      );
      final r = delete(_hkcu, path);
      return r == 0 || r == 2 /* ERROR_FILE_NOT_FOUND */;
    } catch (_) {
      return false;
    } finally {
      calloc.free(path);
    }
  }
}
