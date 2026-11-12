import 'dart:async';
import 'dart:io';

/// סוגי כשלי רשת שמוצגים למשתמש בעברית ברורה.
enum NetErrorKind { offline, blocked, rateLimit, busy, other }

/// כשל רשת מסווג. ההודעה מוכנה להצגה.
class NetFailure implements Exception {
  NetFailure(this.kind, this.message);
  final NetErrorKind kind;
  final String message;
  @override
  String toString() => message;
}

const _msgOffline = 'אין חיבור לאינטרנט. בדקו את החיבור ונסו שוב.';
const _msgBlocked = 'האתר נראה חסום, כנראה על ידי מסנן אינטרנט. אפשר לבקש ממנהל המסנן לפתוח את github.com '
    'ואת raw.githubusercontent.com, ולנסות שוב. מה שכבר הורד נשמר.';
const _msgRate = 'גיטהאב הגביל זמנית את מספר הבקשות. נסו שוב בעוד כמה דקות.';
const _msgBusy = 'השרת עמוס או לא זמין כרגע. נסו שוב בעוד כמה דקות.';

/// מסווג תגובת HTTP שאינה הצלחה (או עמוד HTML שהגיע במקום קובץ).
NetFailure classifyHttp(int status, {String? contentType, String? rateLimitRemaining, bool htmlInstead = false}) {
  if (htmlInstead) return NetFailure(NetErrorKind.blocked, _msgBlocked);
  if (status == 429 || (status == 403 && rateLimitRemaining == '0')) {
    return NetFailure(NetErrorKind.rateLimit, _msgRate);
  }
  if (status == 403 || status == 451 || status == 407) return NetFailure(NetErrorKind.blocked, _msgBlocked);
  if (status == 408 || status >= 500) return NetFailure(NetErrorKind.busy, _msgBusy);
  return NetFailure(NetErrorKind.other, 'שגיאת שרת $status');
}

/// האם התגובה היא עמוד HTML (סימן אופייני לעמוד חסימה של מסנן) ולא הקובץ שביקשנו.
bool looksLikeHtml(HttpClientResponse res) {
  final ct = res.headers.contentType;
  return ct != null && (ct.mimeType == 'text/html' || ct.mimeType == 'application/xhtml+xml');
}

/// בודק תגובה של בקשה שמצפה לקובץ לא-HTML. זורק [NetFailure] מתאים אם אינה תקינה.
/// קורא גם את גוף התגובה כדי שהחיבור ישתחרר.
Future<void> ensureOk(HttpClientResponse res, {Set<int> ok = const {200}, bool expectNonHtml = true}) async {
  final html = expectNonHtml && looksLikeHtml(res);
  if (!ok.contains(res.statusCode) || html) {
    await res.drain<void>().catchError((_) {});
    throw classifyHttp(
      res.statusCode,
      rateLimitRemaining: res.headers.value('x-ratelimit-remaining'),
      htmlInstead: html && ok.contains(res.statusCode),
    );
  }
}

/// הודעה ידידותית לכל חריגה שעלולה לצוץ בבקשת רשת.
String friendlyNetError(Object e) {
  if (e is NetFailure) return e.message;
  if (e is SocketException || e is HandshakeException || e is TlsException) {
    // חיבור TLS שנכשל בדרך כלל מעיד על מסנן שמתערב.
    return e is SocketException ? _msgOffline : _msgBlocked;
  }
  if (e is TimeoutException) return 'השרת לא הגיב בזמן. בדקו את החיבור ונסו שוב.';
  if (e is HttpException) return _msgBusy;
  return '$e';
}

/// מחזיר את סוג הכשל לצורך החלטות (למשל אם כדאי לנסות שוב).
NetErrorKind kindOf(Object e) {
  if (e is NetFailure) return e.kind;
  if (e is SocketException) return NetErrorKind.offline;
  if (e is HandshakeException || e is TlsException) return NetErrorKind.blocked;
  if (e is TimeoutException) return NetErrorKind.busy;
  return NetErrorKind.other;
}

/// מפרש כותרת Content-Range ("bytes 100-199/200"). מחזיר את נקודת ההתחלה, או null אם אינה תקינה.
int? contentRangeStart(String? header) {
  if (header == null) return null;
  final m = RegExp(r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$', caseSensitive: false).firstMatch(header);
  return m == null ? null : int.parse(m.group(1)!);
}

/// האם תגובת 206 היא בדיוק ההמשך שביקשנו מהבית [have].
bool isExactContinuation(HttpClientResponse res, int have) =>
    res.statusCode == 206 && contentRangeStart(res.headers.value(HttpHeaders.contentRangeHeader)) == have;

/// כשל שאין טעם לנסות שוב מיד (חסימה, הגבלת קצב).
bool isFinalNetFailure(Object e) {
  final k = kindOf(e);
  return k == NetErrorKind.blocked || k == NetErrorKind.rateLimit;
}
