import 'package:books_offline_update/src/quick/windows_registration.dart';
import 'package:flutter_test/flutter_test.dart';

/// אותו נירמול שעדכוני אוצריא עושה לשם המוצג ולרמזים (InstallLearner.normalize).
String _normalize(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

void main() {
  const exe = r'D:\app-files\OtzariaData\mirror\apps\booksofflineupdate-exe\BooksOfflineUpdate.exe';

  test('השם המוצג מכיל את הרמז שעדכוני אוצריא גוזרת משם קובץ ההתקנה', () {
    final v = WindowsRegistration.values(exePath: exe, version: '0.1.26');
    // הרמז מ-BooksOfflineUpdate.exe הוא הטוקן "booksofflineupdate" (הארוך מכולם, ולכן הוא המכריע).
    expect(_normalize(v['DisplayName']! as String), contains('booksofflineupdate'));
  });

  test('תיקיית ההתקנה היא תיקיית ה-exe המקורי, וההסרה מוחקת רק את הרישום', () {
    final v = WindowsRegistration.values(exePath: exe, version: '0.1.26');
    expect(v['InstallLocation'], r'D:\app-files\OtzariaData\mirror\apps\booksofflineupdate-exe');
    expect(v['DisplayIcon'], exe);
    expect(v['UninstallString'], '"$exe" ${WindowsRegistration.unregisterArg}');
    expect(v['DisplayVersion'], '0.1.26');
    expect(v['NoModify'], 1);
  });

  test('בלי גרסה (הרצה מהפיתוח): אין DisplayVersion ריק', () {
    expect(WindowsRegistration.values(exePath: exe, version: '').containsKey('DisplayVersion'), isFalse);
  });
}
