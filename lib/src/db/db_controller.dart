import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../controllers/app_controller.dart';
import '../services/app_paths.dart';
import '../services/net_errors.dart';
import '../services/disk_space.dart';
import '../services/otzaria_locator.dart';
import '../services/repo_service.dart' show DownloadCancelled;
import 'db_manifest.dart';
import 'db_service.dart';

enum InstallAction { none, delta, full, blocked }

/// מה ייעשה בלחיצה על "התקן": לפי המסד שביעד ומה שיש במראה.
class InstallPlan {
  InstallPlan(this.action, this.message, {this.artifact, this.artifacts});
  final InstallAction action;
  final String message;
  final DbArtifact? artifact;

  /// קבצים להחלה לפי הסדר (שרשרת צעדי עדכון); כשחסר, הפעולה היא [artifact] בלבד.
  final List<DbArtifact>? artifacts;
  List<DbArtifact> get all => artifacts ?? [artifact!];
  bool get canRun => action == InstallAction.delta || action == InstallAction.full;
}

class _ChainStopped implements Exception {
  _ChainStopped(this.reason);
  final String reason;
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

  /// צעדי עדכון בין גרסאות עוקבות (ברילס נפרד), ברשת ובתיקיית המראה. ללא: אין שרשרת.
  StepsRelease? remoteSteps;
  StepsRelease? mirrorSteps;
  String? remoteError;
  bool checking = false;

  DbRelease? mirror;
  String? mirrorError;

  /// המסד שביעד מול הגרסה העדכנית ברשת (כשיש חיבור; אחרת מול המראה). משמש לזיהוי "יש עדכון".
  LocalDbInfo? local;

  /// המסד שביעד מול תיקיית המראה בלבד: קובע מה אפשר להתקין ממנה (תיקייה על דיסק און קי יכולה להיות ישנה מהרשת).
  LocalDbInfo? localMirror;
  bool inspecting = false;

  /// המקום שבו אוצריא שומרת את המסד במחשב הזה, אם נמצא.
  String? otzariaDbPath;

  /// שרשרת צעדים משתלמת רק כשהסכום שלה קטן מהורדת המסד המלא.
  static bool _worthIt(List<DbArtifact> chain, DbManifest m) =>
      chain.fold<int>(0, (a, c) => a + c.downloadSize) < m.full.downloadSize;

  /// יש עדכון למסד שבמחשב הזה (לפי הרשת).
  bool get updateAvailable =>
      remote != null && local != null && local!.state != LocalDbState.current && targetDb.isNotEmpty;

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
      otzariaDbPath = await OtzariaLocator.findDbPath();
      // מחשב שעוד לא נבחר בו מיקום: ישר למקום שאוצריא קוראת ממנו, ואם המסד עוד לא צורף אליה,
      // למיקום קבוע במסמכים (ואז מסבירים איך לצרף אותו).
      if (targetDb.isEmpty) {
        targetDb = otzariaDbPath ?? OtzariaLocator.defaultNewDbPath();
        await _save();
      }
    }
    if (targetDb.isNotEmpty) await DbService.recoverInterrupted(targetDb);
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

  /// ההודעה הנוכחית מסיימת הכנה/העתקה למחשב השני (כדי להציג "עכשיו מעבירים את התוכנה...").
  bool messageIsTransferDone = false;

  void _msg(String text, {bool error = false, bool transferDone = false}) {
    message = text;
    messageIsError = error;
    messageIsTransferDone = transferDone && !error;
    notifyListeners();
  }

  void clearMessage() {
    message = null;
    notifyListeners();
  }

  void setFromVersion(int? v) {
    fromVersion = v;
    detectedCurrentPath = null;
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

  void _notifyThrottled() {
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
      remoteSteps = await _service.fetchSteps();
      // ברירת מחדל לבחירת גרסה: אם נבחרה גרסה שאינה קיימת עוד, חוזרים ל"כולן".
      if (fromVersion != null && !versionOptions.any((o) => o.version == fromVersion)) fromVersion = null;
    } catch (e) {
      remote = null;
      remoteError = e is DbException ? e.message : friendlyNetError(e);
    }
    checking = false;
    notifyListeners();
    if (remote != null && targetDb.isNotEmpty && !busy) await inspectTarget();
  }

  // ─── מראה ─────────────────────────────────────────────────────────

  Future<void> refreshMirror() async {
    mirrorError = null;
    try {
      mirror = await _service.readMirror(mirrorDir);
      mirrorSteps = await _service.readMirrorSteps(mirrorDir);
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

  /// אישור מהמשתמש (דיאלוג). מוגדר על ידי המסך; כשחסר, ממשיכים בלי לשאול (בדיקות).
  Future<bool> Function(String message)? confirm;

  static const unknownDbConfirmText = 'המסד במחשב הזה לא מזוהה ויוחלף במסד המלא. להמשיך?';

  /// בודק שיש מקום פנוי בכונן של המסד ליעד. נכשל בבדיקה עצמה: ממשיכים (מחזיר true).
  Future<bool> _hasRoomFor(int needed) async {
    final free = await freeDiskSpace(targetDb);
    if (free == null || free >= needed) return true;
    _msg('אין מספיק מקום פנוי בכונן של המסד. דרושים כ-${formatBytes(needed)}, ופנויים ${formatBytes(free)}. '
        'פנו מקום ונסו שוב.', error: true);
    return false;
  }

  /// המסד היעד חייב להיראות כמסד SQLite (או להיות חסר/ריק), כדי לא לדרוס קובץ אחר.
  Future<bool> _targetIsSqlite() async {
    try {
      if (await DbService.looksLikeSqlite(targetDb)) return true;
    } catch (_) {
      return true; // לא הצלחנו לקרוא: הזיהוי וההחלפה ייכשלו בעצמם אם יש בעיה
    }
    _msg('הקובץ שנבחר אינו מסד ספרים (אינו קובץ SQLite), ולכן לא יוחלף. בחרו קובץ אחר או תיקייה חדשה.', error: true);
    return false;
  }

  Future<void> setTarget(String path) async {
    if (busy) return;
    try {
      if (!await DbService.looksLikeSqlite(path)) {
        _msg('הקובץ שנבחר אינו מסד ספרים (אינו קובץ SQLite), ולכן לא נבחר. בחרו את קובץ המסד של אוצריא או תיקייה חדשה.',
            error: true);
        return;
      }
    } catch (_) {}
    targetDb = path;
    await DbService.recoverInterrupted(path);
    local = null;
    localMirror = null;
    await _save();
    await inspectTarget();
  }

  Future<void> useOtzariaLocation() async {
    final o = otzariaDbPath;
    if (o != null) await setTarget(o);
  }

  /// אוצריא נועלת את המסד ואת ההגדרות שלה: לא מתחילים כשהיא פתוחה.
  Future<bool> _blockedByOtzaria() async {
    if (!await OtzariaLocator.isRunning()) return false;
    _msg('אוצריא פתוחה. סגרו את אוצריא ולחצו שוב.', error: true);
    return true;
  }

  /// מצרף את המסד לאוצריא אם עוד לא צורף בנתיב הזה, כדי שהספרים יופיעו בה מעצמם.
  /// מחזיר תוספת להודעת הסיום.
  Future<String> _ensureAttached() async {
    if (otzariaDbPath == targetDb) return '';
    if (await OtzariaLocator.isRunning()) {
      return '\nאוצריא נפתחה, ולכן המסד לא צורף אליה. סגרו אותה ולחצו שוב.';
    }
    if (await OtzariaLocator.attach(targetDb)) {
      otzariaDbPath = targetDb;
      return ' הספרים יופיעו באוצריא בפתיחה הבאה.';
    }
    if (OtzariaLocator.dataRoot() == null) {
      return '\nאוצריא לא נמצאה במחשב הזה. אחרי שתותקן ותיפתח פעם אחת, לחצו שוב על ההעתקה.';
    }
    return '\nלא הצלחתי לצרף את המסד לאוצריא. צרפו אותו ידנית באוצריא: הגדרות > ספרייה > מסדי ספרים אישיים > ייבא קובץ מסד, '
        'ובחרו את הקובץ: $targetDb';
  }

  /// הודעת כשל מובנת: קובץ נעול כמעט תמיד אומר שאוצריא פתוחה.
  static String _failText(Object e) {
    final t = e.toString();
    final locked = t.contains('errno = 32') ||
        t.contains('errno = 5') ||
        t.contains('being used') ||
        t.contains('Access is denied') ||
        t.contains('בשימוש') ||
        t.contains('הגישה נדחתה');
    return locked ? 'אוצריא פתוחה כנראה. סגרו את אוצריא ונסו שוב.\n($t)' : 'העדכון נכשל: $t';
  }

  /// התקדמות חישוב ה-SHA-256 של המסד (0..1) בזמן זיהוי הגרסה; null כשלא מחשבים.
  double? inspectProgress;

  Future<void>? _inspectRun;
  bool _inspectAgain = false;

  /// (נתיב, גודל, זמן שינוי) של הקובץ שעבורו `local`/`localMirror` תקפים כרגע.
  String? _inspectedKey;

  /// מזהה את גרסת המסד שביעד (חישוב SHA-256 על הקובץ). קריאה בזמן שזיהוי כבר רץ משתמשת בו
  /// (ורצה שוב רק על ה-sha השמור, אם בינתיים הגיע מניפסט חדש).
  Future<void> inspectTarget() {
    final run = _inspectRun;
    if (run != null) {
      _inspectAgain = true;
      return run;
    }
    final f = () async {
      do {
        _inspectAgain = false;
        await _inspectOnce();
      } while (_inspectAgain);
    }();
    return _inspectRun = f.whenComplete(() => _inspectRun = null);
  }

  Future<void> _inspectOnce() async {
    FileStat? st;
    try {
      if (targetDb.isNotEmpty) {
        st = await File(targetDb).stat();
        if (st.type == FileSystemEntityType.notFound) st = null;
      }
    } catch (_) {}
    final key = st == null ? null : '$targetDb|${st.size}|${st.modified.millisecondsSinceEpoch}';
    // אותו קובץ כמו בזיהוי הקודם: ממשיכים להציג את התוצאה הקודמת בזמן הערכה מחדש מול מניפסט חדש.
    final keep = key != null && key == _inspectedKey && local != null;
    if (!keep) {
      local = null;
      localMirror = null;
      _inspectedKey = null;
    }
    if (st == null) {
      notifyListeners();
      return;
    }
    final mm = mirror?.manifest;
    final rm = remote?.manifest;
    if (mm == null && rm == null) {
      notifyListeners();
      return;
    }
    if (!keep) {
      inspecting = true;
      inspectProgress = null;
      notifyListeners();
    }
    try {
      var sha = await _cachedSha(targetDb);
      if (sha == null) {
        inspecting = true;
        inspectProgress = 0;
        notifyListeners();
        sha = await DbService.sha256OfFile(targetDb, onProgress: (done, total) {
          inspectProgress = total == 0 ? 1.0 : done / total;
          _notifyThrottled();
        });
        // נשמר מיד, כדי שהפעלה הבאה (או קריאה נוספת) לא תחשב שוב.
        await _rememberSha(targetDb, sha);
      }
      Future<LocalDbInfo> inspect(DbManifest m, StepsManifest? steps) => _service.inspectLocalDb(
            m,
            targetDb,
            knownSha: sha,
            steps: steps,
            chainIsWorthIt: (c) => _worthIt(c, m),
          );

      final newMirror = mm != null ? await inspect(mm, mirrorSteps?.manifest) : null;
      // "יש עדכון" נקבע לפי הרשת כשיש חיבור, ולא לפי מה שנמצא בתיקיית המראה.
      final newLocal = rm != null ? await inspect(rm, remoteSteps?.manifest) : newMirror;
      localMirror = newMirror;
      local = newLocal;
      _inspectedKey = key;
    } catch (e) {
      _msg('לא ניתן לקרוא את הקובץ: $e', error: true);
    }
    inspecting = false;
    inspectProgress = null;
    notifyListeners();
  }

  /// הקובץ שנבחר בהכנה למחשב אחר וזוהה כגרסה העדכנית; `null` כשלא נבחר או שאינו עדכני.
  String? detectedCurrentPath;

  /// איזה קובץ מסד עדכני אפשר להעתיק ישירות (בלי הורדה), או `null`: אז ממשיכים בהורדה הרגילה.
  /// [fromLocal]: המסד של המחשב הזה (אם הוא העדכני), [fromDetected]: העותק שנבחר וזוהה כעדכני.
  String? latestDbToCopy({required bool fromLocal, required bool fromDetected}) {
    if (fromLocal && local?.state == LocalDbState.current && targetDb.isNotEmpty && (remote ?? mirror) != null) {
      try {
        if (File(targetDb).existsSync()) return targetDb;
      } catch (_) {}
    }
    final d = detectedCurrentPath;
    if (fromDetected && d != null && remote != null) {
      try {
        if (File(d).existsSync()) return d;
      } catch (_) {}
    }
    return null;
  }

  /// מעתיק את קובץ המסד העדכני [src] לתיקייה שנבחרה (למשל דיסק און קי), יחד עם הקבצים החתומים שההתקנה במחשב השני צריכה.
  Future<void> copyLatestDbTo(String folder, String src) async {
    final r = remote ?? mirror;
    if (r == null || busy) return;
    final dest = p.basename(folder) == dbMirrorDirName ? folder : p.join(folder, dbMirrorDirName);
    message = null;
    _cancel = false;
    activity = DbActivity('מעתיק את המסד לדיסק און קי');
    notifyListeners();
    try {
      final free = await freeDiskSpace(p.join(dest, 'x'));
      var needed = r.manifest.full.size + 64 * 1024 * 1024;
      final existing = File(p.join(dest, DbService.rawDbFileName(r.manifest.full)));
      if (existing.existsSync() && existing.lengthSync() == r.manifest.full.size) needed = 64 * 1024 * 1024;
      if (free != null && free < needed) {
        _msg('אין מספיק מקום פנוי בדיסק און קי. דרושים כ-${formatBytes(needed)}, ופנויים ${formatBytes(free)}. '
            'פנו מקום או בחרו כונן אחר.', error: true);
      } else {
        await _service.copyRawDb(r, src, dest, onProgress: _progress, isCancelled: () => _cancel);
        _msg('הושלם. המסד (גרסה ${r.manifest.version}) הועתק אל: $dest', transferDone: true);
      }
    } on DownloadCancelled {
      _msg('ההעתקה נעצרה. לא נשאר קובץ חלקי.');
    } catch (e) {
      _msg(DbService.friendlyCopyError(e), error: true);
    }
    activity = null;
    notifyListeners();
  }

  /// זיהוי גרסה לפי קובץ מסד (לבחירת קובץ העדכון להורדה), בלי לשנות את יעד ההתקנה.
  Future<void> detectVersionFrom(String path) async {
    final m = remote?.manifest;
    if (m == null || busy) return;
    inspecting = true;
    detectedCurrentPath = null;
    notifyListeners();
    try {
      final info = await _service.inspectLocalDb(
        m,
        path,
        steps: remoteSteps?.manifest,
        chainIsWorthIt: (c) => _worthIt(c, m),
      );
      switch (info.state) {
        case LocalDbState.current:
          fromVersion = null;
          detectedCurrentPath = path;
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
      final c = remoteSteps?.manifest.chainFromVersion(v, m.full.sha256);
      if (c != null && _worthIt(c, m)) return c;
    }
    return [m.full];
  }

  /// הגרסאות שאפשר להכין להן עדכון (קובץ עדכון ישיר או שרשרת משתלמת), מהחדשה לישנה, עם גודל ההורדה.
  List<({int version, int bytes})> get versionOptions {
    final m = remote?.manifest;
    if (m == null) return const [];
    final out = <int, int>{};
    for (final d in m.deltas) {
      out[d.fromVersion!] = d.downloadSize;
    }
    final st = remoteSteps?.manifest;
    if (st != null) {
      for (final s in st.steps) {
        final v = s.fromVersion!;
        if (out.containsKey(v)) continue;
        final c = st.chainFromVersion(v, m.full.sha256);
        if (c != null && _worthIt(c, m)) out[v] = c.fold<int>(0, (a, b) => a + b.downloadSize);
      }
    }
    final keys = out.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final k in keys) (version: k, bytes: out[k]!)];
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
      await _service.download(r, list, mirrorDir,
          onProgress: _progress, isCancelled: () => _cancel, steps: remoteSteps);
      _msg('ההורדה הסתיימה (גרסה ${r.manifest.version}). הקבצים בתיקייה: $mirrorDir', transferDone: true);
    } on DownloadCancelled {
      _msg('ההורדה נעצרה. ניתן להמשיך אותה בהמשך מאותה נקודה.');
    } catch (e) {
      _msg('ההורדה נכשלה: ${friendlyNetError(e)}', error: true);
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
    if (await _blockedByOtzaria()) return;
    if (!await _targetIsSqlite()) return;
    final m = r.manifest;
    message = null;
    _cancel = false;
    activity = DbActivity('בודק את המסד');
    notifyListeners();
    var applied = 0;
    var artifactsCount = 1;
    final tmpDir = _updateTmpDir();
    try {
      var artifacts = <DbArtifact>[m.full];
      if (await File(targetDb).exists()) {
        final info = await _service.inspectLocalDb(
          m,
          targetDb,
          onProgress: (d, t) => _progress(d, t, 'מזהה את גרסת המסד'),
          isCancelled: () => _cancel,
          knownSha: await _cachedSha(targetDb),
          steps: remoteSteps?.manifest,
          chainIsWorthIt: (c) => _worthIt(c, m),
        );
        if (info.state == LocalDbState.current) {
          activity = null;
          local = info;
          _msg('המסד כבר בגרסה העדכנית (${m.version}).${await _ensureAttached()}');
          return;
        }
        if (info.updates != null) artifacts = info.updates!;
        if (info.state == LocalDbState.unknown && confirm != null) {
          if (!await confirm!(unknownDbConfirmText)) {
            activity = null;
            _msg('הפעולה בוטלה. המסד הקיים לא שונה.');
            return;
          }
        }
      }
      var missing = 0;
      for (final a in artifacts) {
        for (final part in a.parts) {
          final f = File(DbService.partPath(tmpDir, part));
          if (!(f.existsSync() && f.lengthSync() == part.size)) missing += part.size;
        }
      }
      if (!await _hasRoomFor(DbService.requiredBytes(artifacts, bytesToDownload: missing))) {
        activity = null;
        notifyListeners();
        return;
      }
      artifactsCount = artifacts.length;
      final isDelta = artifacts.first.isDelta;
      activity!.title = isDelta ? 'מוריד עדכון' : 'מוריד את המסד המלא';
      notifyListeners();
      // תיקיית הורדה זמנית ליד המסד, לא תיקיית המראה: קבצים שהוכנו שם למחשב אחר (והמניפסט שמצביע עליהם)
      // לא נמחקים ולא נדרסים. נשארת אחרי הפסקה כדי שההורדה תימשך, ונמחקת אחרי עדכון מוצלח.
      await _service.download(r, artifacts, tmpDir,
          onProgress: _progress, isCancelled: () => _cancel, steps: remoteSteps);
      for (var i = 0; i < artifacts.length; i++) {
        // בשרשרת ארוכה אוצריא עלולה להיפתח באמצע: בודקים לפני כל צעד.
        if (i > 0 && await OtzariaLocator.isRunning()) {
          throw _ChainStopped('אוצריא נפתחה באמצע העדכון');
        }
        final a = artifacts[i];
        activity!.title = !isDelta
            ? 'מתקין את המסד'
            : artifacts.length > 1
                ? 'מעדכן את המסד (${i + 1} מתוך ${artifacts.length})'
                : 'מעדכן את המסד';
        notifyListeners();
        await _service.install(a, tmpDir, targetDb, onProgress: _progress, isCancelled: () => _cancel);
        applied++;
        await _rememberSha(targetDb, a.sha256);
      }
      // הקבצים כבר הוחלו: לא משאירים מאות MB מיותרים בדיסק.
      try {
        await Directory(tmpDir).delete(recursive: true);
      } catch (_) {}
      _msg('המסד עודכן לגרסה ${m.version}.${await _ensureAttached()}');
    } on DownloadCancelled {
      _msg(_stoppedText(applied, total: artifactsCount));
    } on _ChainStopped catch (e) {
      _msg('${e.reason}. ${_stoppedText(applied, total: artifactsCount, always: true)} סגרו את אוצריא ולחצו שוב.', error: true);
    } catch (e) {
      final text = e.toString();
      final cancelled = text.contains('הפעולה בוטלה');
      if (cancelled) {
        _msg(_stoppedText(applied, total: artifactsCount));
      } else if (applied > 0) {
        _msg('${_failText(e)}\n${_stoppedText(applied, total: artifactsCount, always: true)}', error: true);
      } else {
        _msg(_failText(e), error: true);
      }
    }
    activity = null;
    notifyListeners();
    await refreshMirror();
    await inspectTarget();
  }

  String _updateTmpDir() => p.join(p.dirname(targetDb), '.books-update-tmp');

  /// הודעת עצירה: אם כבר הוחלו צעדים, המסד עודכן לגרסת ביניים תקינה ואפשר להמשיך משם.
  static String _stoppedText(int applied, {required int total, bool always = false}) {
    if (applied > 0) {
      return 'המסד עודכן לגרסת ביניים תקינה ($applied מתוך $total צעדים הוחלו) ואפשר להמשיך משם: לחצו שוב על העדכון.';
    }
    return always ? 'המסד הקיים לא שונה.' : 'הפעולה נעצרה. המסד הקיים לא שונה.';
  }

  /// מוחק את זיהוי הגרסה של המחשב היעד (להורדת המסד המלא).
  void clearTransferVersion() {
    fromVersion = null;
    detectedCurrentPath = null;
    notifyListeners();
  }

  // ─── התקנה ────────────────────────────────────────────────────────

  InstallPlan? get plan {
    final m = mirror?.manifest;
    if (m == null) return null;
    if (targetDb.isEmpty) return null;
    final exists = File(targetDb).existsSync();
    final fullOk = DbService.fullAvailable(m.full, mirrorDir);
    if (!exists) {
      return fullOk
          ? InstallPlan(InstallAction.full, 'הקובץ אינו קיים: יותקן המסד המלא (גרסה ${m.version}).', artifact: m.full)
          : InstallPlan(InstallAction.blocked, 'בתיקייה אין את קובץ המסד המלא, ולכן אי אפשר ליצור מסד חדש.');
    }
    final info = localMirror;
    if (info == null) return null; // עדיין מזהים
    switch (info.state) {
      case LocalDbState.current:
        return InstallPlan(InstallAction.none, 'המסד כבר בגרסה העדכנית (${m.version}).');
      case LocalDbState.hasDelta:
        final ups = info.updates ?? [info.delta!];
        if (ups.every((u) => DbService.isComplete(u, mirrorDir))) {
          final size = formatBytes(ups.fold<int>(0, (a, b) => a + b.downloadSize));
          return InstallPlan(
            InstallAction.delta,
            ups.length == 1
                ? 'גרסה ${info.version} ← ${m.version}: יוחל קובץ עדכון ($size).'
                : 'גרסה ${info.version} ← ${m.version}: יוחלו ${ups.length} קבצי עדכון ברצף ($size).',
            artifact: ups.first,
            artifacts: ups,
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
    if (await _blockedByOtzaria()) return;
    if (!await _targetIsSqlite()) return;
    if (!await _hasRoomFor(DbService.requiredBytes(pl.all))) return;
    if (pl.action == InstallAction.full &&
        File(targetDb).existsSync() &&
        localMirror?.state == LocalDbState.unknown &&
        confirm != null &&
        !await confirm!(unknownDbConfirmText)) {
      _msg('הפעולה בוטלה. המסד הקיים לא שונה.');
      return;
    }
    message = null;
    _cancel = false;
    activity = DbActivity('מעתיק את הספרים');
    notifyListeners();
    var applied = 0;
    try {
      for (final a in pl.all) {
        if (applied > 0 && await OtzariaLocator.isRunning()) {
          throw _ChainStopped('אוצריא נפתחה באמצע העדכון');
        }
        await _service.install(a, mirrorDir, targetDb, onProgress: _progress, isCancelled: () => _cancel);
        applied++;
      }
      final attached = await _ensureAttached();
      _msg('הספרים הועתקו בהצלחה (גרסה ${mirror!.manifest.version}).${attached.isEmpty ? ' אפשר לפתוח את אוצריא.' : attached}');
    } on DownloadCancelled {
      _msg(_stoppedText(applied, total: pl.all.length));
    } on _ChainStopped catch (e) {
      _msg('${e.reason}. ${_stoppedText(applied, total: pl.all.length, always: true)} סגרו את אוצריא ולחצו שוב.', error: true);
    } catch (e) {
      final text = e.toString();
      if (text.contains('הפעולה בוטלה')) {
        _msg(_stoppedText(applied, total: pl.all.length));
      } else if (applied > 0) {
        _msg('${_failText(e)}\n${_stoppedText(applied, total: pl.all.length, always: true)}', error: true);
      } else {
        _msg(_failText(e), error: true);
      }
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
