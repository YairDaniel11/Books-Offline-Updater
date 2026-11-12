/// נורמליזציה לחיפוש בעברית: מתעלמת מניקוד וטעמים, מאותיות סופיות ומסוגי גרש/גרשיים.
/// כך "שו"ת", "שו״ת", "שו''ת" ו"שות" מתאימים זה לזה.
String normalizeHebrewForSearch(String input) {
  final b = StringBuffer();
  for (final r in input.runes) {
    if (_skipped(r)) continue;
    final f = _finals[r];
    b.writeCharCode(f ?? r);
  }
  return b.toString().toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// האם [text] מכיל את [query] אחרי נורמליזציה של שניהם.
bool hebrewContains(String text, String query) {
  final q = normalizeHebrewForSearch(query);
  return q.isEmpty || normalizeHebrewForSearch(text).contains(q);
}

const _finals = <int, int>{
        0x05DA: 0x05DB, // ך
        0x05DD: 0x05DE, // ם
        0x05DF: 0x05E0, // ן
        0x05E3: 0x05E4, // ף
        0x05E5: 0x05E6, // ץ
      };

bool _skipped(int r) {
  // טעמים וניקוד, כולל נקודת שין/שמאל, רפה ודגש.
  if ((r >= 0x0591 && r <= 0x05BD) || r == 0x05BF || r == 0x05C1 || r == 0x05C2) return true;
  if (r == 0x05C4 || r == 0x05C5 || r == 0x05C7) return true;
  switch (r) {
    case 0x22: // "
    case 0x27: // '
    case 0x60: // `
    case 0xB4: // ´
    case 0x5F3: // ׳
    case 0x5F4: // ״
    case 0x2018:
    case 0x2019:
    case 0x201A:
    case 0x201B:
    case 0x201C:
    case 0x201D:
    case 0x201E:
    case 0x201F:
    case 0x2032:
    case 0x2033:
    case 0x200E: // סימוני כיוון
    case 0x200F:
      return true;
  }
  return false;
}
