import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'repo_service.dart' show isSafePath;

/// רשימה (בתיקיית היעד עצמה) של הקבצים שהתוכנה הזאת העתיקה אליה.
/// ניקוי ישנים ביעד מוחק רק קבצים שמופיעים כאן, ולא כל קובץ שהנתיב שלו מופיע ברשימת ההסרות.
class CopyLedger {
  CopyLedger._(this.destDir, this._paths);

  static const fileName = '.books-offline-copied.json';

  final String destDir;
  final Set<String> _paths;

  File get _file => File(p.join(destDir, fileName));

  /// טוען את הרשימה של [destDir]; חסרה או פגומה → ריקה (ואז לא נמחק דבר).
  static Future<CopyLedger> load(String destDir) async {
    final paths = <String>{};
    try {
      final f = File(p.join(destDir, fileName));
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        final list = j is Map ? j['files'] : null;
        if (list is List) {
          for (final e in list) {
            if (e is String && isSafePath(e)) paths.add(e);
          }
        }
      }
    } catch (_) {}
    return CopyLedger._(destDir, paths);
  }

  int get length => _paths.length;
  bool owns(String path) => _paths.contains(path);
  void add(String path) => _paths.add(path);
  void remove(String path) => _paths.remove(path);

  /// שומר באופן אטומי (כתיבה לקובץ זמני והחלפה).
  Future<void> save() async {
    try {
      await Directory(destDir).create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      final sorted = _paths.toList()..sort();
      await tmp.writeAsString(jsonEncode({'v': 1, 'files': sorted}));
      await tmp.rename(_file.path);
    } catch (_) {}
  }
}
