import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../db/db_manifest.dart' show dbLibraryId;

/// מאתר את מסד הספרים שלנו כפי שצורף לאוצריא במחשב הזה.
///
/// אוצריא שומרת את רשימת המסדים שצורפו (key-attached-libraries) כמחרוזת JSON בתוך
/// `app_preferences.hive` שבתיקיית הנתונים שלה, עם הנתיב לקובץ ("mode":"link").
/// Hive כותב ברצף ומוסיף רשומה חדשה בכל שינוי, ולכן הרשומה האחרונה בקובץ היא העדכנית.
class OtzariaLocator {
  OtzariaLocator._();

  /// תיקיות הנתונים האפשריות של אוצריא.
  static List<String> _dataRoots() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      return [
        if (env['APPDATA'] != null) p.join(env['APPDATA']!, 'otzaria'),
        if (env['ProgramData'] != null) p.join(env['ProgramData']!, 'otzaria'),
      ];
    }
    final home = env['HOME'];
    return [if (home != null) p.join(home, 'Library', 'Application Support', 'otzaria')];
  }

  static final _slugRecord = RegExp('"slug"\\s*:\\s*"${RegExp.escape(dbLibraryId)}"[^{}]*?"path"\\s*:\\s*("(?:[^"\\\\]|\\\\.)*")');

  /// הנתיב של קובץ המסד שצורף לאוצריא, או null כשלא צורף במחשב הזה.
  static Future<String?> findDbPath() async {
    for (final root in _dataRoots()) {
      try {
        final f = File(p.join(root, 'app_preferences.hive'));
        if (!await f.exists()) continue;
        final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
        final matches = _slugRecord.allMatches(text).toList();
        if (matches.isEmpty) continue;
        final path = jsonDecode(matches.last.group(1)!) as String;
        if (path.isNotEmpty) return path;
      } catch (_) {}
    }
    return null;
  }

  /// מיקום ברירת מחדל למסד חדש, כשהמסד עוד לא צורף לאוצריא במחשב הזה.
  static String defaultNewDbPath() {
    final env = Platform.environment;
    final docs = Platform.isWindows
        ? p.join(env['USERPROFILE'] ?? '.', 'Documents')
        : p.join(env['HOME'] ?? '.', 'Documents');
    return p.join(docs, 'מסד ספרים לאוצריא', '$dbLibraryId.db');
  }
}
