import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// רשומה במדריך המרכזי של zip.
class ZipEntryInfo {
  ZipEntryInfo({
    required this.name,
    required this.method,
    required this.crc,
    required this.compressedSize,
    required this.size,
    required this.localHeaderOffset,
  });

  final String name;
  final int method; // 0 = stored, 8 = deflate
  final int crc;
  final int compressedSize;
  final int size;
  final int localHeaderOffset;

  bool get isDirectory => name.endsWith('/');
}

/// קורא zip מהדיסק בלי לטעון אותו לזיכרון: מפענח רק את המדריך המרכזי, ומאפשר
/// להעתיק את הבתים הדחוסים של כל קובץ כמו שהם (בלי לפרוס ולדחוס מחדש).
class ZipReader {
  ZipReader._(this._raf, this.entries);

  final RandomAccessFile _raf;
  final List<ZipEntryInfo> entries;

  static Future<ZipReader> open(String path) async {
    final raf = await File(path).open();
    try {
      final length = await raf.length();
      final tailLen = length < 70000 ? length : 70000;
      await raf.setPosition(length - tailLen);
      final tail = await raf.read(tailLen);
      final bd = ByteData.sublistView(tail);
      var eocd = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (bd.getUint32(i, Endian.little) == 0x06054b50) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) throw const FormatException('קובץ zip פגום (אין מדריך מרכזי)');
      final total = bd.getUint16(eocd + 10, Endian.little);
      final cdSize = bd.getUint32(eocd + 12, Endian.little);
      final cdOffset = bd.getUint32(eocd + 16, Endian.little);
      if (total == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
        throw const FormatException('zip64 אינו נתמך');
      }

      await raf.setPosition(cdOffset);
      final cd = await raf.read(cdSize);
      final cbd = ByteData.sublistView(cd);
      final entries = <ZipEntryInfo>[];
      var p = 0;
      for (var i = 0; i < total; i++) {
        if (p + 46 > cd.length || cbd.getUint32(p, Endian.little) != 0x02014b50) {
          throw const FormatException('קובץ zip פגום (מדריך מרכזי)');
        }
        final method = cbd.getUint16(p + 10, Endian.little);
        final crc = cbd.getUint32(p + 16, Endian.little);
        final csize = cbd.getUint32(p + 20, Endian.little);
        final usize = cbd.getUint32(p + 24, Endian.little);
        final nameLen = cbd.getUint16(p + 28, Endian.little);
        final extraLen = cbd.getUint16(p + 30, Endian.little);
        final commentLen = cbd.getUint16(p + 32, Endian.little);
        final offset = cbd.getUint32(p + 42, Endian.little);
        final name = utf8.decode(cd.sublist(p + 46, p + 46 + nameLen), allowMalformed: true);
        entries.add(ZipEntryInfo(
          name: name,
          method: method,
          crc: crc,
          compressedSize: csize,
          size: usize,
          localHeaderOffset: offset,
        ));
        p += 46 + nameLen + extraLen + commentLen;
      }
      return ZipReader._(raf, entries);
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  /// מזרים את הבתים הדחוסים של [e] (כפי שהם בקובץ).
  Stream<Uint8List> rawStream(ZipEntryInfo e, {int chunk = 1 << 20}) async* {
    await _raf.setPosition(e.localHeaderOffset);
    final header = await _raf.read(30);
    final bd = ByteData.sublistView(header);
    if (header.length < 30 || bd.getUint32(0, Endian.little) != 0x04034b50) {
      throw const FormatException('קובץ zip פגום (כותרת מקומית)');
    }
    final nameLen = bd.getUint16(26, Endian.little);
    final extraLen = bd.getUint16(28, Endian.little);
    var pos = e.localHeaderOffset + 30 + nameLen + extraLen;
    var left = e.compressedSize;
    while (left > 0) {
      await _raf.setPosition(pos);
      final n = left < chunk ? left : chunk;
      final data = await _raf.read(n);
      if (data.isEmpty) throw const FormatException('קובץ zip קטוע');
      yield data;
      pos += data.length;
      left -= data.length;
    }
  }

  Future<void> close() => _raf.close();
}
