import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:books_offline_update/src/pak/crc32.dart';
import 'package:books_offline_update/src/vectors/oxv_format.dart';
import 'package:books_offline_update/src/vectors/vectors_installer.dart';
import 'package:books_offline_update/src/vectors/vectors_manifest.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _h(String c, int n) => c * n;
final _identity = _h('a', 64);
final _codec = _h('b', 64);

Uint8List _oxv(String idHex, String identityHex, int slots) {
  final h = Uint8List(oxvHeaderLen);
  h.setRange(0, 8, [0x4F, 0x58, 0x56, 0x53, 0x45, 0x47, 0x0D, 0x0A]);
  final bd = ByteData.sublistView(h);
  bd.setUint32(8, 3, Endian.little);
  Uint8List unhex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
  h.setRange(32, 48, unhex(idHex));
  h.setRange(48, 80, unhex(identityHex));
  bd.setUint64(112, slots, Endian.little);
  bd.setUint32(4088, Crc32.update(0, Uint8List.sublistView(h, 0, 4088)), Endian.little);
  return h;
}

Map<String, dynamic> _manifestJson({String segId = '3f09b86c3f9417b6b9836ac585e11a91'}) => {
      'formatVersion': 1,
      'kind': 'supplement',
      'compression': 'zstd',
      'identityDigest': _identity,
      'codecParamsSha256': _codec,
      'segment': {'id': segId, 'sha256': _h('c', 64), 'size': 4096, 'slots': 7, 'books': 2},
      'files': [
        {'file': 'v.oxv.zst', 'size': 10, 'sha256': _h('d', 64)}
      ],
      'db': {'version': 51, 'slug': 'otzarya-unofficial-books', 'sha256': _h('e', 64)},
      'dedupAgainst': {'libraryVersion': 38},
      'builtBy': {'runId': '123'},
    };

Uint8List _bytes(Object o) => Uint8List.fromList(utf8.encode(jsonEncode(o)));

/// סט חי מינימלי: דור 5 עם מקטע בסיס אחד.
String _makeVectorsDir(Directory root, {bool withOurs = false}) {
  final v = p.join(root.path, 'vectors');
  final baseId = '13b6f96b54d5114df13ce2c820923bc5';
  Directory(p.join(v, 'segments')).createSync(recursive: true);
  Directory(p.join(v, 'gen-000005')).createSync();
  File(p.join(v, 'segments', '$baseId.oxv')).writeAsBytesSync(_oxv(baseId, _identity, 3));
  final del = emptyDelBytes(3), links = emptyLinksBytes();
  File(p.join(v, 'gen-000005', '$baseId.del')).writeAsBytesSync(del);
  File(p.join(v, 'gen-000005', '$baseId.links')).writeAsBytesSync(links);
  final doc = {
    'generation': 5,
    'library_version': 38,
    'identity_digest': _identity,
    'codec_params_sha256': _codec,
    'identity': {
      'model': {
        'query_packages': [
          {'quantization': 'fp32', 'id': 'q'}
        ]
      }
    },
    'segments': [
      {
        'id': baseId,
        'file': 'segments/$baseId.oxv',
        'kind': 'base',
        'sha256': _h('0', 64),
        'size': 4096,
        'slots': 3,
        if (withOurs) 'provenance': {'worker': {'backend': 'otzaria-personal-vectors 1'}},
        'del': {'file': '$baseId.del', 'crc32': crcOfBody(del), 'count': 0},
        'links': {'file': '$baseId.links', 'crc32': crcOfBody(links), 'count': 0},
      }
    ],
  };
  final raw = utf8.encode(const JsonEncoder.withIndent('  ').convert(doc));
  File(p.join(v, 'gen-000005', 'set.json')).writeAsBytesSync(raw);
  File(p.join(v, 'CURRENT')).writeAsStringSync(
      jsonEncode({'generation': 5, 'set': 'gen-000005/set.json', 'set_sha256': sha256.convert(raw).toString()}));
  return v;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('vectorstest'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('מניפסט', () {
    test('תקין', () {
      final m = VectorsManifest.parse(_bytes(_manifestJson()));
      expect(m.dbVersion, 51);
      expect(m.segment.slots, 7);
      expect(m.files.single.file, 'v.oxv.zst');
      expect(m.libraryVersion, 38);
      expect(m.runId, '123');
    });

    test('סוג אחר, שם קובץ עם נתיב, ו-sha לא תקין נדחים', () {
      expect(() => VectorsManifest.parse(_bytes({..._manifestJson(), 'kind': 'base'})), throwsA(isA<VectorsException>()));
      final bad = _manifestJson();
      (bad['files'] as List)[0] = {'file': '../x.zst', 'size': 1, 'sha256': _h('d', 64)};
      expect(() => VectorsManifest.parse(_bytes(bad)), throwsA(isA<VectorsException>()));
      final bad2 = _manifestJson()..remove('segment');
      expect(() => VectorsManifest.parse(_bytes(bad2)), throwsA(isA<VectorsException>()));
      expect(() => VectorsManifest.parse(Uint8List.fromList([1, 2, 3])), throwsA(isA<VectorsException>()));
    });
  });

  group('פורמט oxv', () {
    test('כותרת נקראת, ו-CRC פגום נדחה', () {
      final b = _oxv('3f09b86c3f9417b6b9836ac585e11a91', _identity, 42);
      final h = parseOxvHeader(b);
      expect(h.id, '3f09b86c3f9417b6b9836ac585e11a91');
      expect(h.identityDigest, _identity);
      expect(h.slots, 42);
      expect(h.version, 3);
      b[100] ^= 1;
      expect(() => parseOxvHeader(b), throwsA(isA<OxvException>()));
    });

    test('מבנה .del ו-.links זהה ל-publish_generation', () {
      final d = emptyDelBytes(130); // 3 מילים
      expect(d.length, 8 + 16 + 24 + 4);
      expect(ByteData.sublistView(d).getUint64(8, Endian.little), 130);
      expect(ByteData.sublistView(d).getUint32(d.length - 4, Endian.little), Crc32.update(0, d.sublist(0, d.length - 4)));
      final l = emptyLinksBytes();
      expect(l.length, 8 + 8 + 4);
      expect(utf8.decode(l.sublist(0, 8)), 'OXVLNK1\n');
    });
  });

  group('תנאי התקנה', () {
    final m = VectorsManifest.parse(_bytes(_manifestJson()));

    test('מסד תואם: עובר', () async {
      final v = _makeVectorsDir(tmp);
      final live = await VectorsInstaller.checkPreconditions(m, v, installedDbSha256: _h('e', 64));
      expect(live.generation, 5);
    });

    test('מסד שונה או חסר: מסרב', () async {
      final v = _makeVectorsDir(tmp);
      expect(VectorsInstaller.checkPreconditions(m, v, installedDbSha256: _h('f', 64)), throwsA(isA<VectorsException>()));
      expect(VectorsInstaller.checkPreconditions(m, v, installedDbSha256: null), throwsA(isA<VectorsException>()));
    });

    test('מודל אחר: מסרב', () async {
      final v = _makeVectorsDir(tmp);
      final other = VectorsManifest.parse(_bytes({..._manifestJson(), 'identityDigest': _h('9', 64)}));
      expect(VectorsInstaller.checkPreconditions(other, v, installedDbSha256: _h('e', 64)), throwsA(isA<VectorsException>()));
    });

    test('כבר קיים מקטע שלנו: מסרב (עדכון לא נתמך)', () async {
      final v = _makeVectorsDir(tmp, withOurs: true);
      expect(VectorsInstaller.checkPreconditions(m, v, installedDbSha256: _h('e', 64)), throwsA(isA<VectorsException>()));
    });

    test('אין CURRENT, או CURRENT שאינו תואם ל-set.json: מסרב', () async {
      expect(VectorsInstaller.checkPreconditions(m, p.join(tmp.path, 'none'), installedDbSha256: _h('e', 64)),
          throwsA(isA<VectorsException>()));
      final v = _makeVectorsDir(tmp);
      File(p.join(v, 'gen-000005', 'set.json')).writeAsStringSync('{}');
      expect(VectorsInstaller.checkPreconditions(m, v, installedDbSha256: _h('e', 64)), throwsA(isA<VectorsException>()));
    });
  });

  // התקנה מלאה מול zstd אמיתי: דורשת ZSTD_EXE ו-ZSTD_LIB_PATH (כמו שאר בדיקות ה-zstd).
  final exe = Platform.environment['ZSTD_EXE'];
  final lib = Platform.environment['ZSTD_LIB_PATH'];
  test('התקנה מלאה: דור חדש, מצביעים, ואימות שחזור', () async {
    final v = _makeVectorsDir(tmp);
    final segId = '3f09b86c3f9417b6b9836ac585e11a91';
    final raw = File(p.join(tmp.path, 'seg.oxv'))..writeAsBytesSync(_oxv(segId, _identity, 7));
    final zst = p.join(tmp.path, 'files', 'v.oxv.zst');
    Directory(p.dirname(zst)).createSync();
    expect(Process.runSync(exe!, ['-q', raw.path, '-o', zst]).exitCode, 0);
    final json = _manifestJson(segId: segId);
    (json['segment'] as Map)
      ..['sha256'] = sha256.convert(raw.readAsBytesSync()).toString()
      ..['size'] = raw.lengthSync();
    json['files'] = [
      {'file': 'v.oxv.zst', 'size': File(zst).lengthSync(), 'sha256': sha256.convert(File(zst).readAsBytesSync()).toString()}
    ];
    final m = VectorsManifest.parse(_bytes(json));
    final oldCurrent = File(p.join(v, 'CURRENT')).readAsStringSync();

    final r = await VectorsInstaller.install(m, vectorsDir: v, filesDir: p.dirname(zst), installedDbSha256: _h('e', 64));
    expect(r.generation, 6);
    expect(File(p.join(v, 'segments', '$segId.oxv')).existsSync(), isTrue);
    expect(File(p.join(v, 'segments', 'personal-vectors.oxv.tmp')).existsSync(), isFalse);
    expect(File(p.join(v, 'PREVIOUS')).readAsStringSync(), oldCurrent);
    final live = await LiveVectorSet.load(v);
    expect(live.generation, 6);
    final segs = live.segments;
    expect(segs.length, 2);
    expect(segs.last['id'], segId);
    expect((segs.last['provenance'] as Map)['worker']['backend'], startsWith('otzaria-personal-vectors'));
    expect(File(p.join(v, 'gen-000006', '$segId.del')).existsSync(), isTrue);
    expect(File(p.join(v, 'gen-000006', '13b6f96b54d5114df13ce2c820923bc5.del')).existsSync(), isTrue);
    expect((live.doc['stats'] as Map)['slots'], 10);

    // התקנה שנייה: הוקטורים כבר מותקנים.
    expect(VectorsInstaller.install(m, vectorsDir: v, filesDir: p.dirname(zst), installedDbSha256: _h('e', 64)),
        throwsA(isA<VectorsException>()));
  }, skip: exe == null || lib == null ? 'חסרים ZSTD_EXE / ZSTD_LIB_PATH' : false);
}
