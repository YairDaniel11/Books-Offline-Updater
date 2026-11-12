import 'dart:async';
import 'dart:convert' show ByteConversionSink;
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:ffi/ffi.dart';

import 'repo_service.dart' show DownloadCancelled;

/// SHA-256 מהיר: ב-Windows דרך CNG (bcrypt.dll) וב-macOS דרך CommonCrypto, שניהם עם האצת חומרה.
/// אם הטעינה נכשלת (או בפלטפורמה אחרת) נופלים אוטומטית ל-package:crypto.
abstract class Sha256Hasher {
  /// מחזיר hasher נייטיבי אם אפשר, אחרת hasher ב-Dart.
  factory Sha256Hasher() {
    try {
      if (Platform.isWindows) return _CngHasher();
      if (Platform.isMacOS) return _CommonCryptoHasher();
    } catch (_) {}
    return _DartHasher();
  }

  /// hasher ב-Dart בלבד (לבדיקות והשוואה).
  factory Sha256Hasher.dart() = _DartHasher;

  bool get isNative;

  /// מוסיף [length] בתים מזיכרון נייטיבי (בלי העתקה).
  void addPointer(Pointer<Uint8> data, int length);

  void addBytes(Uint8List data);

  /// מסיים ומחזיר hex באותיות קטנות. אחרי הקריאה אי אפשר להמשיך.
  String close();

  /// משחרר משאבים בלי לסיים (למקרה של שגיאה). בטוח לקרוא גם אחרי [close].
  void dispose();
}

const _chunk = 4 * 1024 * 1024;

String _hex(Pointer<Uint8> p, int n) {
  final b = p.asTypedList(n);
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

class _Sink implements Sink<dart_crypto.Digest> {
  dart_crypto.Digest? value;
  @override
  void add(dart_crypto.Digest data) => value = data;
  @override
  void close() {}
}

class _DartHasher implements Sha256Hasher {
  _DartHasher() {
    _conv = dart_crypto.sha256.startChunkedConversion(_sink);
  }
  final _sink = _Sink();
  late final ByteConversionSink _conv;
  bool _closed = false;

  @override
  bool get isNative => false;

  @override
  void addPointer(Pointer<Uint8> data, int length) => _conv.addSlice(data.asTypedList(length), 0, length, false);

  @override
  void addBytes(Uint8List data) => _conv.add(data);

  @override
  String close() {
    _closed = true;
    _conv.close();
    return _sink.value.toString();
  }

  @override
  void dispose() {
    if (!_closed) {
      _closed = true;
      _conv.close();
    }
  }
}

// ---------- Windows CNG ----------

typedef _OpenC = Int32 Function(Pointer<Pointer<Void>>, Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _OpenD = int Function(Pointer<Pointer<Void>>, Pointer<Utf16>, Pointer<Utf16>, int);
typedef _GetPropC = Int32 Function(Pointer<Void>, Pointer<Utf16>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Uint32);
typedef _GetPropD = int Function(Pointer<Void>, Pointer<Utf16>, Pointer<Uint8>, int, Pointer<Uint32>, int);
typedef _CreateC = Int32 Function(
    Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32, Uint32);
typedef _CreateD = int Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Uint8>, int, Pointer<Uint8>, int, int);
typedef _DataC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Uint32);
typedef _DataD = int Function(Pointer<Void>, Pointer<Uint8>, int, int);
typedef _DestroyC = Int32 Function(Pointer<Void>);
typedef _DestroyD = int Function(Pointer<Void>);
typedef _CloseC = Int32 Function(Pointer<Void>, Uint32);
typedef _CloseD = int Function(Pointer<Void>, int);

class _Cng {
  _Cng() {
    final lib = DynamicLibrary.open('bcrypt.dll');
    open = lib.lookupFunction<_OpenC, _OpenD>('BCryptOpenAlgorithmProvider');
    getProp = lib.lookupFunction<_GetPropC, _GetPropD>('BCryptGetProperty');
    create = lib.lookupFunction<_CreateC, _CreateD>('BCryptCreateHash');
    data = lib.lookupFunction<_DataC, _DataD>('BCryptHashData');
    finish = lib.lookupFunction<_DataC, _DataD>('BCryptFinishHash');
    destroy = lib.lookupFunction<_DestroyC, _DestroyD>('BCryptDestroyHash');
    closeAlg = lib.lookupFunction<_CloseC, _CloseD>('BCryptCloseAlgorithmProvider');
  }
  late final _OpenD open;
  late final _GetPropD getProp;
  late final _CreateD create;
  late final _DataD data;
  late final _DataD finish;
  late final _DestroyD destroy;
  late final _CloseD closeAlg;
}

_Cng? _cngCache;

class _CngHasher implements Sha256Hasher {
  _CngHasher() : _api = (_cngCache ??= _Cng()) {
    final pAlg = calloc<Pointer<Void>>();
    final name = 'SHA256'.toNativeUtf16();
    final objLenName = 'ObjectLength'.toNativeUtf16();
    final pLen = calloc<Uint32>();
    final pRes = calloc<Uint32>();
    final pHash = calloc<Pointer<Void>>();
    try {
      _check(_api.open(pAlg, name, nullptr, 0), 'open');
      _alg = pAlg.value;
      _check(_api.getProp(_alg, objLenName, pLen.cast(), 4, pRes, 0), 'prop');
      _obj = malloc.allocate<Uint8>(pLen.value);
      _check(_api.create(_alg, pHash, _obj, pLen.value, nullptr, 0, 0), 'create');
      _hash = pHash.value;
    } catch (_) {
      dispose();
      rethrow;
    } finally {
      calloc.free(pAlg);
      calloc.free(name);
      calloc.free(objLenName);
      calloc.free(pLen);
      calloc.free(pRes);
      calloc.free(pHash);
    }
  }

  final _Cng _api;
  Pointer<Void> _alg = nullptr;
  Pointer<Void> _hash = nullptr;
  Pointer<Uint8> _obj = nullptr;
  bool _done = false;

  static void _check(int status, String what) {
    if (status != 0) throw StateError('CNG $what נכשל: 0x${(status & 0xFFFFFFFF).toRadixString(16)}');
  }

  @override
  bool get isNative => true;

  @override
  void addPointer(Pointer<Uint8> data, int length) {
    var off = 0;
    while (off < length) {
      final n = length - off < _chunk ? length - off : _chunk;
      _check(_api.data(_hash, data + off, n, 0), 'hash');
      off += n;
    }
  }

  @override
  void addBytes(Uint8List data) {
    final buf = malloc.allocate<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      addPointer(buf, data.length);
    } finally {
      malloc.free(buf);
    }
  }

  @override
  String close() {
    final out = malloc.allocate<Uint8>(32);
    try {
      _check(_api.finish(_hash, out, 32, 0), 'finish');
      return _hex(out, 32);
    } finally {
      malloc.free(out);
      dispose();
    }
  }

  @override
  void dispose() {
    if (_done) return;
    _done = true;
    if (_hash != nullptr) _api.destroy(_hash);
    if (_alg != nullptr) _api.closeAlg(_alg, 0);
    if (_obj != nullptr) malloc.free(_obj);
  }
}

// ---------- macOS CommonCrypto ----------

typedef _CcInitC = Int32 Function(Pointer<Uint8>);
typedef _CcInitD = int Function(Pointer<Uint8>);
typedef _CcUpdC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Uint32);
typedef _CcUpdD = int Function(Pointer<Uint8>, Pointer<Uint8>, int);
typedef _CcFinC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _CcFinD = int Function(Pointer<Uint8>, Pointer<Uint8>);

class _Cc {
  _Cc() {
    final lib = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
    init = lib.lookupFunction<_CcInitC, _CcInitD>('CC_SHA256_Init');
    update = lib.lookupFunction<_CcUpdC, _CcUpdD>('CC_SHA256_Update');
    fin = lib.lookupFunction<_CcFinC, _CcFinD>('CC_SHA256_Final');
  }
  late final _CcInitD init;
  late final _CcUpdD update;
  late final _CcFinD fin;
}

_Cc? _ccCache;

class _CommonCryptoHasher implements Sha256Hasher {
  _CommonCryptoHasher() : _api = (_ccCache ??= _Cc()) {
    // CC_SHA256_CTX הוא 104 בתים; מקצים עם מרווח.
    _ctx = calloc.allocate<Uint8>(256);
    _api.init(_ctx);
  }
  final _Cc _api;
  Pointer<Uint8> _ctx = nullptr;

  @override
  bool get isNative => true;

  @override
  void addPointer(Pointer<Uint8> data, int length) {
    var off = 0;
    while (off < length) {
      final n = length - off < _chunk ? length - off : _chunk;
      _api.update(_ctx, data + off, n);
      off += n;
    }
  }

  @override
  void addBytes(Uint8List data) {
    final buf = malloc.allocate<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      addPointer(buf, data.length);
    } finally {
      malloc.free(buf);
    }
  }

  @override
  String close() {
    final out = malloc.allocate<Uint8>(32);
    try {
      _api.fin(out, _ctx);
      return _hex(out, 32);
    } finally {
      malloc.free(out);
      dispose();
    }
  }

  @override
  void dispose() {
    if (_ctx != nullptr) {
      calloc.free(_ctx);
      _ctx = nullptr;
    }
  }
}

// ---------- קובץ ----------

/// SHA-256 של קובץ, ב-isolate נפרד. [onProgress] מדווח (נקרא, סך הכול); [isCancelled] נבדק כל ~100ms
/// וזורק [DownloadCancelled]. [forceDart] לבדיקות.
Future<String> sha256File(
  String path, {
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
  bool forceDart = false,
}) async {
  final port = ReceivePort();
  final sub = port.listen((m) {
    if (m is (int, int)) onProgress?.call(m.$1, m.$2);
  });
  // ביטול שכבר התבקש נקלט מיד: חישוב מהיר מסתיים לפני שהסקר הראשון רץ.
  final flag = malloc.allocate<Uint8>(1)..value = (isCancelled?.call() ?? false) ? 1 : 0;
  final poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
    if (isCancelled?.call() ?? false) flag.value = 1;
  });
  try {
    final r = await _spawn(path, flag.address, port.sendPort, forceDart);
    if (r == null) throw DownloadCancelled();
    return r;
  } finally {
    poll.cancel();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    port.close();
    malloc.free(flag);
  }
}

// נפרד כדי שה-closure לא יתפוס את הקולבקים של הקורא (ראו הערה דומה ב-zstd_stream).
Future<String?> _spawn(String path, int flagAddress, SendPort send, bool forceDart) =>
    Isolate.run(() => _hashFile(path, flagAddress, send, forceDart));

String? _hashFile(String path, int flagAddress, SendPort send, bool forceDart) {
  final flag = Pointer<Uint8>.fromAddress(flagAddress);
  final h = forceDart ? Sha256Hasher.dart() : Sha256Hasher();
  final f = File(path).openSync();
  final buf = malloc.allocate<Uint8>(_chunk);
  try {
    final total = f.lengthSync();
    final view = buf.asTypedList(_chunk);
    var done = 0;
    var lastReport = DateTime.now();
    while (true) {
      if (flag.value != 0) {
        h.dispose();
        return null;
      }
      final n = f.readIntoSync(view, 0, _chunk);
      if (n <= 0) break;
      h.addPointer(buf, n);
      done += n;
      final now = DateTime.now();
      if (now.difference(lastReport).inMilliseconds >= 100) {
        lastReport = now;
        send.send((done, total));
      }
    }
    send.send((done, total));
    return h.close();
  } catch (_) {
    h.dispose();
    rethrow;
  } finally {
    f.closeSync();
    malloc.free(buf);
  }
}
