import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../controllers/app_controller.dart';
import '../services/app_paths.dart';
import '../services/repo_service.dart' show DownloadCancelled;
import 'db_manifest.dart';
import 'db_service.dart';

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

  /// גרסת המסד במחשב היעד (להכנה להעברה): עם גרסה מוכרת יורד רק קובץ העדכון שלה, בלעדיה המסד המלא.
  int? fromVersion;

  DbActivity? activity;
  String? message;
  bool messageIsError = false;

  bool _cancel = false;

  /// ה-hash של ש"ס וגשל שהורדו במחשב הזה (לזיהוי עדכון).
  String? shasHash;

  /// SHA-256 של המסד שנבדק לאחרונה, לפי (גודל, זמן שינוי), כדי לא לקרוא מחדש ~1GB בכל הפעלה.
  Map<String, dynamic> _shaCache = {};

  Future<String?> _cachedSha(String path) async {
    try {
      final st = await File(path).stat();
      final c = _shaCache;
      if (c['path'] == path && c['size'] == st.size && c['mtime'] == st.modified.millisecondsSinceEpoch) {
        return c['sha'] as String?;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _rememberSha(String path, String sha) async {
    try {
      final st = await File(path).stat();
      _shaCache = {'path': path, 'size': st.size, 'mtime': st.modified.millisecondsSinceEpoch, 'sha': sha};
      await _save();
    } catch (_) {}
  }
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  bool _loaded = false;

  bool get busy => activity != null;

  // ─── אתחול והגדרות ────────────────────────────────────────────────

  /// פר-מחשב: מיקום המסד זכור כאן, ולא נוסע עם התוכנה בדיסק און קי.
  File get _settingsFile => File(p.join(AppPaths.userConfigDir(), 'db_settings.json'));

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
        final sh = j['shasHash'];
        if (sh is String) shasHash = sh;
        final c = j['shaCache'];
        if (c is Map<String, dynamic>) _shaCache = c;
      } catch (_) {}
    }
    await refreshMirror();
    if (targetDb.isNotEmpty) await inspectTarget();
    notifyListeners();
    await checkRemote();
  }

  Future<void> _save() async {
    try {
      await _settingsFile.parent.create(recursive: true);
      await _settingsFile.writeAsString(jsonEncode({
        'mirrorDir': mirrorDir,
        'targetDb': targetDb,
        'shaCache': _shaCache,
        'shasHash': shasHash,
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
    if (remote != null && targetDb.isNotEmpty && local == null && !busy) await inspectTarget();
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
      local = await _service.inspectLocalDb(m, targetDb, knownSha: await _cachedSha(targetDb));
      await _rememberSha(targetDb, local!.sha256);
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
          _msg('זוהתה גרסה ${info.version}. יורד רק קובץ העדכון המתאים.');
        case LocalDbState.unknown:
          fromVersion = null;
          _msg('הגרסה אינה מזוהה, או שהיא ישנה מדי לעדכון חלקי. יורד המסד המלא.', error: true);
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
    final v = fromVersion;
    if (v != null) {
      final d = m.deltaForVersion(v);
      if (d != null) return [d];
    }
    return [m.full];
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
    activity = DbActivity(list.first.isDelta ? 'מוריד קובץ עדכון' : 'מוריד את המסד המלא');
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

  /// ש"ס וגשל מורדים לצד קובץ המסד, בתיקייה "תלמוד בבלי".
  String? get shasDestDir => targetDb.isEmpty ? null : p.dirname(targetDb);

  bool get shasDownloaded {
    final d = shasDestDir;
    return d != null && shasHash != null && Directory(p.join(d, 'תלמוד בבלי')).existsSync();
  }

  Future<void> downloadShas() async {
    final d = shasDestDir;
    final item = _app.shasItem;
    if (d == null || item == null || busy) return;
    if (await _app.downloadShasTo(d)) {
      shasHash = item.hash;
      await _save();
    }
    notifyListeners();
  }

  // ─── עדכון בלחיצה אחת (מחשב מחובר) ───────────────────────────────

  /// מזהה את גרסת המסד שבמחשב הזה, מוריד רק מה שדרוש (קובץ עדכון, או המסד המלא כשאין ברירה),
  /// מתקין במקום ומנקה את קבצי ההורדה. המשתמש לא צריך לדעת מה סוג הקובץ.
  Future<void> updateNow() async {
    final r = remote;
    if (r == null || busy || targetDb.isEmpty) return;
    final m = r.manifest;
    message = null;
    _cancel = false;
    activity = DbActivity('בודק את המסד');
    notifyListeners();
    try {
      DbArtifact artifact = m.full;
      if (await File(targetDb).exists()) {
        final info = await _service.inspectLocalDb(
          m,
          targetDb,
          onProgress: (d, t) => _progress(d, t, 'מזהה את גרסת המסד'),
          isCancelled: () => _cancel,
          knownSha: await _cachedSha(targetDb),
        );
        if (info.state == LocalDbState.current) {
          activity = null;
          local = info;
          _msg('המסד כבר בגרסה העדכנית (${m.version}).');
          return;
        }
        if (info.delta != null) artifact = info.delta!;
      }
      activity!.title = artifact.isDelta ? 'מוריד עדכון' : 'מוריד את המסד המלא';
      notifyListeners();
      await _service.download(r, [artifact], mirrorDir, onProgress: _progress, isCancelled: () => _cancel);
      activity!.title = artifact.isDelta ? 'מעדכן את המסד' : 'מתקין את המסד';
      notifyListeners();
      await _service.install(artifact, mirrorDir, targetDb, onProgress: _progress, isCancelled: () => _cancel);
      await _rememberSha(targetDb, artifact.sha256);
      // הקבצים כבר הוחלו: לא משאירים ~400MB מיותרים בדיסק.
      for (final part in artifact.parts) {
        try {
          await File(DbService.partPath(mirrorDir, part)).delete();
        } catch (_) {}
      }
      _msg('המסד עודכן לגרסה ${m.version}.');
    } on DownloadCancelled {
      _msg('הפעולה נעצרה. המסד הקיים לא שונה.');
    } catch (e) {
      final text = e.toString();
      final cancelled = text.contains('הפעולה בוטלה');
      _msg(cancelled ? 'הפעולה נעצרה. המסד הקיים לא שונה.' : 'העדכון נכשל: $text', error: !cancelled);
    }
    activity = null;
    notifyListeners();
    await refreshMirror();
    await inspectTarget();
  }

  /// מוחק את זיהוי הגרסה של המחשב היעד (להורדת המסד המלא).
  void clearTransferVersion() {
    fromVersion = null;
    notifyListeners();
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
          : InstallPlan(InstallAction.blocked, 'בתיקייה אין את קובץ המסד המלא, ולכן אי אפשר ליצור מסד חדש.');
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
            'קובץ העדכון מגרסה ${info.version} חסר בתיקייה. יוחלף המסד כולו (${formatBytes(m.full.downloadSize)}).',
            artifact: m.full,
          );
        }
        return InstallPlan(
          InstallAction.blocked,
          'המסד בגרסה ${info.version}, אך קובץ העדכון שלו חסר בתיקייה. יש להוריד אותו במחשב מחובר.',
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
                'גרסת המסד אינה מזוהה, ובתיקייה אין את קובץ המסד המלא. יש להוריד אותו במחשב מחובר.',
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
