import 'package:books_offline_update/src/services/hebrew_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('מרכאות וגרשיים מכל הסוגים', () {
    for (final q in ['שו"ת', 'שו״ת', "שו''ת", 'שות', 'שו”ת']) {
      expect(hebrewContains('שו״ת הרשב״א', q), isTrue, reason: q);
    }
  });

  test('ניקוד וטעמים', () {
    expect(hebrewContains('בְּרֵאשִׁית בָּרָא', 'בראשית'), isTrue);
    expect(hebrewContains('בראשית', 'בְּרֵאשִׁית'), isTrue);
  });

  test('אותיות סופיות', () {
    expect(hebrewContains('מלכים', 'מלכימ'), isTrue);
    expect(hebrewContains('מלכימ', 'מלכים'), isTrue);
    expect(normalizeHebrewForSearch('ךםןףץ'), 'כמנפצ');
  });

  test('אין התאמה כוזבת, ורווחים', () {
    expect(hebrewContains('בראשית', 'שמות'), isFalse);
    expect(hebrewContains('בראשית', '   '), isTrue);
    expect(normalizeHebrewForSearch('  א   ב '), 'א ב');
  });
}
