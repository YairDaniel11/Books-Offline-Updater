import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'net_errors.dart';
import 'repo_service.dart' show DownloadCancelled;

/// מספר החיבורים המקבילים לקובץ אחד.
const fastDownloadConnections = 6;

/// גודל מקטע: כל חיבור מוריד מקטע אחד לזיכרון, וחיבור שמסיים לוקח את המקטע הבא בתור.
/// המקטע נכתב לדיסק בכתיבה אחת גדולה - מה שדיסק און קי צריך כדי לכתוב מהר.
const fastDownloadChunk = 4 * 1024 * 1024;

/// מוחק קובץ חלקי (וקובץ מצב ישן אם נשאר מגרסת פיתוח).
Future<void> discardPartial(String dest) async {
  for (final f in [File(dest), File('$dest.chunks')]) {
    await _deleteQuiet(f);
  }
}

class _RangeUnsupported implements Exception {}

class _Aborted implements Exception {}

/// מוריד את [url] אל [dest] בכמה חיבורים מקבילים (בקשות Range), כמו מנהלי הורדות.
///
/// הכתיבה לדיסק רציפה לגמרי, לפי הסדר ובבלוקים גדולים: החיבורים מורידים מקטעים לזיכרון,
/// וכותב אחד מוסיף אותם לסוף הקובץ כשמגיע תורם. כך גם כונן נייד איטי כותב במהירות המרבית שלו,
/// והקובץ החלקי תמיד רציף - ההמשך אחרי הפסקה מתחיל פשוט מאורכו (כמו בהורדה רגילה).
/// שרת שלא תומך ב-Range: נופלים להורדה רגילה בחיבור אחד.
///
/// בסיום [dest] מכיל את הקובץ כולו (לא מאומת; האימות באחריות הקורא, ובכשל - [discardPartial]).
/// [onProgress] מקבל את מספר הבתים שכבר נכתבו לדיסק ואת הגודל הכולל (אם ידוע).
Future<void> fastDownload(
  HttpClient client,
  String url,
  String dest, {
  int? knownSize,
  required void Function(int have, int? total) onProgress,
  required bool Function() isCancelled,
  int connections = fastDownloadConnections,
  int chunkSize = fastDownloadChunk,
}) async {
  if (isCancelled()) throw DownloadCancelled();
  Future<void> single() => _single(client, url, dest, chunkSize, onProgress: onProgress, isCancelled: isCancelled);
  // כבר נמדד שחלקים לא מקצרים (או לא נתמכים, למשל דרך נטפרי): הורדה רגילה, בלי בקשות חלקים בכלל.
  if (_rangesHelp == false) return single();
  final file = File(dest);
  final size = knownSize ?? await _probeSize(client, url);
  if (size == null) return single();
  var have = await file.exists() ? await file.length() : 0;
  if (have > size) {
    await file.delete();
    have = 0;
  }
  onProgress(have, size);
  if (have == size) return;
  // קובץ קטן לא שווה פיצול כל עוד לא הוכח שזה עוזר.
  if (_rangesHelp != true && size - have < 3 * chunkSize) return single();
  try {
    await _ordered(client, url, file, have, size, chunkSize, connections, onProgress, isCancelled);
  } on _RangeUnsupported {
    _rangesHelp = false;
    await single();
  }
}

/// האם כמה חיבורים מקצרים את ההורדה ברשת הזו: null - עוד לא נמדד. נשמר עד סוף הריצה.
bool? _rangesHelp;

/// לבדיקות ולתצוגה: תוצאת המדידה (null - עוד לא נמדד).
bool? get fastDownloadRangesHelp => _rangesHelp;

/// לבדיקות: מתחילים מדידה מחדש.
void resetFastDownloadVerdict([bool? value]) => _rangesHelp = value;

/// משך המדידה בחיבור אחד, ואחריה בכמה חיבורים.
const _measureSolo = Duration(seconds: 3);
const _measureMulti = Duration(seconds: 4);

/// כמה חיבורים צריכים להיות מהירים מחיבור אחד כדי שישתלמו.
const _minGain = 1.3;

/// בודק את גודל הקובץ ואם השרת תומך ב-Range. מחזיר null כשאין תמיכה (או שהגודל לא ידוע).
Future<int?> _probeSize(HttpClient client, String url) async {
  final req = await client.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
  final res = await req.close().timeout(const Duration(seconds: 30));
  await ensureOk(res, ok: const {200, 206});
  if (res.statusCode != 206) {
    // השרת (או המסנן) שולח את כל הקובץ: אין חלקים. סוגרים את החיבור בלי לקרוא אותו.
    _rangesHelp = false;
    await res.listen(null).cancel();
    return null;
  }
  await res.drain<void>();
  final m = RegExp(r'/(\d+)\s*$').firstMatch(res.headers.value(HttpHeaders.contentRangeHeader) ?? '');
  return m == null ? null : int.parse(m.group(1)!);
}

Future<void> _ordered(
  HttpClient client,
  String url,
  File file,
  int have,
  int size,
  int chunkSize,
  int connections,
  void Function(int have, int? total) onProgress,
  bool Function() isCancelled,
) async {
  final starts = [for (var o = have; o < size; o += chunkSize) o];
  int endOf(int i) => math.min(starts[i] + chunkSize, size) - 1;
  // כמה מקטעים מותר להקדים את הכתיבה: חוסם את הזיכרון (בערך (חיבורים+2) × גודל מקטע).
  final window = connections + 2;
  final ready = <int, Uint8List>{};
  var nextFetch = 0;
  var nextWrite = 0;
  var abort = false;
  Object? firstError;

  var tick = Completer<void>();
  void notify() {
    final t = tick;
    tick = Completer<void>();
    t.complete();
  }

  void fail(Object e) {
    if (!abort) {
      abort = true;
      firstError = e;
    }
    notify();
  }

  // מדידה: קודם חיבור אחד, אחר כך כולם. ממשיכים בכמה חיבורים רק אם זה באמת מהיר יותר.
  var decided = _rangesHelp != null;
  var allowed = _rangesHelp == true ? connections : 1;
  final clock = Stopwatch()..start();
  var received = 0;
  int? phaseStart;
  var phaseBytes = 0;
  var soloRate = 0.0;
  var multi = false;
  void observe(int n) {
    received += n;
    if (decided) return;
    final now = clock.elapsedMicroseconds;
    if (phaseStart == null) {
      // השעון מתחיל עם הבתים הראשונים, בלי זמן ההתחברות.
      phaseStart = now;
      phaseBytes = received;
      return;
    }
    final elapsed = now - phaseStart!;
    if (!multi && elapsed >= _measureSolo.inMicroseconds) {
      soloRate = (received - phaseBytes) / elapsed;
      multi = true;
      allowed = connections;
      phaseStart = now;
      phaseBytes = received;
      notify();
    } else if (multi && elapsed >= _measureMulti.inMicroseconds) {
      final multiRate = (received - phaseBytes) / elapsed;
      decided = true;
      _rangesHelp = multiRate >= soloRate * _minGain;
      if (_rangesHelp == false) allowed = 1;
      notify();
    }
  }

  Future<Uint8List> fetchChunk(int i) async {
    final start = starts[i];
    final end = endOf(i);
    final buf = BytesBuilder(copy: false);
    Object? last;
    for (var attempt = 0; attempt < 5; attempt++) {
      if (abort) throw _Aborted();
      if (isCancelled()) throw DownloadCancelled();
      try {
        final from = start + buf.length;
        final req = await client.getUrl(Uri.parse(url));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$end');
        final res = await req.close().timeout(const Duration(seconds: 30));
        await ensureOk(res, ok: const {200, 206});
        if (!isExactContinuation(res, from)) {
          await res.listen(null).cancel();
          throw _RangeUnsupported();
        }
        await for (final c in res.timeout(const Duration(seconds: 30))) {
          if (abort) throw _Aborted();
          if (isCancelled()) throw DownloadCancelled();
          final take = math.min(c.length, end - start + 1 - buf.length);
          if (take <= 0) break;
          buf.add(take == c.length ? c : c.sublist(0, take));
          observe(take);
        }
        if (buf.length < end - start + 1) throw const HttpException('החיבור נסגר לפני סוף המקטע');
        return buf.takeBytes();
      } on DownloadCancelled {
        rethrow;
      } on _Aborted {
        rethrow;
      } on _RangeUnsupported {
        rethrow;
      } catch (e) {
        last = e;
        if (isFinalNetFailure(e)) break;
        await Future<void>.delayed(Duration(milliseconds: 700 * (attempt + 1)));
      }
    }
    throw last!;
  }

  Future<void> worker(int id) async {
    try {
      while (!abort && nextFetch < starts.length) {
        if (id >= allowed) {
          if (decided) return; // הוחלט שחיבור אחד מספיק: החיבורים הנוספים נסגרים אחרי המקטע שלהם
          await tick.future;
          continue;
        }
        if (nextFetch >= nextWrite + window) {
          await tick.future;
          continue;
        }
        final i = nextFetch++;
        ready[i] = await fetchChunk(i);
        notify();
      }
    } on _Aborted {
      // חיבור אחר כבר נכשל
    } catch (e) {
      fail(e);
    }
  }

  // FileMode.append: הכתיבה מתחילה בסוף הקובץ החלקי ([have]).
  final raf = await file.open(mode: FileMode.append);
  Future<void> writer() async {
    try {
      while (!abort && nextWrite < starts.length) {
        final b = ready.remove(nextWrite);
        if (b == null) {
          await tick.future;
          continue;
        }
        await raf.writeFrom(b);
        have += b.length;
        nextWrite++;
        onProgress(have, size);
        notify();
        if (isCancelled()) throw DownloadCancelled();
      }
    } catch (e) {
      fail(e);
    }
  }

  try {
    await Future.wait([
      writer(),
      for (var i = 0; i < math.min(connections, starts.length); i++) worker(i),
    ]);
  } finally {
    await raf.close();
  }
  if (firstError != null) throw firstError!;
}

/// הורדה רגילה בחיבור אחד, עם המשכה מסוף הקובץ החלקי. גם כאן הכתיבה בבלוקים גדולים.
Future<void> _single(
  HttpClient client,
  String url,
  String dest,
  int blockSize, {
  required void Function(int have, int? total) onProgress,
  required bool Function() isCancelled,
}) async {
  final file = File(dest);
  var have = await file.exists() ? await file.length() : 0;
  final req = await client.getUrl(Uri.parse(url));
  if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
  final res = await req.close().timeout(const Duration(seconds: 30));
  if (res.statusCode == 416) {
    await res.drain<void>(); // כבר הורד במלואו
    return;
  }
  await ensureOk(res, ok: const {200, 206});
  if (have > 0 && !isExactContinuation(res, have)) have = 0;
  final total = res.contentLength >= 0 ? res.contentLength + have : null;
  final raf = await file.open(mode: have > 0 ? FileMode.append : FileMode.write);
  final buf = BytesBuilder(copy: false);
  Future<void> spill() async {
    if (buf.isEmpty) return;
    final n = buf.length;
    await raf.writeFrom(buf.takeBytes());
    have += n;
    onProgress(have, total);
  }

  try {
    await for (final c in res.timeout(const Duration(seconds: 30))) {
      if (isCancelled()) throw DownloadCancelled();
      buf.add(c);
      if (buf.length >= blockSize) await spill();
    }
  } finally {
    // מה שהתקבל רציף ותקין: נשמר גם בביטול או בניתוק, כדי שההמשך יתחיל ממנו.
    try {
      await spill();
    } finally {
      await raf.close();
    }
  }
}


Future<void> _deleteQuiet(File f) async {
  try {
    if (await f.exists()) await f.delete();
  } catch (_) {}
}
