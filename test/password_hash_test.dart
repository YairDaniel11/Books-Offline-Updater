import 'package:books_offline_update/src/services/password_hash.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('גיבוב חדש עם מלח: מאמת נכון, דוחה שגוי, ושני גיבובים שונים', () {
    final a = PasswordHash.create('סיסמה', iterations: 1000);
    final b = PasswordHash.create('סיסמה', iterations: 1000);
    expect(a, isNot(b));
    expect(PasswordHash.isLegacy(a), isFalse);
    expect(PasswordHash.verify('סיסמה', a), isTrue);
    expect(PasswordHash.verify('אחרת', a), isFalse);
  });

  test('גיבוב ישן מגרסאות קודמות עדיין מאומת וזוהה כישן', () {
    final old = PasswordHash.legacy('abc');
    expect(PasswordHash.isLegacy(old), isTrue);
    expect(PasswordHash.verify('abc', old), isTrue);
    expect(PasswordHash.verify('abd', old), isFalse);
  });

  test('PBKDF2 מול וקטור ידוע', () {
    // PBKDF2-HMAC-SHA256, password="password", salt="salt", c=1, dkLen=32
    final h = PasswordHash.pbkdf2('password'.codeUnits, 'salt'.codeUnits, 1);
    expect(h.map((e) => e.toRadixString(16).padLeft(2, '0')).join(),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
  });

  test('ערך פגום לא מקריס', () {
    expect(PasswordHash.verify('x', r'pbkdf2$zz$!!$!!'), isFalse);
    expect(PasswordHash.verify('x', r'pbkdf2$1'), isFalse);
  });

  test('האטה: אחרי 3 כשלונות נחסם וגדל', () {
    var t = DateTime(2025);
    final th = AttemptThrottle(now: () => t);
    th.recordFailure();
    th.recordFailure();
    expect(th.blocked, isFalse);
    th.recordFailure();
    expect(th.blocked, isTrue);
    expect(th.remaining.inSeconds, 5);
    t = t.add(const Duration(seconds: 6));
    expect(th.blocked, isFalse);
    th.recordFailure();
    expect(th.remaining.inSeconds, 10);
    th.recordSuccess();
    expect(th.blocked, isFalse);
  });

  test('ברירת המחדל של האיטרציות מהירה מספיק', () {
    final sw = Stopwatch()..start();
    PasswordHash.create('x');
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });
}
