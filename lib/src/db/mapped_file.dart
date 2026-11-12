import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// קובץ ממופה לזיכרון (memory map). הדפים נתמכים בקובץ עצמו ולא בזיכרון "מחויב" (commit): מערכת
/// ההפעלה טוענת ומפנה אותם לפי הצורך, כך שגם קובץ של כמה ג'יגה אינו דורש כמה ג'יגה של RAM פנוי.
/// מחזיר null מ-[open] אם המיפוי אינו נתמך או נכשל, והקורא חוזר לדרך הרגילה.
class MappedFile {
  MappedFile._(this.address, this.length, this._close);

  /// כתובת תחילת המיפוי.
  final int address;
  final int length;
  final void Function() _close;
  bool _closed = false;

  Pointer<Uint8> get pointer => Pointer<Uint8>.fromAddress(address);

  /// כותב לדיסק את הדפים ששונו (רלוונטי רק למיפוי לכתיבה).
  void close() {
    if (_closed) return;
    _closed = true;
    _close();
  }

  /// ממפה קובץ קיים לקריאה בלבד.
  static MappedFile? openRead(String path) {
    try {
      final len = File(path).lengthSync();
      if (len <= 0) return null;
      if (Platform.isWindows) return _winMap(path, len, write: false);
      if (Platform.isMacOS || Platform.isLinux) return _posixMap(path, len, write: false);
    } catch (_) {}
    return null;
  }

  /// יוצר (או מאפס) קובץ בגודל [length] וממפה אותו לכתיבה.
  static MappedFile? createWrite(String path, int length) {
    try {
      if (length <= 0) return null;
      if (Platform.isWindows) return _winMap(path, length, write: true);
      if (Platform.isMacOS || Platform.isLinux) {
        final f = File(path).openSync(mode: FileMode.write);
        try {
          f.truncateSync(length);
        } finally {
          f.closeSync();
        }
        return _posixMap(path, length, write: true);
      }
    } catch (_) {}
    return null;
  }
}

// ---------------- Windows ----------------

typedef _CreateFileC = IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr);
typedef _CreateFileD = int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);
typedef _CreateMappingC = IntPtr Function(IntPtr, Pointer<Void>, Uint32, Uint32, Uint32, Pointer<Utf16>);
typedef _CreateMappingD = int Function(int, Pointer<Void>, int, int, int, Pointer<Utf16>);
typedef _MapViewC = IntPtr Function(IntPtr, Uint32, Uint32, Uint32, IntPtr);
typedef _MapViewD = int Function(int, int, int, int, int);
typedef _PtrBoolC = Int32 Function(IntPtr);
typedef _PtrBoolD = int Function(int);
typedef _FlushViewC = Int32 Function(IntPtr, IntPtr);
typedef _FlushViewD = int Function(int, int);

MappedFile? _winMap(String path, int length, {required bool write}) {
  final k = DynamicLibrary.open('kernel32.dll');
  final createFile = k.lookupFunction<_CreateFileC, _CreateFileD>('CreateFileW');
  final createMapping = k.lookupFunction<_CreateMappingC, _CreateMappingD>('CreateFileMappingW');
  final mapView = k.lookupFunction<_MapViewC, _MapViewD>('MapViewOfFile');
  final unmap = k.lookupFunction<_PtrBoolC, _PtrBoolD>('UnmapViewOfFile');
  final closeHandle = k.lookupFunction<_PtrBoolC, _PtrBoolD>('CloseHandle');
  final flushView = k.lookupFunction<_FlushViewC, _FlushViewD>('FlushViewOfFile');

  const genericRead = 0x80000000, genericWrite = 0x40000000;
  const shareReadWrite = 0x1 | 0x2;
  const createAlways = 2, openExisting = 3;
  const pageReadonly = 0x02, pageReadwrite = 0x04;
  const fileMapRead = 0x4, fileMapWrite = 0x2;
  final invalid = -1; // INVALID_HANDLE_VALUE

  final wpath = path.toNativeUtf16();
  int file = invalid, mapping = 0, view = 0;
  try {
    file = createFile(
      wpath,
      write ? (genericRead | genericWrite) : genericRead,
      shareReadWrite,
      nullptr,
      write ? createAlways : openExisting,
      0x80, // FILE_ATTRIBUTE_NORMAL
      0,
    );
    if (file == invalid || file == 0) return null;
    mapping = createMapping(
      file,
      nullptr,
      write ? pageReadwrite : pageReadonly,
      write ? (length >> 32) & 0xFFFFFFFF : 0,
      write ? length & 0xFFFFFFFF : 0,
      nullptr,
    );
    if (mapping == 0) {
      closeHandle(file);
      return null;
    }
    view = mapView(mapping, write ? fileMapWrite : fileMapRead, 0, 0, 0);
    if (view == 0) {
      closeHandle(mapping);
      closeHandle(file);
      return null;
    }
    final f = file, m = mapping, v = view;
    return MappedFile._(v, length, () {
      if (write) flushView(v, 0);
      unmap(v);
      closeHandle(m);
      closeHandle(f);
    });
  } finally {
    malloc.free(wpath);
  }
}

// ---------------- macOS / Linux ----------------

typedef _OpenC = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenD = int Function(Pointer<Utf8>, int);
typedef _MmapC = IntPtr Function(IntPtr, IntPtr, Int32, Int32, Int32, Int64);
typedef _MmapD = int Function(int, int, int, int, int, int);
typedef _MunmapC = Int32 Function(IntPtr, IntPtr);
typedef _MunmapD = int Function(int, int);
typedef _MsyncC = Int32 Function(IntPtr, IntPtr, Int32);
typedef _MsyncD = int Function(int, int, int);
typedef _CloseC = Int32 Function(Int32);
typedef _CloseD = int Function(int);

MappedFile? _posixMap(String path, int length, {required bool write}) {
  final c = DynamicLibrary.process();
  final open = c.lookupFunction<_OpenC, _OpenD>('open');
  final mmap = c.lookupFunction<_MmapC, _MmapD>('mmap');
  final munmap = c.lookupFunction<_MunmapC, _MunmapD>('munmap');
  final msync = c.lookupFunction<_MsyncC, _MsyncD>('msync');
  final close = c.lookupFunction<_CloseC, _CloseD>('close');

  const oRdonly = 0, oRdwr = 2;
  const protRead = 1, protWrite = 2, mapShared = 1;
  const msSync = 0x10; // Linux: MS_SYNC=4, macOS: MS_SYNC=0x10
  final sync = Platform.isLinux ? 4 : msSync;

  final cpath = path.toNativeUtf8();
  try {
    final fd = open(cpath, write ? oRdwr : oRdonly);
    if (fd < 0) return null;
    final addr = mmap(0, length, write ? (protRead | protWrite) : protRead, mapShared, fd, 0);
    close(fd); // המיפוי נשאר תקף גם אחרי סגירת ה-fd
    if (addr == -1 || addr == 0) return null;
    return MappedFile._(addr, length, () {
      if (write) msync(addr, length, sync);
      munmap(addr, length);
    });
  } finally {
    malloc.free(cpath);
  }
}
