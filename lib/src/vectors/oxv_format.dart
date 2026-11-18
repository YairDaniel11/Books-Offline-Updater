import 'dart:io';
import 'dart:typed_data';

import '../pak/crc32.dart';

/// פורמט קובץ מקטע וקטורים של אוצריא (`.oxv`, גרסה 3), כפי שמימש `otzaria_personal_vectors.py`.
const oxvHeaderLen = 4096;
const oxvSupportedVersion = 3;
const _magic = [0x4F, 0x58, 0x56, 0x53, 0x45, 0x47, 0x0D, 0x0A]; // "OXVSEG\r\n"
const _delMagic = [0x4F, 0x58, 0x56, 0x44, 0x45, 0x4C, 0x31, 0x0A]; // "OXVDEL1\n"
const _linksMagic = [0x4F, 0x58, 0x56, 0x4C, 0x4E, 0x4B, 0x31, 0x0A]; // "OXVLNK1\n"

class OxvException implements Exception {
  OxvException(this.message);
  final String message;
  @override
  String toString() => message;
}

String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

class OxvHeader {
  OxvHeader({
    required this.version,
    required this.id,
    required this.identityDigest,
    required this.slots,
    this.foreign = 0,
  });
  final int version;
  final int foreign;

  /// 32 תווי hex.
  final String id;

  /// 64 תווי hex.
  final String identityDigest;
  final int slots;
}

/// קורא ומאמת את כותרת המקטע (קסם + CRC32), בלי לקרוא את שאר הקובץ.
Future<OxvHeader> readOxvHeader(String path) async {
  final raf = await File(path).open();
  Uint8List h;
  try {
    h = await raf.read(oxvHeaderLen);
  } finally {
    await raf.close();
  }
  return parseOxvHeader(h, path);
}

OxvHeader parseOxvHeader(Uint8List h, [String name = 'oxv']) {
  if (h.length < oxvHeaderLen) throw OxvException('$name: קובץ וקטורים קצר מדי');
  for (var i = 0; i < _magic.length; i++) {
    if (h[i] != _magic[i]) throw OxvException('$name: אינו קובץ וקטורים של אוצריא');
  }
  final bd = ByteData.sublistView(h);
  if (bd.getUint32(4088, Endian.little) != Crc32.update(0, Uint8List.sublistView(h, 0, 4088))) {
    throw OxvException('$name: כותרת הקובץ פגומה');
  }
  return OxvHeader(
    version: bd.getUint32(8, Endian.little),
    id: _hex(Uint8List.sublistView(h, 32, 48)),
    identityDigest: _hex(Uint8List.sublistView(h, 48, 80)),
    slots: bd.getUint64(112, Endian.little),
    foreign: bd.getUint64(128, Endian.little),
  );
}

/// מפת סיביות "מתים" ריקה ל-[slots] וקטורים: magic, slots, count=0, מילים, CRC32 (זהה ל-`publish_generation`).
Uint8List emptyDelBytes(int slots) {
  final words = (slots + 63) ~/ 64;
  final b = BytesBuilder();
  b.add(_delMagic);
  final head = ByteData(16)
    ..setUint64(0, slots, Endian.little)
    ..setUint64(8, 0, Endian.little);
  b.add(head.buffer.asUint8List());
  b.add(Uint8List(8 * words));
  final body = b.toBytes();
  return _withCrc(body);
}

/// קובץ קישורים ריק: magic, count=0, CRC32.
Uint8List emptyLinksBytes() {
  final b = BytesBuilder()
    ..add(_linksMagic)
    ..add(Uint8List(8));
  return _withCrc(b.toBytes());
}

/// ה-CRC32 של תוכן הקובץ בלי 4 הבתים האחרונים (הערך שנרשם ב-set.json).
int crcOfBody(Uint8List fileBytes) => Crc32.update(0, Uint8List.sublistView(fileBytes, 0, fileBytes.length - 4));

Uint8List _withCrc(Uint8List body) {
  final out = Uint8List(body.length + 4)..setRange(0, body.length, body);
  ByteData.sublistView(out).setUint32(body.length, Crc32.update(0, body), Endian.little);
  return out;
}
