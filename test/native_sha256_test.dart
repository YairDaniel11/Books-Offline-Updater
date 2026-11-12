import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:books_offline_update/src/services/native_sha256.dart';
import 'package:books_offline_update/src/services/repo_service.dart' show DownloadCancelled;

void main() {
  late Directory dir;
  setUpAll(() => dir = Directory.systemTemp.createTempSync('sha_test'));
  tearDownAll(() => dir.deleteSync(recursive: true));

  File make(String name, int size) {
    final f = File(p.join(dir.path, name));
    final r = Random(size);
    final sink = f.openSync(mode: FileMode.write);
    var left = size;
    while (left > 0) {
      final n = min(left, 1 << 20);
      sink.writeFromSync(List<int>.generate(n, (_) => r.nextInt(256)));
      left -= n;
    }
    sink.closeSync();
    return f;
  }

  Future<String> ref(File f) async => (await sha256.bind(f.openRead()).first).toString();

  test('native hasher זמין בפלטפורמה הנתמכת', () {
    final h = Sha256Hasher();
    if (Platform.isWindows || Platform.isMacOS) expect(h.isNative, isTrue);
    h.dispose();
  });

  for (final size in [0, 1, 55, 56, 63, 64, 65, 1000, 4 * 1024 * 1024 - 1, 4 * 1024 * 1024, 4 * 1024 * 1024 + 1, 9 * 1024 * 1024 + 7]) {
    test('זהה ל-package:crypto בגודל $size', () async {
      final f = make('f$size', size);
      expect(await sha256File(f.path), await ref(f));
    });
  }

  test('קובץ גדול (32MB) + מהירות', () async {
    final f = make('big', 32 * 1024 * 1024);
    final sw = Stopwatch()..start();
    final n = await sha256File(f.path);
    final tn = sw.elapsedMilliseconds;
    sw
      ..reset()
      ..start();
    final d = await sha256File(f.path, forceDart: true);
    final td = sw.elapsedMilliseconds;
    expect(n, d);
    expect(n, await ref(f));
    // ignore: avoid_print
    print('native: ${(32 * 1000 / (tn == 0 ? 1 : tn)).toStringAsFixed(0)} MB/s ($tn ms), dart: ${(32 * 1000 / (td == 0 ? 1 : td)).toStringAsFixed(0)} MB/s ($td ms)');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('hasher מצטבר מקטעים שונים', () {
    final data = List<int>.generate(1000003, (i) => i * 7 & 255);
    final h = Sha256Hasher();
    final ptr = malloc.allocate<Uint8>(data.length);
    ptr.asTypedList(data.length).setAll(0, data);
    for (var off = 0; off < data.length;) {
      final n = min(333333, data.length - off);
      h.addPointer(ptr + off, n);
      off += n;
    }
    malloc.free(ptr);
    expect(h.close(), sha256.convert(data).toString());
  });

  test('התקדמות וביטול', () async {
    final f = File(p.join(dir.path, 'big'));
    var calls = 0;
    expect(
      sha256File(f.path, onProgress: (_, _) => calls++, isCancelled: () => true),
      throwsA(isA<DownloadCancelled>()),
    );
    var last = 0;
    await sha256File(f.path, onProgress: (d, t) => last = d);
    expect(last, f.lengthSync());
  });
}
