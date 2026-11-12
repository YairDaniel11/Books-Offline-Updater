import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

import '../db/db_manifest.dart' show dbLibraryId;

/// הקשר בין המסד שלנו לאוצריא: איפה אוצריא קוראת אותו, וצירוף שלו כדי שיוצג בלי פעולה ידנית.
///
/// אוצריא שומרת את רשימת "מסדי הספרים האישיים" שצורפו (key-attached-libraries, מחרוזת JSON)
/// בקופסת ה-Hive שלה, `app_preferences.hive` שבתיקיית הנתונים שלה. כמו בתוכנת העדכון האופליין
/// הרשמית (Otzaria_Offline_update): קריאה נעשית מעותק, וכתיבה רק כשאוצריא סגורה.
class OtzariaLocator {
  OtzariaLocator._();

  static const _boxName = 'app_preferences';
  static const _boxFile = '$_boxName.hive';
  static const _keyAttached = 'key-attached-libraries';
  static const displayName = 'מאגר ספרים לא רשמי';

  /// Hive מחזיק מצב גלובלי (init, קופסאות לפי שם): כל גישה עוברת בתור אחד.
  static Future<void> _queue = Future<void>.value();
  static int _counter = 0;

  static Future<T> _exclusive<T>(Future<T> Function() action) {
    final prev = _queue;
    final done = Completer<void>();
    _queue = done.future;
    return prev.then((_) => action()).whenComplete(done.complete);
  }

  static List<String> _candidateRoots() {
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

  /// תיקיית הנתונים של אוצריא (זו שבה יושבות ההגדרות), או null כשאוצריא לא הופעלה במחשב הזה.
  static String? dataRoot() {
    final roots = _candidateRoots();
    for (final r in roots) {
      if (File(p.join(r, _boxFile)).existsSync()) return r;
    }
    return null;
  }

  /// מיקום למסד במחשב שבו הוא עוד לא צורף: תיקיית "מסדים אישיים" של אוצריא עצמה.
  static String defaultNewDbPath() {
    final root = dataRoot();
    if (root != null) return p.join(root, 'מסדים אישיים', '$dbLibraryId.db');
    final env = Platform.environment;
    final home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
    return p.join(home ?? '.', 'Documents', 'מסד ספרים לאוצריא', '$dbLibraryId.db');
  }

  static List<Map<String, dynamic>> _parseList(Object? raw) {
    if (raw is! String || raw.isEmpty) return [];
    try {
      final j = jsonDecode(raw);
      if (j is List) return [for (final e in j) if (e is Map) Map<String, dynamic>.from(e)];
    } catch (_) {}
    return [];
  }

  /// הנתיב שבו אוצריא קוראת את המסד שלנו, או null כשהוא לא צורף במחשב הזה.
  static Future<String?> findDbPath({String? root}) async {
    final dir = root ?? dataRoot();
    if (dir == null) return null;
    return _exclusive(() => _readPath(dir));
  }

  /// קריאה מעותק של הקופסה (בתוך התור הקיים).
  static Future<String?> _readPath(String dir) async {
    Directory? scratch;
    Box<dynamic>? box;
    try {
      // קריאה מעותק: פתיחת הקופסה במקומה הייתה יוצרת נעילה ומתנגשת עם אוצריא פתוחה.
      scratch = await Directory.systemTemp.createTemp('otzaria-settings-');
      final name = '$_boxName-${_counter++}';
      await File(p.join(dir, _boxFile)).copy(p.join(scratch.path, '$name.hive'));
      Hive.init(scratch.path);
      box = await Hive.openBox<dynamic>(name, path: scratch.path);
      for (final e in _parseList(box.get(_keyAttached))) {
        final path = e['path'];
        if (e['slug'] == dbLibraryId && path is String && path.isNotEmpty) return path;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        await box?.close();
      } catch (_) {}
      try {
        await scratch?.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// מצרף את [dbPath] לאוצריא (או מעדכן את הנתיב אם כבר צורף), כדי שהספרים יוצגו בה מעצמם.
  /// על הקורא לוודא שאוצריא סגורה. מחזיר `true` בהצלחה.
  ///
  /// בטיחות: לא כותבים כשהקובץ לא נקרא במלואו או כשרשימת הספריות במבנה לא צפוי (כדי לא למחוק ספריות של המשתמש);
  /// נשמר גיבוי חד-פעמי לפני הכתיבה הראשונה; אחרי הכתיבה קוראים מחדש ומאמתים, ובכשל משחזרים את הקובץ.
  static Future<bool> attach(String dbPath, {String? root}) async {
    final dir = root ?? dataRoot();
    if (dir == null || !p.isAbsolute(dbPath)) return false;
    return _exclusive(() async {
      if (Hive.isBoxOpen(_boxName)) return false;
      final file = File(p.join(dir, _boxFile));
      Box<dynamic>? box;
      File? snapshot;
      var wrote = false;
      try {
        Hive.init(dir);
        // בלי שחזור אוטומטי: הוא עלול לקצץ קובץ הגדרות פגום של המשתמש, ובמקום זה נכשלים בלי לכתוב.
        box = await Hive.openBox<dynamic>(_boxName, path: dir, crashRecovery: false);
        if (box.path == null || !p.equals(box.path!, file.path)) return false;
        final raw = box.get(_keyAttached);
        final List<dynamic> list;
        if (raw == null || (raw is String && raw.isEmpty)) {
          list = [];
        } else if (raw is String) {
          final j = jsonDecode(raw);
          if (j is! List) return false; // מבנה לא צפוי: לא נוגעים
          list = j;
        } else {
          return false;
        }
        // ערכים שאינם מפה נשארים כמות שהם (לא מוחקים דבר מהרשימה של המשתמש).
        final i = list.indexWhere((e) => e is Map && e['slug'] == dbLibraryId);
        if (i >= 0) {
          final cur = Map<String, dynamic>.from(list[i] as Map);
          if (cur['path'] == dbPath && cur['hidden'] != true) return true;
          list[i] = {...cur, 'path': dbPath, 'hidden': false};
        } else {
          final maxPriority = list.fold<int>(-1, (m, e) {
            final v = e is Map ? (e['priority'] as num?)?.toInt() ?? 0 : 0;
            return v > m ? v : m;
          });
          list.add({
            'slug': dbLibraryId,
            'displayName': displayName,
            'path': dbPath,
            'origin': 'imported',
            'mode': 'link',
            'placement': 'mergeIntoLibrary',
            'priority': maxPriority + 1,
            'addedAt': DateTime.now().toIso8601String(),
          });
        }
        // גיבוי חד-פעמי של הקובץ המקורי, ועותק זמני לשחזור אם הכתיבה נכשלת.
        final backup = File('${file.path}.books-update.bak');
        if (!await backup.exists()) await file.copy(backup.path);
        snapshot = await file.copy('${file.path}.books-update.tmp');
        wrote = true;
        await box.put(_keyAttached, jsonEncode(list));
        await box.close();
        box = null;
        // אימות: קוראים מחדש ומוודאים שהנתיב נקלט.
        if (await _readPath(dir) == dbPath) return true;
        await snapshot.copy(file.path);
        return false;
      } catch (_) {
        if (wrote && snapshot != null) {
          try {
            await box?.close();
          } catch (_) {}
          box = null;
          try {
            await snapshot.copy(file.path);
          } catch (_) {}
        }
        return false;
      } finally {
        try {
          await box?.close();
        } catch (_) {}
        try {
          if (snapshot != null && await snapshot.exists()) await snapshot.delete();
        } catch (_) {}
      }
    });
  }

  /// האם אוצריא פתוחה כרגע (היא נועלת את קובץ המסד ואת ההגדרות שלה).
  static Future<bool> isRunning() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('tasklist', ['/FI', 'IMAGENAME eq otzaria.exe', '/NH']);
        if (r.exitCode != 0) return false;
        return r.stdout.toString().toLowerCase().contains('otzaria.exe');
      }
      for (final name in const ['אוצריא', 'otzaria']) {
        final r = await Process.run('/usr/bin/pgrep', ['-x', name]);
        if (r.exitCode == 0) return true;
      }
    } catch (_) {}
    return false;
  }
}
