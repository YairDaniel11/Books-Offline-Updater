import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// גיבוב סיסמת הנעילה: PBKDF2-HMAC-SHA256 עם מלח אקראי. פורמט: `pbkdf2$<איטרציות>$<מלח b64>$<גיבוב b64>`.
/// גיבוב ישן (SHA-256 הקסדצימלי בלי מלח, מגרסאות קודמות) עדיין מאומת, ומסומן לשדרוג.
class PasswordHash {
  PasswordHash._();

  static const defaultIterations = 60000;
  static const _legacyPrefix = 'books-offline-lock:';
  static const _tag = 'pbkdf2';

  static Uint8List pbkdf2(List<int> password, List<int> salt, int iterations, {int length = 32}) {
    final hmac = Hmac(sha256, password);
    final out = BytesBuilder();
    var block = 1;
    while (out.length < length) {
      var u = hmac.convert([...salt, block >> 24 & 255, block >> 16 & 255, block >> 8 & 255, block & 255]).bytes;
      final t = List<int>.from(u);
      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.add(t);
      block++;
    }
    return Uint8List.fromList(out.takeBytes().sublist(0, length));
  }

  static String create(String password, {int iterations = defaultIterations, Random? random}) {
    final r = random ?? Random.secure();
    final salt = Uint8List.fromList([for (var i = 0; i < 16; i++) r.nextInt(256)]);
    final h = pbkdf2(utf8.encode(password), salt, iterations);
    return [_tag, '$iterations', base64.encode(salt), base64.encode(h)].join(r'$');
  }

  static bool isLegacy(String stored) => !stored.startsWith('$_tag\$');

  static String legacy(String password) => sha256.convert(utf8.encode('$_legacyPrefix$password')).toString();

  static bool verify(String password, String stored) {
    if (isLegacy(stored)) return _constEq(utf8.encode(legacy(password)), utf8.encode(stored));
    final parts = stored.split(r'$');
    if (parts.length != 4) return false;
    final iters = int.tryParse(parts[1]);
    if (iters == null || iters < 1) return false;
    try {
      final salt = base64.decode(parts[2]);
      final expected = base64.decode(parts[3]);
      return _constEq(pbkdf2(utf8.encode(password), salt, iters, length: expected.length), expected);
    } catch (_) {
      return false;
    }
  }

  static bool _constEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }
}

/// האטה אחרי ניסיונות שגויים: מהשלישי ואילך ההמתנה מוכפלת (5, 10, 20... שניות עד 5 דקות).
/// ניסיון שמגיע בזמן המתנה נדחה בלי בדיקה (וגם לא נספר), כך שניסיונות מהירים חוזרים לא עוזרים.
class AttemptThrottle {
  AttemptThrottle({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  int failures = 0;
  DateTime? _until;

  Duration get remaining {
    final u = _until;
    if (u == null) return Duration.zero;
    final d = u.difference(_now());
    return d.isNegative ? Duration.zero : d;
  }

  bool get blocked => remaining > Duration.zero;

  void recordFailure() {
    failures++;
    if (failures >= 3) {
      final secs = min(300, 5 * (1 << min(failures - 3, 6)));
      _until = _now().add(Duration(seconds: secs));
    }
  }

  void recordSuccess() {
    failures = 0;
    _until = null;
  }
}
