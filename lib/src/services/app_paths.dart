import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows_parent.dart';

const pakFileName = 'OtzariaBooks.pak';

/// מיקומי הקבצים של התוכנה: ה-PAK וההגדרות יושבים ליד התוכנה (כך הכול עובר יחד בדיסק און קי),
/// אלא אם המשתמש בחר תיקייה אחרת.
class AppPaths {
  AppPaths._();

  /// התיקייה שבה התוכנה רצה. ב-Mac זו התיקייה שמכילה את ה-.app.
  static String programDir() {
    final exe = Platform.resolvedExecutable;
    if (Platform.isWindows) {
      // exe יחיד (SFX): התוכנה מחולצת לתיקייה זמנית של 7-Zip, והאב שלה הוא ה-exe המקורי.
      final dir = p.dirname(exe);
      final temp = (Platform.environment['TEMP'] ?? Platform.environment['TMP'] ?? '').toLowerCase();
      if (temp.isNotEmpty &&
          p.basename(dir).startsWith('7z') &&
          p.dirname(dir).toLowerCase() == p.normalize(temp)) {
        final parent = windowsParentExecutable();
        if (parent != null) return p.dirname(parent);
      }
    }
    final marker = '.app${Platform.pathSeparator}Contents${Platform.pathSeparator}MacOS';
    final i = exe.indexOf(marker);
    if (i >= 0) return p.dirname(exe.substring(0, i + 4));
    return p.dirname(exe);
  }

  static String _userConfigDir() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null) return p.join(appData, 'BooksOfflineUpdater');
    }
    final home = Platform.environment['HOME'] ?? '.';
    return p.join(home, 'Library', 'Application Support', 'BooksOfflineUpdater');
  }

  static File get _overrideFile => File(p.join(_userConfigDir(), 'location.txt'));

  /// תיקיית הנתונים: מה שנבחר ידנית, ואם אין — ליד התוכנה.
  static Future<String> dataDir() async {
    try {
      final f = _overrideFile;
      if (await f.exists()) {
        final d = (await f.readAsString()).trim();
        if (d.isNotEmpty && await Directory(d).exists()) return d;
      }
    } catch (_) {}
    return programDir();
  }

  static Future<void> setDataDirOverride(String? dir) async {
    final f = _overrideFile;
    if (dir == null) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.parent.create(recursive: true);
    await f.writeAsString(dir);
  }
}
