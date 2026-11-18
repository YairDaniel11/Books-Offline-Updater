import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:books_offline_update/src/vectors/vectors_manifest.dart';
import 'package:books_offline_update/src/vectors/vectors_service.dart';

void main() {
  late Directory src, dst;
  late VectorsRelease rel;
  final data = Uint8List.fromList(List.generate(300000, (i) => i % 251));

  setUp(() {
    src = Directory.systemTemp.createTempSync('vsrc');
    dst = Directory.systemTemp.createTempSync('vdst');
    File(p.join(src.path, 'a.oxv.zst')).writeAsBytesSync(data);
    final m = VectorsManifest(
      identityDigest: 'i',
      codecParamsSha256: 'c',
      segment: VectorsSegment(id: 's', sha256: 'x', size: 1, slots: 1),
      files: [VectorsFile(file: 'a.oxv.zst', size: data.length, sha256: sha256.convert(data).toString())],
      dbVersion: 51,
      dbSha256: 'd',
      dbSlug: 'slug',
      libraryVersion: 38,
    );
    rel = VectorsRelease(Uint8List.fromList(utf8.encode('{}')), 'sig', m);
  });
  tearDown(() {
    src.deleteSync(recursive: true);
    dst.deleteSync(recursive: true);
  });

  test('מעתיק קובץ ומניפסט, בלי .part', () async {
    await VectorsService.copyPackage(rel, src.path, dst.path, onProgress: (_, _, _) {}, isCancelled: () => false);
    expect(File(p.join(dst.path, 'a.oxv.zst')).readAsBytesSync(), data);
    expect(File(p.join(dst.path, 'vectors-manifest.json')).existsSync(), isTrue);
    expect(File(p.join(dst.path, 'vectors-manifest.json.sig')).readAsStringSync(), 'sig');
    expect(Directory(dst.path).listSync().any((e) => e.path.endsWith('.part')), isFalse);
  });

  test('מקור פגום: נכשל, לא משאיר קובץ ולא כותב מניפסט', () async {
    File(p.join(src.path, 'a.oxv.zst')).writeAsBytesSync(Uint8List.fromList(data.reversed.toList()));
    await expectLater(
      VectorsService.copyPackage(rel, src.path, dst.path, onProgress: (_, _, _) {}, isCancelled: () => false),
      throwsA(isA<VectorsException>()),
    );
    expect(Directory(dst.path).listSync(), isEmpty);
  });
}
