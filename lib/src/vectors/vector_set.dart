import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../pak/crc32.dart';
import 'vectors_manifest.dart';

/// הרישום של מקטע וקטורים בסט של אוצריא (`<vectors>\CURRENT`, `gen-NNNNNN\set.json`).
/// מימוש של `publish_generation` מ-`otzaria_personal_vectors.py` במאגר הספרים.

const _worker = 'otzaria-personal-vectors 1.0';
const _oursPrefixes = ['otzaria-personal-vectors', 'otzaria-sources personal export'];
final _delMagic = ascii.encode('OXVDEL1\n');
final _linksMagic = ascii.encode('OXVLNK1\n');
const _headerLen = 4096;
final _segMagic = Uint8List.fromList([...ascii.encode('OXVSEG'), 13, 10]);

bool isOurs(Map<String, dynamic> seg) {
  final prov = seg['provenance'];
  final worker = prov is Map ? prov['worker'] : null;
  final backend = worker is Map ? worker['backend'] : null;
  return backend is String && _oursPrefixes.any(backend.startsWith);
}

class OxvHeader {
  OxvHeader(this.version, this.id, this.identityDigest, this.slots, this.foreign);
  final int version;
  final String id;
  final String identityDigest;
  final int slots;
  final int foreign;
}

/// קורא ומאמת (magic + CRC) את כותרת מקטע .oxv.
OxvHeader readOxvHeader(String path) {
  final raf = File(path).openSync();
  Uint8List h;
  try {
    h = raf.readSync(_headerLen);
  } finally {
    raf.closeSync();
  }
  if (h.length < _headerLen) throw VectorsException('קובץ הוקטורים קצר מדי');
  for (var i = 0; i < 8; i++) {
    if (h[i] != _segMagic[i]) throw VectorsException('הקובץ אינו מקטע וקטורים');
  }
  final bd = ByteData.sublistView(h);
  if (bd.getUint32(4088, Endian.little) != Crc32.update(0, h.sublist(0, 4088))) {
    throw VectorsException('כותרת מקטע הוקטורים פגומה');
  }
  String hex(int a, int b) => [for (var i = a; i < b; i++) h[i].toRadixString(16).padLeft(2, '0')].join();
  return OxvHeader(
    bd.getUint32(8, Endian.little),
    hex(32, 48),
    hex(48, 80),
    bd.getUint64(112, Endian.little),
    bd.getUint64(128, Endian.little),
  );
}

Future<void> writeDurable(String path, List<int> data) async {
  final tmp = File('$path.tmp');
  final raf = await tmp.open(mode: FileMode.write);
  try {
    await raf.writeFrom(data);
    await raf.flush();
  } finally {
    await raf.close();
  }
  await tmp.rename(path);
}

Map<String, dynamic>? _readJson(File f) {
  if (!f.existsSync()) return null;
  var s = utf8.decode(f.readAsBytesSync());
  if (s.startsWith('﻿')) s = s.substring(1);
  return jsonDecode(s) as Map<String, dynamic>;
}

/// נעילה אקסקלוסיבית על `<vectors>\.lock`, כמו שאוצריא לוקחת בהתקנה.
class SetLock {
  SetLock._(this._raf);
  final RandomAccessFile _raf;

  static SetLock acquire(String vectorsDir) {
    final raf = File(p.join(vectorsDir, '.lock')).openSync(mode: FileMode.append);
    try {
      raf.lockSync(FileLock.exclusive, 0, 1);
    } on FileSystemException {
      raf.closeSync();
      throw VectorsException('סט הוקטורים נעול: אוצריא מתקינה או מכווצת וקטורים כרגע. סגרו אותה ונסו שוב.');
    }
    return SetLock._(raf);
  }

  void release() {
    try {
      _raf.unlockSync(0, 1);
    } catch (_) {}
    _raf.closeSync();
  }
}

/// הדור ש-CURRENT מצביע עליו.
class LiveSet {
  LiveSet._(this.dir, this.pointer, this.setFile, this.doc);
  final String dir;
  final Map<String, dynamic> pointer;
  final File setFile;
  final Map<String, dynamic> doc;

  String get genDir => p.dirname(setFile.path);
  List<Map<String, dynamic>> get segments => [for (final s in doc['segments'] as List) s as Map<String, dynamic>];

  static LiveSet open(String vectorsDir) {
    final ptr = _readJson(File(p.join(vectorsDir, 'CURRENT')));
    if (ptr == null) throw VectorsException('לא נמצא סט וקטורים של אוצריא בתיקייה: $vectorsDir');
    final rel = ptr['set'];
    if (rel is! String || p.isAbsolute(rel) || rel.contains('..')) throw VectorsException('CURRENT אינו תקין');
    final setFile = File(p.join(vectorsDir, rel));
    final raw = setFile.readAsBytesSync();
    if (sha256.convert(raw).toString() != ptr['set_sha256']) {
      throw VectorsException('CURRENT אינו תואם לקובץ הסט (set.json)');
    }
    final doc = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    return LiveSet._(vectorsDir, ptr, setFile, doc);
  }
}

int _nextGeneration(String vdir) {
  var m = 0;
  final d = Directory(vdir);
  if (d.existsSync()) {
    for (final e in d.listSync()) {
      final n = p.basename(e.path);
      if (e is Directory && n.startsWith('gen-')) m = _max(m, int.tryParse(n.substring(4)) ?? 0);
    }
  }
  for (final name in const ['CURRENT', 'PREVIOUS']) {
    try {
      final g = _readJson(File(p.join(vdir, name)))?['generation'];
      if (g is int) m = _max(m, g);
    } catch (_) {}
  }
  return m + 1;
}

int _max(int a, int b) => a > b ? a : b;

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

/// קובץ `.del` ריק: magic, slots, count=0, ביטמפ אפסים, CRC32.
Uint8List buildDel(int slots) {
  final words = (slots + 63) ~/ 64;
  final b = BytesBuilder()..add(_delMagic);
  final head = ByteData(16)
    ..setUint64(0, slots, Endian.little)
    ..setUint64(8, 0, Endian.little);
  b
    ..add(head.buffer.asUint8List())
    ..add(Uint8List(8 * words));
  final body = b.toBytes();
  return Uint8List.fromList([...body, ..._u32(Crc32.update(0, body))]);
}

/// קובץ `.links` ריק: magic, count=0, CRC32.
Uint8List buildLinks() {
  final body = Uint8List.fromList([..._linksMagic, ...Uint8List(8)]);
  return Uint8List.fromList([...body, ..._u32(Crc32.update(0, body))]);
}

int _crcOfBody(Uint8List withCrc) => Crc32.update(0, withCrc.sublist(0, withCrc.length - 4));

/// יוצר דור חדש שמוסיף את המקטע [segId] (כבר ב-`segments\<id>.oxv`), וכותב PREVIOUS ואז CURRENT.
/// כשל לפני כתיבת CURRENT מוחק את תיקיית הדור שנוצרה. מחזיר את מספר הדור.
Future<int> publishGeneration(
  LiveSet live, {
  required String segId,
  required int slots,
  required String sha256Hex,
  required int size,
  required int version,
  required String origin,
}) async {
  final vdir = live.dir;
  final doc = live.doc;
  final gen = _nextGeneration(vdir);
  final gname = 'gen-${gen.toString().padLeft(6, '0')}';
  final gdir = Directory(p.join(vdir, gname));
  await gdir.create();
  try {
    final segs = live.segments;
    for (final s in segs) {
      for (final key in const ['del', 'links']) {
        final f = s[key];
        if (f is Map && f['file'] is String) {
          final name = p.basename(f['file'] as String);
          await File(p.join(live.genDir, name)).copy(p.join(gdir.path, name));
        }
      }
    }
    final delb = buildDel(slots);
    final linkb = buildLinks();
    await writeDurable(p.join(gdir.path, '$segId.del'), delb);
    await writeDurable(p.join(gdir.path, '$segId.links'), linkb);

    Map<String, dynamic>? package;
    final model = (doc['identity'] as Map?)?['model'];
    if (model is Map && model['query_packages'] is List) {
      for (final q in model['query_packages'] as List) {
        if (q is Map<String, dynamic> && q['quantization'] == 'fp32') {
          package = q;
          break;
        }
      }
    }
    final ours = <String, dynamic>{
      'id': segId,
      'file': 'segments/$segId.oxv',
      'kind': 'delta',
      'from': version,
      'to': version,
      'sha256': sha256Hex,
      'size': size,
      'slots': slots,
      'provenance': {
        'passage_package': package,
        'worker': {'backend': _worker, 'device': origin},
      },
      'del': {'file': '$segId.del', 'crc32': _crcOfBody(delb), 'count': 0},
      'links': {'file': '$segId.links', 'crc32': _crcOfBody(linkb), 'count': 0},
    };
    final all = [...segs, ours];
    var foreign = 0;
    for (final s in segs) {
      try {
        foreign += readOxvHeader(p.join(vdir, s['file'] as String)).foreign;
      } catch (_) {}
    }
    int sum(String k) => all.fold<int>(0, (a, s) => a + (s[k] as int));
    int nested(String k) => all.fold<int>(0, (a, s) => a + (((s[k] as Map?)?['count'] as int?) ?? 0));
    final next = Map<String, dynamic>.from(doc)
      ..['generation'] = gen
      ..['segments'] = all
      ..['stats'] = {
        'slots': sum('slots'),
        'slots_dead': nested('del'),
        'foreign': foreign,
        'foreign_unresolved': nested('links'),
        'bytes': sum('size'),
      }
      ..['created_at'] = '${DateTime.now().toUtc().toIso8601String().split('.').first}Z';
    final raw = utf8.encode(const JsonEncoder.withIndent('  ').convert(next));
    await writeDurable(p.join(gdir.path, 'set.json'), raw);
    final pointer = utf8.encode(jsonEncode({
      'generation': gen,
      'set': '$gname/set.json',
      'set_sha256': sha256.convert(raw).toString(),
    }));
    await writeDurable(p.join(vdir, 'PREVIOUS'), await File(p.join(vdir, 'CURRENT')).readAsBytes());
    await writeDurable(p.join(vdir, 'CURRENT'), pointer);
  } catch (_) {
    // CURRENT לא שונה (הוא נכתב אחרון): מנקים את הדור שנוצר.
    final cur = _readJson(File(p.join(vdir, 'CURRENT')))?['generation'];
    if (cur != gen) {
      try {
        await gdir.delete(recursive: true);
      } catch (_) {}
    }
    rethrow;
  }
  return gen;
}
