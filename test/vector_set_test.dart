import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:books_offline_update/src/pak/crc32.dart';
import 'package:books_offline_update/src/vectors/vector_set.dart';
import 'package:books_offline_update/src/vectors/vectors_manifest.dart';
import 'package:books_offline_update/src/vectors/vectors_service.dart';

Uint8List fakeOxv(int slots) {
  final h = Uint8List(4096);
  h.setAll(0, [...ascii.encode('OXVSEG'), 13, 10]);
  final bd = ByteData.sublistView(h);
  bd.setUint32(8, 3, Endian.little);
  for (var i = 0; i < 16; i++) {
    h[32 + i] = i;
  }
  bd.setUint64(112, slots, Endian.little);
  bd.setUint32(4088, Crc32.update(0, h.sublist(0, 4088)), Endian.little);
  return h;
}

void main() {
  test('חתימת המניפסט האמיתי מאומתת במפתח של המסד, והמניפסט נפרס', () {
    final bytes = File('test/fixtures/vectors-manifest.json').readAsBytesSync();
    final sig = File('test/fixtures/vectors-manifest.json.sig').readAsStringSync();
    final r = VectorsService.verify(bytes, sig);
    expect(r.manifest.files.single.file, endsWith('.oxv.zst'));
    expect(r.manifest.dbVersion, 51);
    expect(() => VectorsService.verify(Uint8List.fromList([...bytes, 32]), sig), throwsA(isA<VectorsException>()));
  });

  test('publishGeneration יוצר דור חדש ומעדכן PREVIOUS ו-CURRENT', () async {
    final dir = Directory.systemTemp.createTempSync('vecset');
    addTearDown(() => dir.deleteSync(recursive: true));
    final v = dir.path;
    Directory(p.join(v, 'segments')).createSync();
    Directory(p.join(v, 'gen-000003')).createSync();
    File(p.join(v, 'segments', 'aa.oxv')).writeAsBytesSync(fakeOxv(10));
    final del = buildDel(10), links = buildLinks();
    File(p.join(v, 'gen-000003', 'aa.del')).writeAsBytesSync(del);
    File(p.join(v, 'gen-000003', 'aa.links')).writeAsBytesSync(links);
    final doc = {
      'generation': 3,
      'library_version': 38,
      'identity_digest': 'x',
      'segments': [
        {
          'id': 'aa', 'file': 'segments/aa.oxv', 'kind': 'base', 'slots': 10, 'size': 4096,
          'del': {'file': 'aa.del', 'crc32': 1, 'count': 0},
          'links': {'file': 'aa.links', 'crc32': 2, 'count': 0},
        }
      ],
    };
    final raw = utf8.encode(jsonEncode(doc));
    File(p.join(v, 'gen-000003', 'set.json')).writeAsBytesSync(raw);
    final cur = utf8.encode(jsonEncode({'generation': 3, 'set': 'gen-000003/set.json', 'set_sha256': sha256.convert(raw).toString()}));
    File(p.join(v, 'CURRENT')).writeAsBytesSync(cur);

    final live = LiveSet.open(v);
    final gen = await publishGeneration(live,
        segId: 'bb', slots: 100, sha256Hex: 'ab', size: 999, version: 38, origin: 'prebuilt: 1');
    expect(gen, 4);
    expect(File(p.join(v, 'PREVIOUS')).readAsBytesSync(), cur);
    final after = LiveSet.open(v);
    expect(after.doc['generation'], 4);
    final segs = after.segments;
    expect(segs.length, 2);
    expect(isOurs(segs.last), isTrue);
    expect(segs.last['from'], 38);
    expect(after.doc['stats']['slots'], 110);
    final g = p.join(v, 'gen-000004');
    expect(File(p.join(g, 'aa.del')).existsSync(), isTrue);
    final bdel = File(p.join(g, 'bb.del')).readAsBytesSync();
    expect(bdel.length, 8 + 16 + 8 * 2 + 4);
    expect(segs.last['del']['crc32'], Crc32.update(0, bdel.sublist(0, bdel.length - 4)));
    expect(File(p.join(g, 'bb.links')).readAsBytesSync().length, 8 + 8 + 4);
    // הדור הבא ממשיך את המספור
    expect(await publishGeneration(after, segId: 'cc', slots: 1, sha256Hex: 'x', size: 1, version: 38, origin: 'o'), 5);
  });

  test('readOxvHeader קורא כותרת ודוחה כותרת פגומה', () {
    final dir = Directory.systemTemp.createTempSync('oxv');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File(p.join(dir.path, 'a.oxv'))..writeAsBytesSync(fakeOxv(7));
    final h = readOxvHeader(f.path);
    expect(h.version, 3);
    expect(h.slots, 7);
    expect(h.id, '000102030405060708090a0b0c0d0e0f');
    final bad = fakeOxv(7)..[200] = 9;
    f.writeAsBytesSync(bad);
    expect(() => readOxvHeader(f.path), throwsA(isA<VectorsException>()));
  });
}
