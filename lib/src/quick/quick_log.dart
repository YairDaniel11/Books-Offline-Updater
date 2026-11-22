import 'dart:io';

import 'package:path/path.dart' as p;

/// לוג של "עדכון מהיר", כדי שאפשר יהיה לזהות תקלות.
///
/// נשמר ליד התוכנה (על הכונן), כך שגם לוג מהמחשב שאין בו רשת חוזר עם הכונן. כל שורה כוללת זמן ושם מחשב.
/// הקובץ מתחלף כשהוא עובר [maxBytes] (הקודם נשמר כ-`.old`). כשל בכתיבה לעולם לא מפיל את התוכנה.
class QuickLog {
  QuickLog._();

  static const fileName = 'quick-update.log';
  static const maxBytes = 1024 * 1024;

  static File? _file;

  /// נתיב קובץ הלוג, או `null` כשהלוג לא הופעל (למשל בבדיקות).
  static String? get path => _file?.path;

  static void init(String dir) {
    try {
      Directory(dir).createSync(recursive: true);
      final f = File(p.join(dir, fileName));
      if (f.existsSync() && f.lengthSync() > maxBytes) {
        final old = File('${f.path}.old');
        if (old.existsSync()) old.deleteSync();
        f.renameSync(old.path);
      }
      _file = f;
    } catch (_) {
      _file = null;
    }
  }

  static void info(String message) => _write('INFO ', message);

  static void warn(String message) => _write('WARN ', message);

  static void error(String message, [Object? error, StackTrace? stack]) {
    final b = StringBuffer(message);
    if (error != null) b.write(' | $error');
    if (stack != null) b.write('\n$stack');
    _write('ERROR', b.toString());
  }

  static void _write(String level, String message) {
    final f = _file;
    if (f == null) return;
    try {
      final host = Platform.localHostname;
      f.writeAsStringSync('${DateTime.now().toIso8601String()} [$host] $level $message\n', mode: FileMode.append);
    } catch (_) {}
  }
}
