import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:path/path.dart' as p;

import '../db/db_controller.dart';
import '../services/app_paths.dart';
import '../services/disk_space.dart';
import '../services/net_errors.dart';
import '../services/otzaria_locator.dart';
import '../services/repo_service.dart' show DownloadCancelled;
import 'vectors_manifest.dart';
import 'vectors_service.dart';

const vectorsCredit = 'וקטורי החיפוש מבוססים על המודל של פרויקט אוצריא (otzaria.org)';

/// הכנה (הורדה) והתקנה של וקטורי החיפוש-לפי-משמעות של ספרי המאגר.
class VectorsController extends ChangeNotifier {
  VectorsController(this._db);

  final DbController _db;
  final VectorsService _service = VectorsService();

  VectorsRelease? remote;
  String? remoteError;
  VectorsRelease? mirror;
  String? vectorsDir;
  bool checking = false;

  DbActivity? activity;
  String? message;
  bool messageIsError = false;
  bool _cancel = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// מקטעים שהתוכנה הזו כבר רשמה בסט (נשמר: אחרי כיווץ של אוצריא המקטע אינו מזוהה בסט).
  List<String> installedSegments = [];

  bool get busy => activity != null;

  File get _file => File(p.join(AppPaths.userConfigDir(), 'vectors_settings.json'));

  Future<void> init() async {
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      final v = j['vectorsDir'];
      if (v is String && v.isNotEmpty) vectorsDir = v;
      final s = j['installedSegments'];
      if (s is List) installedSegments = [for (final e in s) e.toString()];
    } catch (_) {}
    vectorsDir ??= await OtzariaLocator.findVectorsDir();
    refreshMirror();
    notifyListeners();
    await checkRemote();
  }

  Future<void> _save() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode({'vectorsDir': vectorsDir, 'installedSegments': installedSegments}));
    } catch (_) {}
  }

  Future<void> setVectorsDir(String dir) async {
    vectorsDir = dir;
    await _save();
    notifyListeners();
  }

  void refreshMirror() {
    try {
      mirror = VectorsService.readMirror(_db.mirrorDir);
    } catch (_) {
      mirror = null;
    }
    notifyListeners();
  }

  Future<void> checkRemote() async {
    if (checking) return;
    checking = true;
    remoteError = null;
    notifyListeners();
    try {
      remote = await _service.fetchRemote();
    } catch (e) {
      remote = null;
      remoteError = e is VectorsException ? e.message : friendlyNetError(e);
    }
    checking = false;
    notifyListeners();
  }

  void clearMessage() {
    message = null;
    notifyListeners();
  }

  void cancel() {
    if (activity == null) return;
    _cancel = true;
    activity!.cancelled = true;
    notifyListeners();
  }

  void _msg(String text, {bool error = false}) {
    message = text;
    messageIsError = error;
    notifyListeners();
  }

  void _progress(int done, int? total, String detail) {
    final a = activity;
    if (a == null) return;
    a.detail = detail;
    a.progress = total == null || total == 0 ? null : (done / total).clamp(0.0, 1.0);
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds > 120) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  /// הוקטורים ברשת תואמים למסד שמוכן לאותה חבילה (אותה גרסה ואותו sha256)?
  String? remoteMismatch() {
    final v = remote?.manifest;
    final d = _db.remote?.manifest;
    if (v == null || d == null) return null;
    if (v.dbVersion != d.version || v.dbSha256 != d.full.sha256) {
      return 'וקטורי החיפוש בנויים למסד גרסה ${v.dbVersion}, ואילו המסד העדכני הוא גרסה ${d.version}. '
          'כדי שהחיפוש לא ייתן תוצאות שגויות, לא מכינים חבילה שבה הגרסאות שונות. נסו שוב מאוחר יותר.';
    }
    return null;
  }

  bool get preparedComplete => mirror != null && VectorsService.isComplete(mirror!.manifest, _db.mirrorDir);

  // ─── הכנה (מחובר) ─────────────────────────────────────────────────

  Future<void> prepare() async {
    final r = remote;
    if (r == null || busy) return;
    if (_db.remote == null) {
      _msg('צריך לבדוק קודם את גרסת המסד (חיבור לרשת).', error: true);
      return;
    }
    final mismatch = remoteMismatch();
    if (mismatch != null) {
      _msg(mismatch, error: true);
      return;
    }
    final free = await freeDiskSpace(p.join(_db.mirrorDir, 'x'));
    final need = r.manifest.downloadSize + 64 * 1024 * 1024;
    if (free != null && free < need) {
      _msg('אין מספיק מקום פנוי. דרושים כ-${DbController.formatBytes(need)}, ופנויים ${DbController.formatBytes(free)}.',
          error: true);
      return;
    }
    message = null;
    _cancel = false;
    activity = DbActivity('מוריד את וקטורי החיפוש');
    notifyListeners();
    try {
      await _service.download(
        r,
        _db.mirrorDir,
        onProgress: (d, t, name) => _progress(
            d, t, t == null ? name : '${DbController.formatBytes(d)} מתוך ${DbController.formatBytes(t)}'),
        isCancelled: () => _cancel,
      );
      _msg('וקטורי החיפוש הורדו (למסד גרסה ${r.manifest.dbVersion}). הקבצים בתיקייה: ${_db.mirrorDir}');
    } on DownloadCancelled {
      _msg('ההורדה נעצרה. בהורדה חוזרת היא תתחיל מההתחלה (השרת לא תומך בהמשך).');
    } catch (e) {
      _msg('ההורדה נכשלה: ${e is VectorsException ? e.message : friendlyNetError(e)}', error: true);
    }
    activity = null;
    refreshMirror();
  }

  // ─── התקנה (אופליין) ──────────────────────────────────────────────

  Future<void> install() async {
    if (busy) return;
    final r = mirror;
    if (r == null || !preparedComplete) {
      _msg('בתיקיית החבילה אין וקטורים שלמים. הכינו אותם במחשב מחובר.', error: true);
      return;
    }
    final m = r.manifest;
    final vdir = vectorsDir;
    if (vdir == null || !File(p.join(vdir, 'CURRENT')).existsSync()) {
      _msg('לא נמצאה תיקיית הוקטורים של אוצריא. הפעילו את אוצריא פעם אחת עם חיפוש-לפי-משמעות, או בחרו את התיקייה ידנית.',
          error: true);
      return;
    }
    if (await OtzariaLocator.isRunning()) {
      _msg('אוצריא פתוחה. סגרו אותה ולחצו שוב.', error: true);
      return;
    }
    if (installedSegments.isNotEmpty && !installedSegments.contains(m.segment.id)) {
      _msg('כבר הותקנו כאן וקטורים של המאגר בגרסה אחרת. עדכון וקטורים לגרסת מסד חדשה עדיין לא נבדק (ייתכן שאוצריא כבר כיווצה את הישנים), '
          'ולכן התוכנה לא מבצעת אותו.', error: true);
      return;
    }
    message = null;
    _cancel = false;
    activity = DbActivity('מתקין את וקטורי החיפוש');
    notifyListeners();
    try {
      final dbPath = _db.otzariaDbPath ?? _db.targetDb;
      final sha = await _db.installedDbSha(
        dbPath,
        onProgress: (d, t) => _progress(d, t, 'בודק את גרסת המסד'),
        isCancelled: () => _cancel,
      );
      if (sha != m.dbSha256) {
        _msg('הוקטורים בנויים למסד גרסה ${m.dbVersion}, והמסד שמותקן כאן שונה ממנו. קודם מעדכנים את המסד, ורק אחר כך מתקינים וקטורים.',
            error: true);
        activity = null;
        notifyListeners();
        return;
      }
      final free = await freeDiskSpace(p.join(vdir, 'segments', 'x'));
      final need = m.segment.size + 256 * 1024 * 1024;
      if (free != null && free < need) {
        _msg('אין מספיק מקום פנוי בכונן של אוצריא. דרושים כ-${DbController.formatBytes(need)}, ופנויים ${DbController.formatBytes(free)}.',
            error: true);
        activity = null;
        notifyListeners();
        return;
      }
      final gen = await VectorsService.install(m, _db.mirrorDir, vdir, onProgress: _progress, isCancelled: () => _cancel);
      installedSegments = [...installedSegments, m.segment.id];
      await _save();
      _msg('הוקטורים הותקנו (דור $gen, ${m.segment.slots} וקטורים). אוצריא תשתמש בהם בהפעלה הבאה.');
    } on DownloadCancelled {
      _msg('ההתקנה נעצרה. סט הוקטורים של אוצריא לא שונה.');
    } catch (e) {
      _msg('ההתקנה נכשלה: $e', error: true);
    }
    activity = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }
}
