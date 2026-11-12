import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// כמה בתים פנויים בכונן שבו נמצאת [path] (הנתיב עצמו לא חייב להתקיים).
/// `null` כשאי אפשר לברר: הקורא ממשיך כאילו יש מקום.
Future<int?> freeDiskSpace(String path) async {
  try {
    var dir = p.dirname(p.absolute(path));
    // עולים עד תיקייה קיימת.
    while (!Directory(dir).existsSync()) {
      final parent = p.dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
    if (Platform.isWindows) return _windowsFree(dir);
    if (Platform.isMacOS || Platform.isLinux) {
      final r = await Process.run('df', ['-k', dir]);
      if (r.exitCode != 0) return null;
      return parseDfKilobytes(r.stdout.toString());
    }
  } catch (_) {}
  return null;
}

/// מפענח פלט של `df -k`: העמודה "Available" בשורת הנתונים (עמודה 4), בקילובייטים.
int? parseDfKilobytes(String out) {
  final lines = out.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
  if (lines.length < 2) return null;
  // שורת הנתונים עלולה לעטוף כששם ההתקן ארוך: מחברים את כל מה שאחרי הכותרת.
  final cols = lines.skip(1).join(' ').trim().split(RegExp(r'\s+'));
  if (cols.length < 4) return null;
  final kb = int.tryParse(cols[3]);
  return kb == null ? null : kb * 1024;
}

typedef _GetFreeNative = Int32 Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);
typedef _GetFreeDart = int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);

int? _windowsFree(String dir) {
  final fn = DynamicLibrary.open('kernel32.dll').lookupFunction<_GetFreeNative, _GetFreeDart>('GetDiskFreeSpaceExW');
  final path = dir.toNativeUtf16();
  final avail = calloc<Uint64>();
  final total = calloc<Uint64>();
  final free = calloc<Uint64>();
  try {
    if (fn(path, avail, total, free) == 0) return null;
    return avail.value;
  } finally {
    calloc.free(path);
    calloc.free(avail);
    calloc.free(total);
    calloc.free(free);
  }
}
