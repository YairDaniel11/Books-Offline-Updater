import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:books_offline_update/src/quick/quick_window.dart';

void main() {
  test('גדלי המבנים', () {
    expect(sizeOf<FlashWInfo>(), 32);
    expect(sizeOf<ComGuid>(), 16);
  });

  test('בלי חלון - לא זורק', () {
    QuickWindow.setUp(width: 100, height: 100);
    QuickWindow.instance?.setProgress(0.5);
    QuickWindow.instance?.clearProgress();
  });
}
