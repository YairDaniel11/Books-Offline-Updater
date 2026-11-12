import 'dart:io';

import 'package:path/path.dart' as p;

/// נעילת מופע יחיד: קובץ נעילה עם נעילת מערכת ההפעלה (LockFileEx ב-Windows, fcntl ב-Mac).
/// המערכת משחררת את הנעילה לבד כשהתהליך מסתיים, גם בקריסה, ולכן לא נשארת נעילה תקועה.
class SingleInstance {
  SingleInstance._(this._raf);

  final RandomAccessFile? _raf;

  /// מנסה לתפוס את הנעילה. `null` אם מופע אחר כבר רץ.
  /// אם אי אפשר ליצור את קובץ הנעילה בכלל (הרשאות), ממשיכים בלי הגנה ולא חוסמים את המשתמש.
  static Future<SingleInstance?> acquire(String lockFilePath) async {
    RandomAccessFile raf;
    try {
      await Directory(p.dirname(lockFilePath)).create(recursive: true);
      raf = await File(lockFilePath).open(mode: FileMode.append);
    } catch (_) {
      return SingleInstance._(null);
    }
    try {
      await raf.lock(FileLock.exclusive);
    } on FileSystemException {
      try {
        await raf.close();
      } catch (_) {}
      return null;
    }
    return SingleInstance._(raf);
  }

  Future<void> release() async {
    try {
      await _raf?.unlock();
      await _raf?.close();
    } catch (_) {}
  }
}
