import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:zstandard_native/zstandard_native_bindings.dart';

import 'mapped_file.dart';

class ZstdException implements Exception {
  ZstdException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ZstdResult {
  const ZstdResult(this.size, this.sha256);
  final int size;
  final String sha256;
}

/// החלון המרבי שהפענוח מוכן לקבל. 31 הוא המקסימום בפורמט: קובץ עדכון שנדחס עם `--long=31`
/// נדחה בברירת המחדל (27).
const _maxWindowLog = 31;

/// מפענח zstd בזרימה: קורא את [sources] לפי הסדר (חלקים של אותו קובץ), כותב אל [dest],
/// ומחשב את sha256 של הפלט תוך כדי. כשמועבר [prefixPath] הוא משמש כ-"מסד בסיס" לפענוח קובץ עדכון
/// (`zstd --patch-from`). רץ ב-isolate נפרד כדי לא לתקוע את הממשק.
///
/// [onProgress] מדווח כמה בתים נקראו מהקלט הדחוס. [isCancelled] נבדק כל כמה מאות מילישניות.
Future<ZstdResult> zstdDecompressFiles(
  List<String> sources,
  String dest, {
  String? prefixPath,
  void Function(int read, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final port = ReceivePort();
  final sub = port.listen((m) {
    if (m is (int, int)) onProgress?.call(m.$1, m.$2);
  });
  // בית אחד בזיכרון נייטיבי: הדבר היחיד ששני ה-isolates יכולים לחלוק.
  final flag = malloc.allocate<Uint8>(1)..value = 0;
  final poll = Timer.periodic(const Duration(milliseconds: 200), (_) {
    if (isCancelled?.call() ?? false) flag.value = 1;
  });
  final flagAddress = flag.address;
  final send = port.sendPort;
  try {
    final r = await _runInIsolate(sources, dest, prefixPath, flagAddress, send);
    return ZstdResult(r.$1, r.$2);
  } finally {
    poll.cancel();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    port.close();
    malloc.free(flag);
  }
}

/// ה-closure נוצר כאן ולא ב-[zstdDecompressFiles] בכוונה: closure שומר את כל ההקשר שבו נוצר, ושם
/// נמצאים `onProgress`/`isCancelled` של הקורא (שמחזיקים מצב עם קבצים פתוחים, שאי אפשר לשלוח ל-isolate).
Future<(int, String)> _runInIsolate(
  List<String> sources,
  String dest,
  String? prefixPath,
  int flagAddress,
  SendPort send,
) {
  final srcCopy = List<String>.of(sources);
  return Isolate.run(() => _decompress(srcCopy, dest, prefixPath, flagAddress, send));
}

DynamicLibrary _openLibrary() {
  try {
    // לבדיקות: נתיב מפורש לספרייה (בהרצת `flutter test` הפלאגין אינו טעון).
    final override = Platform.environment['ZSTD_LIB_PATH'];
    if (override != null && override.isNotEmpty) return DynamicLibrary.open(override);
    if (Platform.isWindows) return DynamicLibrary.open('zstandard_windows.dll');
    if (Platform.isMacOS) return DynamicLibrary.open('zstandard_macos.framework/zstandard_macos');
    if (Platform.isLinux) return DynamicLibrary.open('libzstandard_linux.so');
  } catch (_) {}
  throw ZstdException('ספריית zstd אינה זמינה בפלטפורמה הזו');
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

typedef _RefPrefixC = IntPtr Function(Pointer<Void>, Pointer<Void>, IntPtr);
typedef _RefPrefixD = int Function(Pointer<Void>, Pointer<Void>, int);
typedef _SetParamC = IntPtr Function(Pointer<Void>, Int32, Int32);
typedef _SetParamD = int Function(Pointer<Void>, int, int);

/// ZSTD_d_stableOutBuffer (ZSTD_d_experimentalParam2): הפלט נכתב ישירות לחוצץ אחד קבוע שמכיל את כל
/// התוצאה, ולכן המפענח אינו מקצה חלון (עד 2GB ב-windowLog 31).
const _paramStableOutBuffer = 1001;


(int, String) _decompress(
  List<String> sources,
  String destPath,
  String? prefixPath,
  int cancelFlagAddress,
  SendPort progress,
) {
  final cancelFlag = Pointer<Uint8>.fromAddress(cancelFlagAddress);
  final library = _openLibrary();
  final zstd = ZstandardNativeBindings(library);

  String err(int code) {
    try {
      return zstd.ZSTD_getErrorName(code).cast<Utf8>().toDartString();
    } catch (_) {
      return 'code $code';
    }
  }

  final inCap = zstd.ZSTD_DStreamInSize();
  final outCap = zstd.ZSTD_DStreamOutSize();
  final dctx = zstd.ZSTD_createDCtx();
  if (dctx == nullptr) throw ZstdException('יצירת הקשר zstd נכשלה');
  final inPtr = malloc.allocate<Uint8>(inCap);
  final outPtr = malloc.allocate<Uint8>(outCap);
  final inBuf = malloc<ZSTD_inBuffer>();
  final outBuf = malloc<ZSTD_outBuffer>();
  Pointer<Uint8> prefix = nullptr;
  MappedFile? mappedPrefix;
  MappedFile? mappedOut;
  RandomAccessFile? dest;
  final digest = _DigestSink();
  final hasher = sha256.startChunkedConversion(digest);
  var hasherClosed = false;
  try {
    var total = 0;
    for (final s in sources) {
      total += File(s).lengthSync();
    }

    final init = zstd.ZSTD_initDStream(dctx);
    if (zstd.ZSTD_isError(init) != 0) throw ZstdException('אתחול zstd נכשל');
    zstd.ZSTD_DCtx_setParameter(dctx, ZSTD_dParameter.ZSTD_d_windowLogMax, _maxWindowLog);

    if (prefixPath != null) {
      // מסד הבסיס ממופה לקריאה בלבד: הדפים נתמכים בקובץ ולא תופסים זיכרון מחויב. רק אם המיפוי נכשל
      // טוענים אותו ל-RAM כבעבר.
      mappedPrefix = MappedFile.openRead(prefixPath);
      Pointer<Uint8> prefixPtr;
      int len;
      if (mappedPrefix != null) {
        prefixPtr = mappedPrefix.pointer;
        len = mappedPrefix.length;
      } else {
        final f = File(prefixPath).openSync();
        try {
          len = f.lengthSync();
          if (len == 0) throw ZstdException('מסד הבסיס ריק');
          prefix = malloc.allocate<Uint8>(len);
          const chunk = 8 * 1024 * 1024;
          var off = 0;
          while (off < len) {
            final n = len - off < chunk ? len - off : chunk;
            final view = (prefix + off).asTypedList(n);
            final got = f.readIntoSync(view, 0, n);
            if (got <= 0) throw ZstdException('קריאת מסד הבסיס נכשלה');
            off += got;
          }
        } finally {
          f.closeSync();
        }
        prefixPtr = prefix;
      }
      final ref = library.lookupFunction<_RefPrefixC, _RefPrefixD>('ZSTD_DCtx_refPrefix');
      final rc = ref(dctx.cast(), prefixPtr.cast(), len);
      if (zstd.ZSTD_isError(rc) != 0) throw ZstdException('הצמדת מסד הבסיס נכשלה: ${err(rc)}');

      // גודל התוצאה מופיע בכותרת ה-frame. אם הוא ידוע, כותבים את הפלט ישירות לקובץ ממופה בלי חלון.
      final expected = _frameContentSize(zstd, sources.first);
      if (expected != null && expected > 0) {
        mappedOut = MappedFile.createWrite(destPath, expected);
        if (mappedOut != null) {
          final setParam = library.lookupFunction<_SetParamC, _SetParamD>('ZSTD_DCtx_setParameter');
          final sc = setParam(dctx.cast(), _paramStableOutBuffer, 1);
          if (zstd.ZSTD_isError(sc) != 0) {
            mappedOut.close();
            mappedOut = null;
          }
        }
      }
    }

    if (mappedOut == null) dest = File(destPath).openSync(mode: FileMode.write);
    final inView = inPtr.asTypedList(inCap);
    final outView = outPtr.asTypedList(outCap);
    inBuf.ref.src = inPtr.cast();
    outBuf.ref.dst = mappedOut != null ? mappedOut.pointer.cast() : outPtr.cast();
    if (mappedOut != null) {
      outBuf.ref.size = mappedOut.length;
      outBuf.ref.pos = 0;
    }

    var last = 0;
    var any = false;
    var bytesRead = 0;
    var outSize = 0;
    var tick = 0;
    for (final s in sources) {
      final src = File(s).openSync();
      try {
        while (true) {
          if (cancelFlag.value != 0) throw ZstdException('הפעולה בוטלה');
          final read = src.readIntoSync(inView, 0, inCap);
          if (read == 0) break;
          any = true;
          bytesRead += read;
          if ((++tick & 63) == 0) progress.send((bytesRead, total));
          inBuf.ref.size = read;
          inBuf.ref.pos = 0;
          while (inBuf.ref.pos < inBuf.ref.size) {
            if (mappedOut == null) {
              outBuf.ref.size = outCap;
              outBuf.ref.pos = 0;
            }
            last = zstd.ZSTD_decompressStream(dctx, outBuf, inBuf);
            if (zstd.ZSTD_isError(last) != 0) throw ZstdException('פענוח zstd נכשל: ${err(last)}');
            final produced = mappedOut != null ? 0 : outBuf.ref.pos;
            if (produced > 0) {
              dest!.writeFromSync(outView, 0, produced);
              hasher.addSlice(outView, 0, produced, false);
              outSize += produced;
            }
          }
        }
      } finally {
        src.closeSync();
      }
    }
    progress.send((bytesRead, total));
    if (!any) throw ZstdException('קובץ הקלט ריק');
    // 0 = ה-frame נסגר כהלכה; אחרת הקלט נגמר באמצע (קובץ קטוע).
    if (last != 0) throw ZstdException('הקובץ הדחוס קטוע');
    if (mappedOut != null) {
      // הפלט כבר בקובץ הממופה: מוודאים שהתקבל בדיוק הגודל שהוצהר ומחשבים את ה-sha256 במקטעים.
      if (outBuf.ref.pos != mappedOut.length) throw ZstdException('הקובץ הדחוס קטוע');
      outSize = mappedOut.length;
      const chunk = 8 * 1024 * 1024;
      for (var off = 0; off < outSize; off += chunk) {
        if (cancelFlag.value != 0) throw ZstdException('הפעולה בוטלה');
        final n = outSize - off < chunk ? outSize - off : chunk;
        hasher.addSlice((mappedOut.pointer + off).asTypedList(n), 0, n, false);
      }
      mappedOut.close();
      mappedOut = null;
    } else {
      dest!.flushSync();
    }
    hasher.close();
    hasherClosed = true;
    return (outSize, digest.value.toString());
  } finally {
    if (!hasherClosed) hasher.close();
    dest?.closeSync();
    mappedOut?.close();
    mappedPrefix?.close();
    if (prefix != nullptr) malloc.free(prefix);
    malloc.free(inBuf);
    malloc.free(outBuf);
    malloc.free(inPtr);
    malloc.free(outPtr);
    zstd.ZSTD_freeDCtx(dctx);
  }
}

/// גודל התוכן המפוענח שרשום בכותרת ה-frame הראשון, או null אם אינו ידוע.
int? _frameContentSize(ZstandardNativeBindings zstd, String path) {
  final f = File(path).openSync();
  final buf = malloc.allocate<Uint8>(32);
  try {
    final n = f.readIntoSync(buf.asTypedList(32), 0, 32);
    if (n <= 0) return null;
    final r = zstd.ZSTD_getFrameContentSize(buf.cast(), n);
    // ZSTD_CONTENTSIZE_UNKNOWN = -1, ZSTD_CONTENTSIZE_ERROR = -2 (uint64 גדול כ-int חתום).
    return r < 0 ? null : r;
  } finally {
    f.closeSync();
    malloc.free(buf);
  }
}
