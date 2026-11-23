import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:books_offline_update/src/services/fast_download.dart';
import 'package:books_offline_update/src/services/repo_service.dart' show DownloadCancelled;

/// שרת מקומי שמגיש [data], עם או בלי תמיכה ב-Range. סופר בקשות.
Future<(HttpServer, List<String?>)> _serve(Uint8List data, {bool ranges = true}) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  final seen = <String?>[];
  server.listen((req) async {
    final r = req.headers.value(HttpHeaders.rangeHeader);
    seen.add(r);
    final res = req.response..headers.contentType = ContentType.binary;
    final m = r == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(r);
    if (ranges && m != null) {
      final s = int.parse(m.group(1)!);
      final e = m.group(2)!.isEmpty ? data.length - 1 : min(int.parse(m.group(2)!), data.length - 1);
      res.statusCode = 206;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $s-$e/${data.length}');
      res.contentLength = e - s + 1;
      res.add(data.sublist(s, e + 1));
    } else {
      res.contentLength = data.length;
      res.add(data);
    }
    await res.close();
  });
  return (server, seen);
}

void main() {
  final data = Uint8List.fromList(List.generate(1000003, (i) => (i * 31 + i ~/ 7) & 0xff));
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fastdl');
    resetFastDownloadVerdict();
  });
  tearDown(() async => dir.delete(recursive: true));

  test('מוריד בכמה מקטעים ומרכיב קובץ זהה', () async {
    final (server, seen) = await _serve(data);
    final dest = p.join(dir.path, 'a.bin');
    var last = 0;
    await fastDownload(HttpClient(), 'http://127.0.0.1:${server.port}/a', dest,
        chunkSize: 100000, onProgress: (h, t) => last = h, isCancelled: () => false);
    expect(await File(dest).readAsBytes(), data);
    expect(last, data.length);
    expect(seen.length, greaterThan(10)); // בדיקה + 11 מקטעים
    await server.close(force: true);
  });

  test('ממשיך אחרי ביטול מהמקטעים שכבר נשמרו', () async {
    final (server, seen) = await _serve(data);
    final dest = p.join(dir.path, 'b.bin');
    final url = 'http://127.0.0.1:${server.port}/b';
    var have = 0;
    await expectLater(
      fastDownload(HttpClient(), url, dest,
          knownSize: data.length, chunkSize: 100000, connections: 2,
          onProgress: (h, t) => have = h, isCancelled: () => have > 450000),
      throwsA(isA<DownloadCancelled>()),
    );
    final part = await File(dest).readAsBytes(); // חלקי, רציף ותקין
    expect(part.length, greaterThan(400000));
    expect(part, data.sublist(0, part.length));
    seen.clear();
    await fastDownload(HttpClient(), url, dest,
        knownSize: data.length, chunkSize: 100000, onProgress: (h, t) {}, isCancelled: () => false);
    expect(await File(dest).readAsBytes(), data);
    expect(seen.length, lessThan(10)); // לא הורד הכול מחדש
    await server.close(force: true);
  });

  test('שרת בלי Range: נופל להורדה רגילה', () async {
    final (server, _) = await _serve(data, ranges: false);
    final dest = p.join(dir.path, 'c.bin');
    await fastDownload(HttpClient(), 'http://127.0.0.1:${server.port}/c', dest,
        chunkSize: 100000, onProgress: (h, t) {}, isCancelled: () => false);
    expect(await File(dest).readAsBytes(), data);
    await server.close(force: true);
  });

  test('קובץ חלקי ישן (רציף, בלי קובץ מצב) ממשיך ממנו', () async {
    final (server, _) = await _serve(data);
    final dest = p.join(dir.path, 'd.bin');
    await File(dest).writeAsBytes(data.sublist(0, 350000));
    await fastDownload(HttpClient(), 'http://127.0.0.1:${server.port}/d', dest,
        knownSize: data.length, chunkSize: 100000, onProgress: (h, t) {}, isCancelled: () => false);
    expect(await File(dest).readAsBytes(), data);
    await server.close(force: true);
  });

  test('שרת בלי Range: נמדד "לא עוזר", והקבצים הבאים בלי בקשות חלקים', () async {
    final (server, seen) = await _serve(data, ranges: false);
    await fastDownload(HttpClient(), 'http://127.0.0.1:${server.port}/e', p.join(dir.path, 'e1'),
        chunkSize: 100000, onProgress: (h, t) {}, isCancelled: () => false);
    expect(fastDownloadRangesHelp, isFalse);
    seen.clear();
    await fastDownload(HttpClient(), 'http://127.0.0.1:${server.port}/e', p.join(dir.path, 'e2'),
        chunkSize: 100000, onProgress: (h, t) {}, isCancelled: () => false);
    expect(seen, [null]); // בקשה אחת רגילה
    expect(await File(p.join(dir.path, 'e2')).readAsBytes(), data);
    await server.close(force: true);
  });

  // מגבלה לכל חיבור בנפרד: כמה חיבורים באמת מהירים יותר.
  test('מדידה: מגבלה לכל חיבור - נבחרים כמה חיבורים', () async {
    final big = Uint8List(6000000);
    final server = await _throttled(big, shared: false);
    await fastDownload(HttpClient(), 'http://127.0.0.1:${server.port}/f', p.join(dir.path, 'f'),
        chunkSize: 100000, onProgress: (h, t) {}, isCancelled: () => false);
    expect(fastDownloadRangesHelp, isTrue);
    expect(await File(p.join(dir.path, 'f')).length(), big.length);
    await server.close(force: true);
  }, timeout: const Timeout(Duration(minutes: 1)));

  // מגבלה משותפת לקו (כמו נטפרי/קו איטי): כמה חיבורים לא מקצרים - חוזרים לאחד.
  test('מדידה: מגבלה משותפת - חוזרים לחיבור אחד', () async {
    final big = Uint8List(1500000);
    final server = await _throttled(big, shared: true);
    await fastDownload(HttpClient(), 'http://127.0.0.1:${server.port}/g', p.join(dir.path, 'g'),
        chunkSize: 100000, onProgress: (h, t) {}, isCancelled: () => false);
    expect(fastDownloadRangesHelp, isFalse);
    expect(await File(p.join(dir.path, 'g')).length(), big.length);
    await server.close(force: true);
  }, timeout: const Timeout(Duration(minutes: 1)));
}

/// שרת איטי: 16KB כל 100ms. [shared] - כל החיבורים יחד חולקים את הקצב (תור אחד).
Future<HttpServer> _throttled(Uint8List data, {required bool shared}) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  var line = Future<void>.value();
  server.listen((req) async {
    final r = req.headers.value(HttpHeaders.rangeHeader);
    final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(r ?? '')!;
    final s = int.parse(m.group(1)!);
    final e = m.group(2)!.isEmpty ? data.length - 1 : min(int.parse(m.group(2)!), data.length - 1);
    final res = req.response
      ..statusCode = 206
      ..headers.contentType = ContentType.binary
      ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $s-$e/${data.length}')
      ..contentLength = e - s + 1;
    for (var o = s; o <= e; o += 16384) {
      Future<void> send() async {
        res.add(data.sublist(o, min(o + 16384, e + 1)));
        await res.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      if (shared) {
        final mine = line.then((_) => send());
        line = mine.catchError((_) {});
        await mine;
      } else {
        await send();
      }
    }
    await res.close();
  });
  return server;
}
