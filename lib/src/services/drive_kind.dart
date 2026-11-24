import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// שורש הכונן בצורה ש-`GetDriveTypeW` מקבל (`E:\`, `\\server\share\`).
String driveRootFor(String path) {
  final root = p.rootPrefix(p.absolute(path)).replaceAll('/', r'\');
  if (root.isEmpty) return '';
  return root.endsWith(r'\') ? root : '$root\\';
}

/// כונן נשלף (דיסק און קי) לפי ווינדוס (`DRIVE_REMOVABLE`); בשאר המערכות false.
/// כמו בעדכון האופליין של אוצריא: כונן כזה כותב מהר רק רצף ארוך לקובץ אחד,
/// ולכן ההורדה אליו עוברת דרך הדיסק המקומי וכותב יחיד.
bool isRemovableDrive(String path) {
  if (!Platform.isWindows) return false;
  try {
    final root = driveRootFor(path);
    if (root.isEmpty) return false;
    final getDriveType = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Uint32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('GetDriveTypeW');
    final native = root.toNativeUtf16();
    try {
      return getDriveType(native) == 2; // DRIVE_REMOVABLE
    } finally {
      malloc.free(native);
    }
  } catch (_) {
    return false;
  }
}
