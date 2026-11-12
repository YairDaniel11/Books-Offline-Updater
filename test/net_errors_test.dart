import 'dart:async';
import 'dart:io';

import 'package:books_offline_update/src/services/net_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('סיווג קודי HTTP', () {
    expect(classifyHttp(403).kind, NetErrorKind.blocked);
    expect(classifyHttp(403, rateLimitRemaining: '0').kind, NetErrorKind.rateLimit);
    expect(classifyHttp(429).kind, NetErrorKind.rateLimit);
    expect(classifyHttp(503).kind, NetErrorKind.busy);
    expect(classifyHttp(404).kind, NetErrorKind.other);
    expect(classifyHttp(200, htmlInstead: true).kind, NetErrorKind.blocked);
  });

  test('חריגות רשת', () {
    expect(friendlyNetError(const SocketException('x')), contains('אין חיבור'));
    expect(kindOf(TimeoutException('t')), NetErrorKind.busy);
    expect(friendlyNetError(const HandshakeException('x')), contains('חסום'));
  });

  test('ensureOk: עמוד HTML במקום קובץ נחשב חסימה, ו-403 לא מוצג כשגיאת שרת', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      if (req.uri.path == '/html') {
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html>blocked</html>');
      } else if (req.uri.path == '/rate') {
        req.response.statusCode = 403;
        req.response.headers.set('x-ratelimit-remaining', '0');
      } else {
        req.response.write('ok');
      }
      req.response.close();
    });
    final c = HttpClient();
    addTearDown(c.close);
    Future<Object?> run(String path) async {
      final res = await (await c.getUrl(Uri.parse('http://127.0.0.1:${server.port}$path'))).close();
      try {
        await ensureOk(res);
        await res.drain<void>();
        return null;
      } catch (e) {
        return e;
      }
    }

    expect((await run('/html') as NetFailure).kind, NetErrorKind.blocked);
    expect((await run('/rate') as NetFailure).kind, NetErrorKind.rateLimit);
    expect(await run('/ok'), isNull);
  });

  test('Content-Range: המשך מדויק בלבד', () {
    expect(contentRangeStart('bytes 100-199/200'), 100);
    expect(contentRangeStart('bytes 0-9/*'), 0);
    expect(contentRangeStart('bytes */200'), isNull);
    expect(contentRangeStart(null), isNull);
    expect(contentRangeStart('garbage'), isNull);
  });

  test('כשלים סופיים: חסימה והגבלת קצב אינם נוסו שוב', () {
    expect(isFinalNetFailure(classifyHttp(403)), isTrue);
    expect(isFinalNetFailure(classifyHttp(429)), isTrue);
    expect(isFinalNetFailure(classifyHttp(503)), isFalse);
    expect(isFinalNetFailure(const SocketException('x')), isFalse);
  });
}
