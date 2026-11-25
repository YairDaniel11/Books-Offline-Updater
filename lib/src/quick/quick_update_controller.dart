import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../controllers/app_controller.dart';
import '../db/db_controller.dart';
import '../db/db_manifest.dart';
import '../db/db_service.dart';
import '../services/disk_space.dart';
import '../services/net_errors.dart';
import '../services/otzaria_locator.dart';
import '../vectors/vector_set.dart' show LiveSet, isOurs;
import '../vectors/vectors_controller.dart';
import '../vectors/vectors_manifest.dart';
import 'progress_rate.dart';
import 'quick_log.dart';

/// checking: בדיקה אוטומטית בפתיחה. ready: מחכים ללחיצה על הכפתור ([action]). working: הורדה/עדכון.
enum QuickPhase { checking, ready, working, done, failed }

/// מה יקרה בלחיצה על הכפתור: הורדה לכונן (מחשב מחובר), עדכון המסד, או התקנה ראשונה (בחירת מיקום).
enum QuickAction { download, update, install }

/// החיפוש החכם שבכונן מול המחשב הזה. none: אין בכונן (או שהוא למסד בגרסה אחרת). pending: אפשר להתקין.
/// noOtzariaSet: באוצריא אין עדיין סט וקטורים. otherVersion: כבר מותקנת גרסה אחרת של וקטורי המאגר.
enum SmartSearchState { none, pending, installed, noOtzariaSet, otherVersion }

/// התשובה לשאלה "להוריד גם את החיפוש החכם?". [remember]: לא לשאול שוב.
class SmartSearchAnswer {
  const SmartSearchAnswer({required this.download, required this.remember});
  final bool download;
  final bool remember;
}

/// "עדכון מהיר": מה שקורה כשהתוכנה מופעלת מתוך עדכוני אוצריא (תוכנות נוספות).
///
/// במחשב מחובר: בודק בכל פתיחה אם יש גרסה חדשה, ובלחיצה מוריד לכונן את המסד המלא ואת קובצי העדכון
/// של עד [stepsBack] הגרסאות האחרונות. במחשב בלי רשת: בלחיצה מעדכן את המסד מהכונן, ובפעם הראשונה
/// מתקין אותו במיקום שהמשתמש בוחר.
class QuickUpdateController extends ChangeNotifier {
  /// [freeSpace]: בדיקת מקום פנוי בכונן (מוזרק בבדיקות, כדי לא להריץ תהליך חיצוני).
  /// [findOtzariaDb]: איפה אוצריא קוראת את המסד (מוזרק בבדיקות, כדי לא לקרוא את אוצריא של המחשב).
  /// [smartSearch]: יוצר את בקר וקטורי החיפוש החכם; בלעדיו העדכון המהיר מטפל במסד בלבד.
  QuickUpdateController({
    required this.mirrorDir,
    DbController? db,
    Future<String?> Function()? findOtzariaDb,
    VectorsController Function(DbController db)? smartSearch,
    Future<int?> Function(String path)? freeSpace,
  }) : db = db ?? DbController(AppController()..dataDir = p.dirname(mirrorDir)),
       _findOtzariaDb = findOtzariaDb ?? OtzariaLocator.findDbPath,
       _freeSpace = freeSpace ?? freeDiskSpace {
    this.db.autoInspect = false;
    this.db.addListener(_onDb);
    vectors = smartSearch?.call(this.db)?..addListener(_onDb);
  }

  // ─── חיפוש חכם ────────────────────────────────────────────────────

  /// וקטורי החיפוש החכם (חיפוש לפי משמעות) של המאגר: יורדים לכונן לצד המסד, ומותקנים באוצריא אחריו.
  late final VectorsController? vectors;

  /// הבחירה השמורה בהורדה לכונן: `true` = תמיד להוריד, `false` = לעולם לא, `null` = לשאול בכל פעם.
  bool? smartSearchChoice;

  /// שואל את המשתמש אם להוריד גם את החיפוש החכם (מוזרק מהמסך). `null` = המשתמש סגר בלי לבחור.
  Future<SmartSearchAnswer?> Function(String size)? askSmartSearch;

  /// קובץ הבחירה השמורה. נקבע מבחוץ (ברירת מחדל: בהגדרות המשתמש); `null` = לא שומרים (בבדיקות).
  String? smartSearchSettingsPath;

  bool _choiceLoaded = false;

  void _loadSmartSearchChoice() {
    if (_choiceLoaded) return;
    _choiceLoaded = true;
    final path = smartSearchSettingsPath;
    if (path == null) return;
    try {
      final j = jsonDecode(File(path).readAsStringSync());
      final v = j is Map ? j['smartSearch'] : null;
      if (v is bool) smartSearchChoice = v;
    } catch (_) {}
  }

  /// שומר (או מבטל, עם `null`) את הבחירה, כך שלא ישאלו שוב.
  void setSmartSearchChoice(bool? v) {
    smartSearchChoice = v;
    QuickLog.info('חיפוש חכם: בחירה שמורה = ${v ?? "לשאול"}');
    final path = smartSearchSettingsPath;
    if (path != null) {
      try {
        Directory(p.dirname(path)).createSync(recursive: true);
        File(path).writeAsStringSync(jsonEncode({'smartSearch': v}));
      } catch (e) {
        QuickLog.warn('שמירת הבחירה בחיפוש החכם נכשלה: $e');
      }
    }
    // "שינוי" אחרי סיום: מציעים שוב את ההורדה (והשאלה תופיע בלחיצה).
    if (v == null && phase == QuickPhase.done && online == true && !localMode && !_running && db.remote != null) {
      _checkDrive();
      return;
    }
    notifyListeners();
  }

  /// גודל החיפוש החכם שיורד לכונן (לשאלה ולתצוגה).
  String get smartSearchSize {
    final m = _onlineVectors;
    return m == null ? '' : _size(m.downloadSize);
  }

  /// במצב הורדה, כשיש חיפוש חכם להוריד והבחירה שמורה: מוצגת שורה קטנה עם "שינוי".
  /// (גם בסיום, כשהבחירה "לא" השאירה את הכונן בלעדיו.)
  bool get showsSmartSearchChoice =>
      ((phase == QuickPhase.ready && action == QuickAction.download) ||
          (phase == QuickPhase.done && online == true && !localMode)) &&
      smartSearchChoice != null &&
      smartSearchMissing > 0;

  /// ההחלטה להורדה הנוכחית (אחרי השאלה או מהבחירה השמורה).
  bool _wantSmartSearch = false;

  /// הפעולה שרצה כרגע: על החיפוש החכם או על המסד.
  DbActivity? get activity => vectors?.activity ?? db.activity;

  /// עצירת הפעולה הנוכחית.
  void cancel() {
    final v = vectors;
    if (v != null && v.busy) {
      v.cancel();
    } else {
      db.cancel();
    }
  }

  Future<void>? _vectorsCheck;

  /// בדיקת הוקטורים ברשת (מניפסט קטן). רצה במקביל לבדיקת המסד, ולא מעכבת את המצב בלי רשת.
  Future<void> _startVectorsCheck() {
    final v = vectors!;
    if (!_vectorsInited) {
      _vectorsInited = true;
      return _vectorsCheck = v.init();
    }
    v.refreshMirror();
    if (v.checking && _vectorsCheck != null) return _vectorsCheck!;
    return _vectorsCheck = v.checkRemote();
  }

  bool _vectorsInited = false;

  /// הוקטורים ברשת, כשהם בנויים בדיוק למסד שברשת (אחרת לא מורידים אותם).
  VectorsManifest? get _onlineVectors {
    final v = vectors;
    if (v == null || v.remote == null || db.remote == null || v.remoteMismatch() != null) return null;
    return v.remote!.manifest;
  }

  /// כמה בתים של החיפוש החכם חסרים בכונן (0 כשהוא כבר שלם שם, או כשאין מה להוריד).
  int get smartSearchMissing {
    final m = _onlineVectors;
    if (m == null) return 0;
    var missing = 0;
    for (final f in m.files) {
      final file = File(p.join(mirrorDir, f.file));
      if (!(file.existsSync() && file.lengthSync() == f.size)) missing += f.size;
    }
    // הקבצים שלמים אבל המניפסט בכונן ישן: ההורדה רק תאמת אותם ותכתוב מניפסט.
    if (missing == 0 && vectors!.mirror?.manifest.segment.id != m.segment.id) return 1;
    return missing;
  }

  /// מצב החיפוש החכם במחשב הזה, מול מה שבכונן.
  SmartSearchState get smartSearchLocal {
    final v = vectors;
    if (v == null) return SmartSearchState.none;
    final r = v.mirror;
    if (r == null || !v.preparedComplete) return SmartSearchState.none;
    // וקטורים ישנים בכונן (למסד בגרסה אחרת מזו שבכונן) לא יתאימו למסד אחרי העדכון.
    final dbVersion = db.mirror?.manifest.version;
    if (dbVersion != null && r.manifest.dbVersion > dbVersion) return SmartSearchState.none;
    final dir = v.vectorsDir;
    if (dir == null || !File(p.join(dir, 'CURRENT')).existsSync()) return SmartSearchState.noOtzariaSet;
    try {
      final segs = LiveSet.open(dir).segments;
      if (segs.any((s) => s['id'] == r.manifest.segment.id)) return SmartSearchState.installed;
      if (segs.any(isOurs)) return SmartSearchState.otherVersion;
    } catch (e) {
      QuickLog.warn('חיפוש חכם: קריאת הסט של אוצריא נכשלה: $e');
      return SmartSearchState.noOtzariaSet;
    }
    return SmartSearchState.pending;
  }

  /// אחרי סיום: החיפוש החכם לא הותקן כי אוצריא פתוחה, ואפשר לנסות שוב אחרי שסוגרים אותה.
  bool canRetrySmartSearch = false;

  Future<void> retrySmartSearch() async {
    if (!canRetrySmartSearch || _running || _disposed) return;
    canRetrySmartSearch = false;
    final t = title, d = detail;
    await _guard(() async {
      final w = await _installSmartSearch();
      _done(t, d, warning: w);
    });
  }

  /// מתקין אוטומטית את החיפוש החכם מהכונן, כשבאוצריא במחשב הזה כבר מופעל חיפוש חכם.
  /// כשאין (או כשכבר מותקנת גרסה אחרת) מדלגים בשקט — רק בלוג. מחזיר הערה למשתמש, או `null`.
  Future<String?> _installSmartSearch() async {
    final v = vectors;
    if (v == null) return null;
    v.refreshMirror();
    final state = smartSearchLocal;
    QuickLog.info('חיפוש חכם: ${state.name}');
    if (state != SmartSearchState.pending) return null;
    if (await OtzariaLocator.isRunning()) {
      canRetrySmartSearch = true;
      return 'כדי להתקין את החיפוש החכם צריך לסגור את אוצריא. סגרו אותה ולחצו "התקנת החיפוש החכם".';
    }
    await v.install();
    QuickLog.info('חיפוש חכם: ${v.messageIsError ? "נכשל" : "הסתיים"} — ${v.message}');
    final msg = v.message;
    v.clearMessage();
    if (v.messageIsError) return 'החיפוש החכם לא הותקן: $msg';
    // נעצר על ידי המשתמש: לא מותקן, ואפשר להפעיל שוב.
    if (smartSearchLocal != SmartSearchState.installed) return msg;
    return null;
  }

  /// מוריד את החיפוש החכם לכונן אחרי המסד. מחזיר הערה כשלא הצליח.
  Future<String?> _downloadSmartSearch() async {
    final v = vectors;
    if (v == null || !_wantSmartSearch || smartSearchMissing == 0) return null;
    QuickLog.info('חיפוש חכם: הורדה לכונן');
    await v.prepare(folder: mirrorDir);
    QuickLog.info('חיפוש חכם: ${v.messageIsError ? "נכשל" : "הסתיים"} — ${v.message}');
    final msg = v.message;
    final error = v.messageIsError;
    v.clearMessage();
    if (smartSearchMissing == 0) return null;
    return error ? 'המסד מוכן, אבל החיפוש החכם לא הורד: $msg' : 'הורדת החיפוש החכם נעצרה. אפשר להפעיל שוב ולהשלים אותה.';
  }

  /// כמה זמן מחכים לשרת לפני שמציעים לדלג על הרשת ולעדכן מהכונן.
  static Duration slowNetwork = const Duration(seconds: 6);

  /// מהירות וזמן משוער של הפעולה הנוכחית.
  final ProgressRate rate = ProgressRate();

  void _onDb() {
    final a = activity;
    if (a == null || a.total == null || a.total! <= 0) {
      rate.reset();
    } else if (!_verifying(a)) {
      // לפי כותרת השלב בלבד: שם הקובץ ב-detail מתחלף בכל חלק, והמדידה הייתה מתאפסת בכל פעם.
      // בדיקות התקינות שבין החלקים לא נמדדות, כדי לא לשבור את מדידת ההורדה.
      rate.add(a.title, a.done, a.total);
    }
    // הבדיקה מול השרת התחילה בפועל: רק מעכשיו סופרים את זמן ההמתנה לפני הצעת הדילוג.
    if (_skip != null && db.checking && _slowTimer == null && !netSlow) {
      _slowTimer = Timer(slowNetwork, () {
        netSlow = true;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  /// בדיקת תקינות (SHA) בין חלקי ההורדה או לפני ההחלה — לא הורדה, ולכן בלי מהירות.
  static bool _verifying(DbActivity a) => a.detail.startsWith('בודק');

  /// רענון שורת המהירות גם כשאין התקדמות (הורדה תקועה: ההערכה נעלמת במקום להישאר ישנה).
  Timer? _tick;

  /// שורת "12.3 MB/s · עוד כ-3 דק'" בזמן פעולה; ריקה כשאין עדיין הערכה.
  String get rateText {
    final a = activity;
    if (a == null || phase != QuickPhase.working || _verifying(a)) return '';
    final parts = <String>[];
    final speed = rate.bytesPerSecond;
    // מהירות רק בהורדה מהרשת; בהתקנה מהכונן המספר פחות אומר למשתמש.
    if (action == QuickAction.download && !localMode && speed != null && speed > 0) {
      parts.add(_isolate('${DbController.formatBytes(speed.round())}/s'));
    }
    final left = rate.remaining;
    if (left != null) parts.add(ProgressRate.formatRemaining(left));
    return parts.join(' · ');
  }

  // ─── שלבי הבדיקה ──────────────────────────────────────────────────

  /// מה נבדק כרגע (במצב [QuickPhase.checking]).
  String get checkingText {
    if (db.inspecting) return 'מזהה את גרסת המסד במחשב...';
    if (db.checking) return 'מתחבר לשרת העדכונים...';
    return online == false ? 'בודק את המסד...' : 'בודק עדכונים...';
  }

  /// התקדמות זיהוי המסד המקומי (חישוב SHA של כ-1GB), כשהוא רץ בזמן הבדיקה.
  double? get checkingProgress => db.inspecting ? db.inspectProgress : null;

  Completer<void>? _skip;
  Timer? _slowTimer;
  Future<void>? _net;

  /// הבדיקה מול השרת מתארכת (למשל מסנן אינטרנט): מוצג כפתור לדלג ולעדכן מהכונן.
  bool netSlow = false;

  /// המשתמש דילג על בדיקת הרשת בהפעלה הזו: עובדים מול הכונן בלבד.
  bool _offlineForced = false;

  bool get canSkipNetwork =>
      phase == QuickPhase.checking && netSlow && db.checking && _skip != null && !_skip!.isCompleted;

  void skipNetwork() {
    if (!canSkipNetwork) return;
    QuickLog.info('דילוג על בדיקת הרשת (המשתמש)');
    _skip!.complete();
  }

  /// ממתין לבדיקת הרשת או לדילוג. מחזיר `true` אם המשתמש דילג.
  Future<bool> _awaitNetwork(Future<void> net) async {
    _net = net;
    final skip = _skip = Completer<void>();
    netSlow = false;
    _slowTimer?.cancel();
    _slowTimer = null;
    // הטיימר מתחיל ב-_onDb כש-db.checking נדלק (לא בזמן קריאת הכונן שלפני הרשת).
    _onDb();
    try {
      // Future.any מאזין גם לשגיאה מאוחרת של [net] אחרי דילוג, כך שהיא לא נזרקת החוצה.
      await Future.any([net, skip.future]);
    } finally {
      _slowTimer?.cancel();
      _slowTimer = null;
      netSlow = false;
      _skip = null;
    }
    if (!skip.isCompleted) _net = null;
    return skip.isCompleted;
  }

  /// הסבר טכני מלא לתקלה האחרונה (להעתקה ולדיווח). ההודעה עצמה ב-[message].
  String? errorDetails;

  /// הודעה ברורה בעברית לחריגה, במקום הטקסט הטכני שלה.
  static String friendlyError(Object e) {
    if (e is DbException) return e.message;
    if (e is DbManifestException) return e.message;
    if (e is FileSystemException) {
      final path = e.path;
      final where = path == null || path.isEmpty ? '' : '\n${_isolate(path)}';
      switch (e.osError?.errorCode) {
        case 32:
        case 33:
          return 'הקובץ תפוס על ידי תוכנה אחרת. סגרו את אוצריא ונסו שוב.$where';
        case 5:
          return 'אין הרשאה לגשת לקובץ או לתיקייה.$where';
        case 39:
        case 112:
          return 'אין מספיק מקום פנוי בכונן.$where';
        case 2:
        case 3:
          return 'הקובץ או התיקייה לא נמצאו. ייתכן שהכונן נותק.$where';
        case 21:
        case 23:
        case 483:
        case 1117:
          return 'שגיאה בקריאה מהכונן. ודאו שהוא מחובר כראוי ונסו שוב.$where';
      }
      return 'שגיאה בגישה לקבצים.$where';
    }
    if (e is SocketException || e is HandshakeException || e is TlsException || e is HttpException) {
      return friendlyNetError(e);
    }
    if (e is TimeoutException) return 'השרת לא הגיב בזמן. בדקו את החיבור ונסו שוב.';
    return 'אירעה שגיאה לא צפויה.';
  }

  void _unexpected(Object e, StackTrace st) {
    QuickLog.error('שגיאה לא צפויה', e, st);
    errorDetails = e.toString();
    _fail(friendlyError(e));
  }

  /// "מה חדש" בגרסה שמוצעת (מהמניפסט החתום); ריק כשאין.
  String get releaseNotes {
    if (phase != QuickPhase.ready) return '';
    final r = action == QuickAction.download ? db.remote : (_offlineForced ? db.mirror : db.mirror ?? db.remote);
    return r?.manifest.notes.trim() ?? '';
  }

  /// כמה גרסאות אחורה אפשר לעדכן בקובצי עדכון בלבד (כמו עדכוני אוצריא למסד הרשמי).
  static const stepsBack = 10;

  /// תיקיית קובצי המסד בכונן, ליד התוכנה.
  final String mirrorDir;
  final DbController db;
  final Future<String?> Function() _findOtzariaDb;
  final Future<int?> Function(String path) _freeSpace;

  QuickPhase phase = QuickPhase.checking;
  QuickAction? action;

  /// נקבע אחרי הבדיקה: `true` = מחשב מחובר (הורדה לכונן), `false` = עדכון מהכונן.
  bool? online;

  /// שתי שורות קצרות למצב הנוכחי (מוכן / הסתיים).
  String title = '';
  String detail = '';

  /// הערה שדורשת תשומת לב (למשל: המסד לא צורף לאוצריא). מוצגת בהדגשה.
  String? warning;

  /// הודעת כשל.
  String? note;

  bool _inited = false;
  bool _running = false;
  bool _disposed = false;
  List<DbArtifact> _driveList = const [];

  /// יש פעולה בעיצומה (גם בשלבים שבהם [DbController.busy] עוד/כבר false, כמו זיהוי הגרסה).
  bool get running => _running || db.busy;

  /// התיקייה שמוצעת בהתקנה ראשונה: "מסדים אישיים" של אוצריא (או במסמכים, כשאוצריא לא נמצאה).
  String get proposedFolder => p.dirname(OtzariaLocator.defaultNewDbPath());

  String? _chosenFolder;

  /// לאן תותקן המסד בהתקנה ראשונה: ברירת המחדל כבר "נבחרה"; [changeFolder] רק אם המשתמש משנה.
  String get installFolder => _chosenFolder ?? proposedFolder;

  void changeFolder(String folder) {
    _chosenFolder = folder;
    QuickLog.info('מיקום התקנה שונה ל: $folder');
    notifyListeners();
  }

  /// מחשב מחובר אחרי שהכונן מוכן: מעדכנים מאותו כונן גם את המסד שבמחשב הזה.
  bool localMode = false;

  /// מחשב מחובר: המסד שמצורף לאוצריא כאן כבר בגרסה האחרונה (נבדק ב-[_probeLocal]).
  /// בלי הבדיקה הזו "עדכון במחשב זה" הוצע בכל פתיחה, ובלחיצה רק התגלה שהמסד מעודכן.
  bool _localUpToDate = false;

  bool get canUpdateThisComputer =>
      phase == QuickPhase.done &&
      online == true &&
      !localMode &&
      (!_localUpToDate || smartSearchLocal == SmartSearchState.pending);

  /// מחשב מחובר: האם המסד שמצורף לאוצריא במחשב הזה כבר מעודכן (SHA שמור, או חישוב פעם אחת).
  Future<void> _probeLocal() async {
    _localUpToDate = false;
    final attached = db.otzariaDbPath;
    // לא מותקן כאן: משאירים את הכפתור (הוא מוביל להתקנה ראשונה).
    if (attached == null || !_existsSync(attached)) return;
    try {
      if (db.targetDb != attached) {
        await db.setTarget(attached);
        if (_disposed || db.targetDb != attached) return;
      }
      await db.inspectTarget();
      _localUpToDate = db.plan?.action == InstallAction.none;
      QuickLog.info('מסד מקומי (מחשב מחובר): ${_localUpToDate ? "מעודכן" : "לא מעודכן"} — ${db.plan?.message}');
    } catch (e) {
      QuickLog.warn('זיהוי המסד המקומי נכשל: $e');
    }
  }

  String get message => note ?? db.message ?? '';

  /// כשל "רך": המשתמש עצר, או ביטל אישור. מוצג בלי צבע שגיאה.
  bool get stoppedByUser => phase == QuickPhase.failed && note == null && db.message != null && !db.messageIsError;

  int? get _version => (_offlineForced ? db.mirror : (db.remote ?? db.mirror))?.manifest.version;

  // ─── בדיקה ────────────────────────────────────────────────────────

  /// הבדיקה האוטומטית בפתיחה (וב"נסו שוב"): מה מצב הכונן או המסד, ואיזה כפתור להציג.
  Future<void> start() async {
    if (_running || _disposed) return;
    _running = true;
    note = null;
    warning = null;
    errorDetails = null;
    action = null;
    localMode = false;
    _offlineForced = false;
    canRetrySmartSearch = false;
    db.clearMessage();
    phase = QuickPhase.checking;
    notifyListeners();
    try {
      _loadSmartSearchChoice();
      final vectorsCheck = vectors == null ? null : _startVectorsCheck();
      bool skipped;
      if (!_inited) {
        _inited = true;
        skipped = await _awaitNetwork(db.init(pinMirrorDir: mirrorDir));
        // דילוג באמצע: init עוד ממתין לרשת, אבל את הכונן הוא כבר קרא. קוראים שוב ליתר ביטחון.
        if (skipped && !_disposed) await db.refreshMirror();
        db.otzariaDbPath = await _findOtzariaDb();
      } else {
        // ניסיון חוזר: ייתכן שבינתיים המסד צורף באוצריא, או שהתקנה קודמת נקטעה.
        db.otzariaDbPath = await _findOtzariaDb();
        if (db.targetDb.isNotEmpty) await DbService.recoverInterrupted(db.targetDb);
        await db.refreshMirror();
        // בדיקה קודמת שדילגו עליה עדיין רצה: ממתינים לה במקום להתחיל חדשה (checkRemote היה חוזר מיד).
        final pending = _net;
        skipped = await _awaitNetwork(pending != null && db.checking ? pending : db.checkRemote());
      }
      if (_disposed) return;
      _offlineForced = skipped;
      online = !skipped && db.remote != null;
      QuickLog.info(
        'בדיקה: ${online! ? "מחובר" : (skipped ? "בלי רשת (דילוג)" : "בלי רשת")}'
        '${db.remoteError == null ? "" : " (שגיאת רשת: ${db.remoteError})"}'
        ', גרסה ברשת: ${db.remote?.manifest.version}, בכונן: ${db.mirror?.manifest.version}'
        '${db.mirrorError == null ? "" : " (שגיאת כונן: ${db.mirrorError})"}'
        ', תיקיית הכונן: $mirrorDir, מצורף לאוצריא: ${db.otzariaDbPath}, יעד: ${db.targetDb}',
      );
      if (online! && vectorsCheck != null) {
        // המניפסט קטן; אם הוא מתעכב, ממשיכים עם המסד בלבד.
        try {
          await vectorsCheck.timeout(const Duration(seconds: 20));
        } catch (_) {}
        if (_disposed) return;
        vectors!.refreshMirror();
        QuickLog.info(
          'חיפוש חכם: ברשת למסד ${vectors!.remote?.manifest.dbVersion}'
          '${vectors!.remoteError == null ? "" : " (${vectors!.remoteError})"}'
          ', בכונן למסד ${vectors!.mirror?.manifest.dbVersion}',
        );
      }
      if (online!) {
        await _probeLocal();
        if (_disposed) return;
        _checkDrive();
      } else {
        await _checkLocal();
      }
    } catch (e, st) {
      _unexpected(e, st);
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  void _checkDrive() {
    final m = db.remote!.manifest;
    _driveList = driveSet(m, db.remoteSteps?.manifest);
    final missing = missingBytes(_driveList, mirrorDir);
    final smart = smartSearchMissing;
    QuickLog.info('כונן: ${_driveList.length} קבצים ברשימה, חסרים $missing בתים (חיפוש חכם: $smart)');
    if (missing == 0 && db.mirror?.manifest.version == m.version) {
      if (smart == 0 || smartSearchChoice == false) {
        _done('הכונן מעודכן', 'גרסה ${m.version}');
      } else {
        // המסד בכונן מעודכן, וחסר רק החיפוש החכם.
        _ready(QuickAction.download, 'החיפוש החכם זמין', 'המסד בכונן מעודכן (גרסה ${m.version})');
      }
      return;
    }
    _ready(QuickAction.download, 'גרסה ${m.version} זמינה', missing == 0 ? '' : '${_size(missing)} להורדה');
  }

  /// [runUpdate]: המשתמש כבר לחץ ("עדכון במחשב זה"), ולכן כשיש עדכון מחילים אותו מיד במקום להציג כפתור.
  Future<void> _checkLocal({bool runUpdate = false}) async {
    if (db.mirror == null) {
      final net = db.remoteError == null || _offlineForced ? '' : '\n\nאם המחשב מחובר לרשת: ${db.remoteError}';
      final mErr = db.mirrorError;
      // שגיאת קבצים גולמית (באנגלית) עוברת לפרטים; ההודעה נשארת ברורה.
      final technical = mErr != null && RegExp(r'Exception|Error:|OS Error').hasMatch(mErr);
      if (technical) errorDetails = mErr;
      _fail(
        mErr != null
            ? (technical
                  ? 'לא ניתן לקרוא את קובצי המסד בכונן. ודאו שהכונן מחובר ונסו שוב.$net'
                  : 'קובצי המסד בכונן אינם תקינים: $mErr$net')
            : 'אין בכונן קבצי מסד. הפעילו קודם את התוכנה במחשב מחובר לרשת.$net',
      );
      return;
    }
    final v = _version;
    final attached = db.otzariaDbPath;
    // מצורף לאוצריא אבל הקובץ נמחק: כמו התקנה ראשונה (בחירת מיקום).
    if (attached != null && _existsSync(attached)) {
      if (db.targetDb != attached) {
        await db.setTarget(attached);
        if (_disposed) return;
        if (db.targetDb != attached) {
          _fail(null);
          return;
        }
      }
    } else if (attached != null || !_existsSync(db.targetDb)) {
      _ready(QuickAction.install, 'המסד לא מותקן במחשב הזה', 'גרסה $v בכונן');
      return;
    }
    await db.inspectTarget();
    if (_disposed) return;
    final plan = db.plan;
    QuickLog.info(
      'מסד מקומי: ${db.targetDb}, גרסה: ${db.localMirror?.version ?? "לא מזוהה"}, '
      'תוכנית: ${plan?.action.name} — ${plan?.message}',
    );
    if (plan == null) {
      _fail(db.message ?? 'לא ניתן לזהות את המסד במחשב הזה.');
      return;
    }
    switch (plan.action) {
      case InstallAction.none:
        // המסד מעודכן, אבל החיפוש החכם שבכונן עוד לא הותקן כאן: מציעים אותו (ההתקנה עוברת ב-[_install]).
        if (!runUpdate && smartSearchLocal == SmartSearchState.pending) {
          _ready(QuickAction.update, 'החיפוש החכם זמין', 'המסד מעודכן (גרסה $v)');
          return;
        }
        // מעודכן, אבל אולי עוד לא מצורף לאוצריא (למשל הותקן ידנית).
        final extra = await db.ensureAttached();
        final smart = runUpdate ? await _installSmartSearch() : null;
        _done('המסד מעודכן', 'גרסה $v', warning: _joinWarnings(_warningFrom(extra), smart));
      case InstallAction.blocked:
        _fail('${plan.message}\nהפעילו את התוכנה במחשב מחובר כדי להשלים את הקבצים בכונן.');
      case InstallAction.delta:
      case InstallAction.full:
        if (runUpdate) {
          await _install();
          return;
        }
        final from = db.localMirror?.version;
        final size = plan.all.fold<int>(0, (a, b) => a + b.downloadSize);
        final kind = plan.action == InstallAction.delta ? 'עדכון חלקי' : 'החלפת המסד כולו';
        _ready(
          QuickAction.update,
          'גרסה $v זמינה',
          [if (from != null) 'במחשב: גרסה $from', '$kind (${_size(size)})'].join(' · '),
        );
    }
  }

  /// "עדכון במחשב זה": אחרי שהכונן הוכן במחשב המחובר, מעדכנים ממנו גם את המסד המקומי
  /// (או, כשהמסד לא מותקן כאן, עוברים להתקנה ראשונה).
  Future<void> updateThisComputer() async {
    if (!canUpdateThisComputer || _running || _disposed) return;
    localMode = true;
    QuickLog.info('עדכון במחשב זה');
    await _guard(() => _checkLocal(runUpdate: true));
  }

  // ─── פעולה ────────────────────────────────────────────────────────

  /// הכפתור הראשי: הורדה לכונן, עדכון המסד, או התקנה ראשונה ב-[installFolder].
  Future<void> run() async {
    if (phase != QuickPhase.ready || _running || _disposed) return;
    switch (action) {
      case QuickAction.download:
        if (!await _decideSmartSearch()) return;
        await _guard(_download);
      case QuickAction.update:
        await _guard(_install);
      case QuickAction.install:
        await installTo(installFolder);
      case null:
        return;
    }
  }

  /// לפני הורדה לכונן: האם להוריד גם את החיפוש החכם — מהבחירה השמורה, ואחרת שואלים.
  /// מחזיר `false` כשהמשתמש סגר את השאלה בלי לבחור (לא מתחילים).
  Future<bool> _decideSmartSearch() async {
    _wantSmartSearch = false;
    if (smartSearchMissing == 0) return true;
    final saved = smartSearchChoice;
    if (saved != null) {
      _wantSmartSearch = saved;
      return true;
    }
    final ask = askSmartSearch;
    if (ask == null) return true;
    final a = await ask(smartSearchSize);
    if (_disposed || a == null) return false;
    _wantSmartSearch = a.download;
    QuickLog.info('חיפוש חכם: ${a.download ? "להוריד" : "לא להוריד"}${a.remember ? " (לזכור)" : ""}');
    if (a.remember) setSmartSearchChoice(a.download);
    // נשאר במצב "מוכן", אבל המסד בכונן כבר מעודכן והחיפוש החכם לא נבחר: אין מה להוריד.
    return true;
  }

  /// התקנה ראשונה בתיקייה שהמשתמש בחר.
  Future<void> installTo(String folder) async {
    if (phase != QuickPhase.ready || action != QuickAction.install || _running || _disposed) return;
    await _guard(() async {
      await db.setTarget(p.join(folder, '$dbLibraryId.db'));
      if (_disposed) return;
      if (db.messageIsError && db.message != null) {
        _fail(null);
        return;
      }
      await _install();
    });
  }

  Future<void> _guard(Future<void> Function() body) async {
    _running = true;
    note = null;
    warning = null;
    errorDetails = null;
    rate.reset();
    phase = QuickPhase.working;
    notifyListeners();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    try {
      await body();
    } catch (e, st) {
      _unexpected(e, st);
    } finally {
      _tick?.cancel();
      _tick = null;
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _download() async {
    final m = db.remote!.manifest;
    final missing = missingBytes(_driveList, mirrorDir);
    final smart = _wantSmartSearch ? smartSearchMissing : 0;
    final need = missing + smart;
    if (need > 0) {
      final free = await _freeSpace(p.join(mirrorDir, 'x'));
      if (free != null && free < need + 64 * 1024 * 1024) {
        _fail(
          'אין מספיק מקום פנוי בכונן. דרושים ${_size(need)}, '
          'ופנויים ${_size(free)}.',
        );
        return;
      }
    }
    // המסד בכונן כבר מעודכן (וחסר רק החיפוש החכם): לא מורידים אותו שוב.
    if (missing > 0 || db.mirror?.manifest.version != m.version) {
      QuickLog.info('הורדה לכונן: מתחיל (${_size(missing)} חסרים)');
      final ok = await db.downloadArtifacts(_driveList, title: 'מוריד', doneMessage: '');
      QuickLog.info('הורדה לכונן: ${ok ? "הושלמה" : "לא הושלמה: ${db.message}"}');
      if (_disposed) return;
      if (!ok) {
        _fail(null);
        return;
      }
      await pruneOldPatches(mirrorDir, _driveList);
    }
    final smartNote = await _downloadSmartSearch();
    if (_disposed) return;
    final withSmart = vectors != null && _onlineVectors != null && smartSearchMissing == 0;
    _done(
      'הכונן מוכן',
      'גרסה ${m.version}${withSmart ? ' · כולל חיפוש חכם' : ''} · אפשר לעבור למחשב ללא רשת',
      warning: smartNote,
    );
  }

  Future<void> _install() async {
    await db.inspectTarget();
    if (_disposed) return;
    final plan = db.plan;
    // בתיקייה שנבחרה כבר יש מסד עדכני: רק מצרפים אותו לאוצריא.
    if (plan?.action == InstallAction.none) {
      final extra = await db.ensureAttached();
      final smart = await _installSmartSearch();
      if (_disposed) return;
      _done('המסד מעודכן', _withSmartDetail('גרסה ${_version ?? ''}'), warning: _joinWarnings(_warningFrom(extra), smart));
      return;
    }
    if (plan == null || !plan.canRun) {
      _fail(plan?.message ?? db.message ?? 'לא ניתן לזהות את המסד במחשב הזה.');
      return;
    }
    QuickLog.info('התקנה: ${plan.action.name} (${plan.all.length} קבצים) אל ${db.targetDb} — ${plan.message}');
    await db.install(title: plan.action == InstallAction.delta ? 'מעדכן את המסד' : 'מתקין את המסד');
    QuickLog.info('התקנה הסתיימה: ${db.messageIsError ? "שגיאה" : "ללא שגיאה"} — ${db.message}');
    if (_disposed) return;
    if (db.messageIsError || db.activity != null) {
      _fail(null);
      return;
    }
    await db.inspectTarget();
    if (_disposed) return;
    if (db.plan?.action != InstallAction.none) {
      // בוטל או נעצר (ההודעה כבר מ-db), או ש-install לא התחיל בכלל.
      _fail(db.message == null ? 'העדכון לא התחיל. נסו שוב.' : null);
      return;
    }
    final msg = db.message ?? '';
    final nl = msg.indexOf('\n');
    final smart = await _installSmartSearch();
    if (_disposed) return;
    _done(
      'המסד עודכן',
      _withSmartDetail('גרסה ${_version ?? ''}'),
      warning: _joinWarnings(nl < 0 ? null : msg.substring(nl + 1), smart),
    );
  }

  /// "· החיפוש החכם מותקן" כשהותקן בפעולה הזו (או כבר היה מותקן) ונבחר.
  String _withSmartDetail(String d) =>
      vectors != null && smartSearchLocal == SmartSearchState.installed ? '$d · החיפוש החכם מותקן' : d;

  static String? _joinWarnings(String? a, String? b) {
    final parts = [a, b].whereType<String>().where((s) => s.trim().isNotEmpty).toList();
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  /// גודל בבידוד כיווניות (LRI…PDI): בלעדיו "935.1 MB" מוצג הפוך בשורה עברית.
  static String _size(int bytes) => _isolate(DbController.formatBytes(bytes));

  /// טקסט משמאל לימין (גודל, נתיב) בבידוד כיווניות בתוך שורה עברית.
  static String _isolate(String s) => '${String.fromCharCode(0x2066)}$s${String.fromCharCode(0x2069)}';

  static String? _warningFrom(String attachNote) {
    final t = attachNote.trim();
    return attachNote.startsWith('\n') && t.isNotEmpty ? t : null;
  }

  // ─── הקבצים בכונן ─────────────────────────────────────────────────

  /// המסד המלא, קובצי העדכון הישירים, וצעדי העדכון של עד [stepsBack] גרסאות אחורה (בלי כפילויות).
  static List<DbArtifact> driveSet(DbManifest m, StepsManifest? steps) {
    final out = <DbArtifact>[m.full];
    final names = <String>{for (final x in m.full.parts) x.fileName};
    void add(DbArtifact a) {
      final n = [for (final x in a.parts) x.fileName];
      if (n.every(names.contains)) return;
      names.addAll(n);
      out.add(a);
    }

    final minVersion = m.version - stepsBack;
    final window = [
      for (final s in steps?.steps ?? const <DbArtifact>[])
        if (s.fromVersion! >= minVersion && steps!.chainFromSha(s.fromSha256!, m.full.sha256) != null) s,
    ]..sort((a, b) => b.fromVersion!.compareTo(a.fromVersion!));
    window.forEach(add);
    for (final d in m.deltas) {
      if (d.fromVersion! >= minVersion) add(d);
    }
    return out;
  }

  static int missingBytes(List<DbArtifact> list, String dir) {
    var total = 0;
    for (final a in list) {
      for (final part in a.parts) {
        final f = File(DbService.partPath(dir, part));
        if (!(f.existsSync() && f.lengthSync() == part.size)) total += part.size;
      }
    }
    return total;
  }

  /// מוחק מהכונן קובצי עדכון ישנים שיצאו מחלון הגרסאות (ההורדה עצמה מוחקת רק מה שאינו במניפסט).
  static Future<void> pruneOldPatches(String dir, List<DbArtifact> keep) async {
    final names = <String>{for (final a in keep) ...a.parts.map((x) => x.fileName)};
    try {
      await for (final e in Directory(dir).list()) {
        if (e is! File) continue;
        final n = p.basename(e.path);
        if (n.startsWith('$dbLibraryId-') && n.endsWith('.patch.zst') && !names.contains(n)) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // ─── מצב ──────────────────────────────────────────────────────────

  static bool _existsSync(String path) {
    if (path.isEmpty) return false;
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  void _ready(QuickAction a, String t, String d) {
    if (_disposed) return;
    action = a;
    title = t;
    detail = d;
    phase = QuickPhase.ready;
    QuickLog.info('מוכן: ${a.name} — $t${d.isEmpty ? '' : ' ($d)'}');
    notifyListeners();
  }

  void _done(String t, String d, {String? warning}) {
    if (_disposed) return;
    title = t;
    detail = d;
    this.warning = warning;
    phase = QuickPhase.done;
    QuickLog.info('הסתיים: $t ($d)${warning == null ? '' : ' | אזהרה: $warning'}');
    notifyListeners();
  }

  void _fail(String? text) {
    if (_disposed) return;
    if (text != null) note = text;
    phase = QuickPhase.failed;
    if (stoppedByUser) {
      QuickLog.warn('נעצר: $message');
    } else {
      QuickLog.error('נכשל: $message');
    }
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _slowTimer?.cancel();
    _tick?.cancel();
    final skip = _skip;
    if (skip != null && !skip.isCompleted) skip.complete();
    vectors?.removeListener(_onDb);
    vectors?.dispose();
    db.removeListener(_onDb);
    db.dispose();
    super.dispose();
  }
}
