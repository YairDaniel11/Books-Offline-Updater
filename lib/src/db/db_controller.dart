import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../controllers/app_controller.dart';
import '../services/repo_service.dart' show DownloadCancelled;
import 'db_manifest.dart';
import 'db_service.dart';

/// מה להוריד למראה.
enum DbDownloadMode { full, updatesOnly }

enum InstallAction { none, delta, full, blocked }

/// מה ייעשה בלחיצה על "התקן": לפי המסד שביעד ומה שיש במראה.
class InstallPlan {
  InstallPlan(this.action, this.message, {this.artifact});
  final InstallAction action;
  final String message;
  final DbArtifact? artifact;
  bool get canRun => action == InstallAction.delta || action == InstallAction.full;
}

class DbActivity {
  DbActivity(this.title);
  String title;
  String detail = '';
  double? progress;
  bool cancelled = false;
}

const dbMirrorDirName = 'OtzariaDbMirror';

/// מצב ופעולות של לשונית המסד: הורדה למראה (מחשב מחובר) והתקנה/עדכון ממנה (מחשב חסום).
class DbController extends ChangeNotifier {
  DbController(this._app);

  final AppController _app;
  final DbService _service = DbService();

  // ─── מצב ──────────────────────────────────────────────────────────

  String mirrorDir = '';
  String targetDb = '';

  DbRelease? remote;
  String? remoteError;
  bool checking = false;

  DbRelease? mirror;
  String? mirrorError;

  LocalDbInfo? local;
  bool inspecting = false;

  DbDownloadMode mode = DbDownloadMode.updatesOnly;

  /// גרסת המקור של קובץ העדכון להורדה; `null` = כל קובצי העדכון.
  int? fromVersion;

  DbActivity? activity;
  String? message;
  bool messageIsError = false;

  bool _cancel = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  bool _loaded = false;

  bool get busy => activity != null;

  // ─── אתחול והגדרות ────────────────────────────────────────────────

  File get _settingsFile => File(p.join(_app.dataDir, 'db_settings.json'));

  Future<void> init() async {
    if (!_loaded) {
      _loaded = true;
      mirrorDir = p.join(_app.dataDir, dbMirrorDirName);
      try {
        final j = jsonDecode(await _settingsFile.readAsString()) as Map<String, dynamic>;
        final m = j['mirrorDir'];
        if (m is String && m.isNotEmpty) mirrorDir = m;
        final t = j['targetDb'];
        if (t is String) targetDb = t;
        mode = j['mode'] == 'full' ? DbDownloadMode.full : DbDownloadMode.updatesOnly;
      } catch (_) {}
    }
    await refreshMirror();
    if (targetDb.isNotEmpty) await inspectTarget();
    notifyListeners();
    await checkRemote();
  }

  Future<void> _save() async {
    try {
      await _settingsFile.writeAsString(jsonEncode({
        'mirrorDir': mirrorDir,
        'targetDb': targetDb,
        'mode': mode == DbDownloadMode.full ? 'full' : 'updates',
      }));
    } catch (_) {}
  }

  void _msg(String text, {bool error = false}) {
    message = text;
    messageIsError = error;
    notifyListeners();
  }

  void clearMessage() {
    message = null;
    notifyListeners();
  }

  void setMode(DbDownloadMode m) {
    mode = m;
    _save();
    notifyListeners();
  }

  void setFromVersion(int? v) {
    fromVersion = v;
    notifyListeners();
  }

  void cancel() {
    if (activity == null) return;
    _cancel = true;
    activity!.cancelled = true;
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

  // ─── רשת ──────────────────────────────────────────────────────────

  Future<void> checkRemote() async {
    if (checking) return;
    checking = true;
    remoteError = null;
    notifyListeners();
    try {
      remote = await _service.fetchRemote();
      final m = remote!.manifest;
      // ברירת מחדל לבחירת גרסה: אם נבחרה גרסה שאינה קיימת עוד, חוזרים ל"כולן".
      if (fromVersion != null && m.deltaForVersion(fromVersion!) == null) fromVersion = null;
    } catch (e) {
      remote = null;
      remoteError = e is DbException ? e.message : 'אין חיבור לרשת';
    }
    checking = false;
    notifyListeners();
  }

  // ─── מראה ─────────────────────────────────────────────────────────

  Future<void> refreshMirror() async {
    mirrorError = null;
    try {
      mirror = await _service.readMirror(mirrorDir);
    } catch (e) {
      mirror = null;
      mirrorError = e.toString();
    }
    notifyListeners();
  }

  Future<void> setMirrorDir(String dir) async {
    if (busy) return;
    mirrorDir = dir;
    await _save();
    await refreshMirror();
  }

  Future<void> setTarget(String path) async {
    if (busy) return;
    targetDb = path;
    local = null;
    await _save();
    await inspectTarget();
  }

  /// מזהה את גרסת המסד שביעד (חישוב SHA-256 על הקובץ).
  Future<void> inspectTarget() async {
    local = null;
    if (targetDb.isEmpty || !await File(targetDb).exists()) {
      notifyListeners();
      return;
    }
    final m = (mirror ?? remote)?.manifest;
    if (m == null) {
      notifyListeners();
      return;
    }
    inspecting = true;
    notifyListeners();
    try {
      local = await _service.inspectLocalDb(m, targetDb);
    } catch (e) {
      _msg('לא ניתן לקרוא את הקובץ: $e', error: true);
    }
    inspecting = false;
    notifyListeners();
  }

  /// זיהוי גרסה לפי קובץ מסד (לבחירת קובץ העדכון להורדה), בלי לשנות את יעד ההתקנה.
  Future<void> detectVersionFrom(String path) async {
    final m = remote?.manifest;
    if (m == null || busy) return;
    inspecting = true;
    notifyListeners();
    try {
      final info = await _service.inspectLocalDb(m, path);
      switch (info.state) {
        case LocalDbState.current:
          fromVersion = null;
          _msg('המסד שבחרתם כבר בגרסה העדכנית (${m.version}).');
        case LocalDbState.hasDelta:
          fromVersion = info.version;
          mode = DbDownloadMode.updatesOnly;
          _msg('זוהתה גרסה ${info.version}. נבחר קובץ העדכון המתאים.');
        case LocalDbState.unknown:
          mode = DbDownloadMode.full;
          _msg('הגרסה אינה מזוהה, או שהיא ישנה מדי לקובץ עדכון. מומלץ להוריד את המסד המלא.', error: true);
      }
    } catch (e) {
      _msg('לא ניתן לקרוא את הקובץ: $e', error: true);
    }
    inspecting = false;
    notifyListeners();
  }

  // ─── הורדה ────────────────────────────────────────────────────────

  List<DbArtifact> get selectedDownload {
    final m = remote?.manifest;
    if (m == null) return const [];
    if (mode == DbDownloadMode.full) return [m.full];
    final v = fromVersion;
    if (v != null) {
      final d = m.deltaForVersion(v);
      return d == null ? const [] : [d];
    }
    return m.deltas;
  }

  /// כמה בתים עוד חסרים במראה עבור הבחירה הנוכחית.
  int get downloadBytes {
    var total = 0;
    for (final a in selectedDownload) {
      for (final part in a.parts) {
        final f = File(DbService.partPath(mirrorDir, part));
        if (!(f.existsSync() && f.lengthSync() == part.size)) total += part.size;
      }
    }
    return total;
  }

  Future<void> download() async {
    final r = remote;
    if (r == null || busy) return;
    final list = selectedDownload;
    if (list.isEmpty) {
      _msg('אין קבצים להורדה לבחירה הזו.', error: true);
      return;
    }
    message = null;
    _cancel = false;
    activity = DbActivity(mode == DbDownloadMode.full ? 'מוריד את המסד המלא' : 'מוריד קבצי עדכון');
    notifyListeners();
    try {
      await _service.download(r, list, mirrorDir, onProgress: _progress, isCancelled: () => _cancel);
      _msg('ההורדה הסתיימה (גרסה ${r.manifest.version}). הקבצים בתיקייה: $mirrorDir');
    } on DownloadCancelled {
      _msg('ההורדה נעצרה. ניתן להמשיך אותה בהמשך מאותה נקודה.');
    } catch (e) {
      _msg('ההורדה נכשלה: $e', error: true);
    }
    activity = null;
    await refreshMirror();
    if (targetDb.isNotEmpty) await inspectTarget();
  }

  // ─── התקנה ────────────────────────────────────────────────────────

  InstallPlan? get plan {
    final m = mirror?.manifest;
    if (m == null) return null;
    if (targetDb.isEmpty) return null;
    final exists = File(targetDb).existsSync();
    final fullOk = DbService.isComplete(m.full, mirrorDir);
    if (!exists) {
      return fullOk
          ? InstallPlan(InstallAction.full, 'הקובץ אינו קיים: יותקן המסד המלא (גרסה ${m.version}).', artifact: m.full)
          : InstallPlan(InstallAction.blocked, 'אין במראה את המסד המלא, ולכן אי אפשר ליצור מסד חדש.');
    }
    final info = local;
    if (info == null) return null; // עדיין מזהים
    switch (info.state) {
      case LocalDbState.current:
        return InstallPlan(InstallAction.none, 'המסד כבר בגרסה העדכנית (${m.version}).');
      case LocalDbState.hasDelta:
        final d = info.delta!;
        if (DbService.isComplete(d, mirrorDir)) {
          return InstallPlan(
            InstallAction.delta,
            'גרסה ${info.version} ← ${m.version}: יוחל קובץ עדכון (${formatBytes(d.downloadSize)}).',
            artifact: d,
          );
        }
        if (fullOk) {
          return InstallPlan(
            InstallAction.full,
            'קובץ העדכון מגרסה ${info.version} חסר במראה. יוחלף המסד כולו (${formatBytes(m.full.downloadSize)}).',
            artifact: m.full,
          );
        }
        return InstallPlan(
          InstallAction.blocked,
          'המסד בגרסה ${info.version}, אך קובץ העדכון שלו חסר במראה. יש להוריד אותו במחשב מחובר.',
        );
      case LocalDbState.unknown:
        return fullOk
            ? InstallPlan(
                InstallAction.full,
                'גרסת המסד אינה מזוהה: יוחלף במסד המלא (גרסה ${m.version}).',
                artifact: m.full,
              )
            : InstallPlan(
                InstallAction.blocked,
                'גרסת המסד אינה מזוהה, ובמראה אין את המסד המלא. יש להוריד אותו במחשב מחובר.',
              );
    }
  }

  Future<void> install() async {
    final pl = plan;
    if (pl == null || !pl.canRun || busy) return;
    message = null;
    _cancel = false;
    activity = DbActivity(pl.action == InstallAction.delta ? 'מעדכן את המסד' : 'מתקין את המסד');
    notifyListeners();
    try {
      await _service.install(pl.artifact!, mirrorDir, targetDb, onProgress: _progress, isCancelled: () => _cancel);
      _msg('המסד עודכן לגרסה ${mirror!.manifest.version}: $targetDb');
    } on DownloadCancelled {
      _msg('הפעולה נעצרה. המסד הקיים לא שונה.');
    } catch (e) {
      final text = e.toString();
      _msg(text.contains('הפעולה בוטלה') ? 'הפעולה נעצרה. המסד הקיים לא שונה.' : 'העדכון נכשל: $text', error: !text.contains('בוטלה'));
    }
    activity = null;
    notifyListeners();
    await inspectTarget();
  }

  static String formatBytes(int b) => AppController.formatBytes(b);

  @override
  void dispose() {
    _service.close();
    super.dispose();
  }
}
