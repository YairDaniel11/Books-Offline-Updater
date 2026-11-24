/// מהירות וזמן משוער לפעולה ארוכה, לפי דגימות של (זמן, בתים שהושלמו).
///
/// המהירות מחושבת על חלון של השניות האחרונות, כך שהיא מגיבה לשינויים בלי לקפוץ בכל דגימה.
/// שינוי בכותרת הפעולה, בגודל הכולל, או ירידה במונה (למשל מעבר לבדיקת תקינות) — מתחילים מחדש.
class ProgressRate {
  ProgressRate({DateTime Function()? clock, this.window = const Duration(seconds: 8)})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// על כמה זמן אחורה מחשבים את המהירות.
  final Duration window;

  /// כמה זמן מדידה לפחות לפני שמציגים הערכה (בהתחלה המהירות עוד לא יציבה).
  static const warmUp = Duration(seconds: 2);

  final List<(DateTime, int)> _samples = [];
  String? _key;
  int? _total;

  void reset() {
    _samples.clear();
    _key = null;
    _total = null;
  }

  /// דגימה חדשה. [key]: מזהה השלב (למשל כותרת הפעולה).
  void add(String key, int done, int? total) {
    final now = _clock();
    if (key != _key || total != _total || (_samples.isNotEmpty && done < _samples.last.$2)) {
      _samples.clear();
      _key = key;
      _total = total;
    }
    if (_samples.isNotEmpty && _samples.last.$2 == done && now.difference(_samples.last.$1) < const Duration(milliseconds: 250)) {
      return;
    }
    _samples.add((now, done));
    // שומרים דגימה אחת מחוץ לחלון, כדי שהחלון יהיה מלא.
    while (_samples.length > 2 && now.difference(_samples[1].$1) > window) {
      _samples.removeAt(0);
    }
  }

  /// כמה זמן בלי התקדמות עד שההערכה כבר לא נחשבת עדכנית (הורדה תקועה).
  static const staleAfter = Duration(seconds: 5);

  /// בתים לשנייה, או `null` כשעוד אין מספיק מדידה, או כשההתקדמות נעצרה.
  double? get bytesPerSecond {
    if (_samples.length < 2) return null;
    if (_clock().difference(_samples.last.$1) > staleAfter) return null;
    final first = _samples.first, last = _samples.last;
    final span = last.$1.difference(first.$1);
    if (span < warmUp) return null;
    final bytes = last.$2 - first.$2;
    if (bytes <= 0) return 0;
    return bytes * 1000 / span.inMilliseconds;
  }

  /// הזמן שנותר, או `null` כשאין הערכה סבירה.
  Duration? get remaining {
    final speed = bytesPerSecond;
    final total = _total;
    if (speed == null || speed <= 0 || total == null || _samples.isEmpty) return null;
    final left = total - _samples.last.$2;
    if (left <= 0) return Duration.zero;
    final secs = left / speed;
    if (secs > 99 * 3600) return null;
    return Duration(seconds: secs.ceil());
  }

  /// "עוד כ-3 דק'" וכדומה.
  static String formatRemaining(Duration d) {
    final s = d.inSeconds;
    if (s < 60) return 'פחות מדקה';
    final totalMin = (s / 60).ceil();
    if (totalMin < 60) return totalMin == 1 ? 'עוד כדקה' : "עוד כ-$totalMin דק'";
    final h = totalMin ~/ 60, m = totalMin % 60;
    final hours = h == 1 ? 'כשעה' : (h == 2 ? 'כשעתיים' : "כ-$h שע'");
    return m == 0 ? 'עוד $hours' : "עוד $hours ו-$m דק'";
  }
}
