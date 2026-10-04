import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// נתיב קובץ ההרצה של תהליך האב (Windows בלבד), או `null` אם לא ניתן לקבוע.
///
/// כשהתוכנה נארזה כ-exe יחיד (SFX), היא מחולצת לתיקייה זמנית ורצה משם; תהליך האב שלה
/// הוא קובץ ה-exe המקורי, ולכן ליד *הוא* צריך לשבת ה-PAK.
String? windowsParentExecutable() {
  if (!Platform.isWindows) return null;
  try {
    final k = DynamicLibrary.open('kernel32.dll');
    final getPid = k.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
    final snapshot = k.lookupFunction<IntPtr Function(Uint32, Uint32), int Function(int, int)>('CreateToolhelp32Snapshot');
    final first = k.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('Process32FirstW');
    final next = k.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('Process32NextW');
    final openProc = k.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>('OpenProcess');
    final query = k.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>),
        int Function(int, int, Pointer<Utf16>, Pointer<Uint32>)>('QueryFullProcessImageNameW');
    final closeH = k.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

    const entrySize = 568; // PROCESSENTRY32W ב-64 ביט
    final me = getPid();
    final snap = snapshot(0x2 /* TH32CS_SNAPPROCESS */, 0);
    if (snap == -1) return null;
    final entry = calloc<Uint8>(entrySize);
    try {
      entry.cast<Uint32>().value = entrySize;
      var parent = 0;
      var ok = first(snap, entry);
      while (ok != 0) {
        final words = entry.cast<Uint32>();
        if (words[2] == me) {
          parent = words[8]; // th32ParentProcessID בהיסט 32
          break;
        }
        ok = next(snap, entry);
      }
      if (parent == 0) return null;
      final h = openProc(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */, 0, parent);
      if (h == 0) return null;
      final buf = calloc<Uint16>(1024).cast<Utf16>();
      final len = calloc<Uint32>()..value = 1024;
      try {
        if (query(h, 0, buf, len) == 0) return null;
        return buf.toDartString(length: len.value);
      } finally {
        calloc.free(buf);
        calloc.free(len);
        closeH(h);
      }
    } finally {
      calloc.free(entry);
      closeH(snap);
    }
  } catch (_) {
    return null;
  }
}
