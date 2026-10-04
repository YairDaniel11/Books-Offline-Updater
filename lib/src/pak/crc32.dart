import 'dart:typed_data';

/// CRC-32 (אותו פולינום כמו zip). מצטבר: מעבירים את התוצאה הקודמת כ-[crc].
class Crc32 {
  Crc32._();

  static final Uint32List _table = () {
    final t = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      t[n] = c;
    }
    return t;
  }();

  static int update(int crc, List<int> data) {
    var c = crc ^ 0xFFFFFFFF;
    final t = _table;
    for (var i = 0; i < data.length; i++) {
      c = t[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
