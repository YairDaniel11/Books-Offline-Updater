import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crc32.dart';
import 'zip_reader.dart';

/// רשומת קובץ בתוך ה-PAK: בתים דחוסים כפי שהגיעו מה-zip (method 8 = deflate).
class PakEntry {
  PakEntry({
    required this.offset,
    required this.compressedSize,
    required this.size,
    required this.method,
    required this.crc,
    required this.version,
  });

  final int offset;
  final int compressedSize;
  final int size;
  final int method;
  final int crc;

  /// חותמת זמן של ההכנסה ל-PAK. נקבעת כזמן השינוי של הקובץ ביעד, כדי לדלג בחילוץ על קבצים זהים.
  final int version;

  List<Object> toJson() => [offset, compressedSize, size, method, crc, version];

  static PakEntry fromJson(List<dynamic> j) => PakEntry(
        offset: j[0] as int,
        compressedSize: j[1] as int,
        size: j[2] as int,
        method: j[3] as int,
        crc: j[4] as int,
        version: j[5] as int,
      );
}

/// קובץ מאגר יחיד: כותרת קבועה, בלוקים דחוסים שנצברים בהמשך, ואינדקס (gzip JSON) בסוף.
/// הכותרת מוחלפת אחרונה, ולכן הפסקה באמצע כתיבה משאירה את המצב הקודם שלם.
class PakFile {
  PakFile._(this.path, this._raf, this.readOnly);

  static const _magic = 'OTZPAK01';
  static const headerSize = 64;

  final String path;
  final RandomAccessFile _raf;
  final bool readOnly;

  final Map<String, PakEntry> files = {};
  Map<String, dynamic> meta = {};
  int _end = headerSize;
  int _indexLength = 0;

  static Future<PakFile> openOrCreate(String path, {bool allowCreate = true}) async {
    final f = File(path);
    if (!await f.exists()) {
      if (!allowCreate) throw FileSystemException('קובץ PAK לא נמצא', path);
      final raf = await f.open(mode: FileMode.write);
      await raf.writeFrom(_headerBytes());
      final pak = PakFile._(path, raf, false).._end = headerSize;
      await pak._commit();
      return pak;
    }
    RandomAccessFile raf;
    var readOnly = false;
    try {
      raf = await f.open(mode: FileMode.append);
    } on FileSystemException {
      raf = await f.open();
      readOnly = true;
    }
    final pak = PakFile._(path, raf, readOnly);
    await pak._load();
    return pak;
  }

  static Uint8List _headerBytes() {
    final h = Uint8List(headerSize);
    h.setRange(0, 8, ascii.encode(_magic));
    ByteData.sublistView(h).setUint32(8, 1, Endian.little);
    return h;
  }

  int get fileLength => _end;

  int get liveBytes => files.values.fold(0, (s, e) => s + e.compressedSize);

  int get totalUncompressed => files.values.fold(0, (s, e) => s + e.size);

  /// בתים שאינם בשימוש (בלוקים שהוחלפו, אינדקסים ישנים).
  int get deadBytes {
    final dead = _end - headerSize - liveBytes - _indexLength;
    return dead < 0 ? 0 : dead;
  }

  static const _tailMagic = 'OTZPAKFT';
  static const _tailSize = 32;

  /// קורא את האינדקס האחרון התקין. הזנב (32 בתים בסוף הקובץ): magic, offset, length, crc.
  /// אם הכתיבה האחרונה נקטעה, מחפש אחורה את הזנב התקין הקודם.
  Future<void> _load() async {
    final len = await _raf.length();
    await _raf.setPosition(0);
    final h = await _raf.read(8);
    if (h.length < 8 || ascii.decode(h, allowInvalid: true) != _magic) {
      throw const FormatException('זה אינו קובץ PAK של התוכנה');
    }
    var end = len;
    while (end >= headerSize + _tailSize) {
      if (await _tryTail(end)) {
        _end = len;
        return;
      }
      // זנב לא תקין: מחפשים את ה-magic הקודם בחלון אחורה.
      final found = await _findTailBefore(end - _tailSize);
      if (found < 0) break;
      end = found + _tailSize;
    }
    throw const FormatException('האינדקס של ה-PAK פגום או חסר');
  }

  Future<bool> _tryTail(int end) async {
    await _raf.setPosition(end - _tailSize);
    final t = await _raf.read(_tailSize);
    if (t.length < _tailSize || ascii.decode(t.sublist(0, 8), allowInvalid: true) != _tailMagic) return false;
    final bd = ByteData.sublistView(t);
    final off = bd.getUint64(8, Endian.little);
    final length = bd.getUint64(16, Endian.little);
    final crc = bd.getUint32(24, Endian.little);
    if (off < headerSize || off + length > end - _tailSize) return false;
    await _raf.setPosition(off);
    final raw = await _raf.read(length);
    if (raw.length != length || Crc32.update(0, raw) != crc) return false;
    try {
      final json = jsonDecode(utf8.decode(gzip.decode(raw))) as Map<String, dynamic>;
      final loaded = <String, PakEntry>{};
      (json['files'] as Map<String, dynamic>).forEach((k, v) {
        loaded[k] = PakEntry.fromJson(v as List<dynamic>);
      });
      files
        ..clear()
        ..addAll(loaded);
      meta = (json['meta'] as Map<String, dynamic>?) ?? {};
      _indexLength = length + _tailSize;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<int> _findTailBefore(int before) async {
    final magic = ascii.encode(_tailMagic);
    const window = 1 << 20;
    var hi = before;
    while (hi > headerSize) {
      final lo = hi - window < headerSize ? headerSize : hi - window;
      await _raf.setPosition(lo);
      final buf = await _raf.read(hi - lo + magic.length > before - lo + 1 ? before - lo + 1 : hi - lo + magic.length);
      for (var i = buf.length - magic.length; i >= 0; i--) {
        var ok = true;
        for (var k = 0; k < magic.length; k++) {
          if (buf[i + k] != magic[k]) {
            ok = false;
            break;
          }
        }
        if (ok && lo + i < before) return lo + i;
      }
      if (lo == headerSize) break;
      hi = lo;
    }
    return -1;
  }

  /// כל הכתיבות הן הוספה בסוף הקובץ בלבד (בטוח גם כשמערכת ההפעלה פותחת ב-O_APPEND).
  /// האינדקס והזנב נכתבים אחרונים: הפסקה באמצע משאירה את הזנב הקודם שלם.
  Future<void> _commit() async {
    if (readOnly) throw StateError('ה-PAK בקריאה בלבד');
    final index = gzip.encode(utf8.encode(jsonEncode({
      'files': files.map((k, v) => MapEntry(k, v.toJson())),
      'meta': meta,
    })));
    final indexOffset = _end;
    final tail = Uint8List(_tailSize);
    final bd = ByteData.sublistView(tail);
    tail.setRange(0, 8, ascii.encode(_tailMagic));
    bd.setUint64(8, indexOffset, Endian.little);
    bd.setUint64(16, index.length, Endian.little);
    bd.setUint32(24, Crc32.update(0, index), Endian.little);
    await _raf.setPosition(_end);
    await _raf.writeFrom(index);
    await _raf.writeFrom(tail);
    await _raf.flush();
    _end += index.length + _tailSize;
    _indexLength = index.length + _tailSize;
  }

  Future<void> commit() => _commit();

  /// מוסיף למאגר את כל הקבצים ב-zip, כשהנתיב הוא [prefix]/שם-בזיפ.
  /// קובץ זהה למה שכבר קיים (גודל + CRC) לא נכתב שוב.
  /// מחזיר את קבוצת הנתיבים שנמצאו ב-zip, ל-[pruneUnder].
  Future<Set<String>> ingestZip(
    String zipPath,
    String prefix, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (readOnly) throw StateError('ה-PAK בקריאה בלבד');
    final zip = await ZipReader.open(zipPath);
    final seen = <String>{};
    final stamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    try {
      final list = zip.entries.where((e) => !e.isDirectory).toList();
      var done = 0;
      for (final e in list) {
        if (isCancelled?.call() ?? false) break;
        if (e.method != 0 && e.method != 8) {
          throw FormatException('שיטת דחיסה לא נתמכת (${e.method}) בקובץ ${e.name}');
        }
        final path = prefix.isEmpty ? e.name : '$prefix/${e.name}';
        seen.add(path);
        final old = files[path];
        if (old != null && old.crc == e.crc && old.size == e.size) {
          onProgress?.call(++done, list.length);
          continue;
        }
        final start = _end;
        await _raf.setPosition(start);
        var written = 0;
        await for (final chunk in zip.rawStream(e)) {
          await _raf.writeFrom(chunk);
          written += chunk.length;
        }
        _end += written;
        files[path] = PakEntry(
          offset: start,
          compressedSize: written,
          size: e.size,
          method: e.method,
          crc: e.crc,
          version: stamp,
        );
        onProgress?.call(++done, list.length);
      }
    } finally {
      await zip.close();
    }
    return seen;
  }

  /// מוסיף קובץ בודד (למשל דורות.csv) מהזיכרון, בדחיסה.
  Future<void> putBytes(String path, Uint8List data) async {
    if (readOnly) throw StateError('ה-PAK בקריאה בלבד');
    final crc = Crc32.update(0, data);
    final old = files[path];
    if (old != null && old.crc == crc && old.size == data.length) return;
    final z = ZLibCodec(raw: true, level: 9).encode(data);
    final start = _end;
    await _raf.setPosition(start);
    await _raf.writeFrom(z);
    _end += z.length;
    files[path] = PakEntry(
      offset: start,
      compressedSize: z.length,
      size: data.length,
      method: 8,
      crc: crc,
      version: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// מוחק את כל הקבצים תחת [prefix]/ שאינם ב-[keep]. מחזיר את הנתיבים שנמחקו.
  List<String> pruneUnder(String prefix, Set<String> keep) {
    final gone = files.keys.where((p) => p.startsWith('$prefix/') && !keep.contains(p)).toList();
    for (final p in gone) {
      files.remove(p);
    }
    return gone;
  }

  bool remove(String path) => files.remove(path) != null;

  Stream<Uint8List> rawStream(PakEntry e, {int chunk = 1 << 20}) async* {
    var pos = e.offset;
    var left = e.compressedSize;
    while (left > 0) {
      await _raf.setPosition(pos);
      final data = await _raf.read(left < chunk ? left : chunk);
      if (data.isEmpty) throw const FormatException('קובץ ה-PAK קטוע');
      yield data;
      pos += data.length;
      left -= data.length;
    }
    if (!readOnly) await _raf.setPosition(_end);
  }

  /// פורס את [e] אל [target] (דרך קובץ זמני), ומאמת CRC. זורק כשל בשגיאה.
  Future<void> extractTo(PakEntry e, String target) async {
    final out = File(target);
    await out.parent.create(recursive: true);
    final part = File('$target.part');
    final sink = part.openWrite();
    var crc = 0;
    try {
      if (e.method == 0) {
        await for (final c in rawStream(e)) {
          crc = Crc32.update(crc, c);
          sink.add(c);
        }
      } else {
        final buffered = <List<int>>[];
        final conv = ZLibCodec(raw: true).decoder.startChunkedConversion(_ListSink(buffered));
        await for (final c in rawStream(e)) {
          conv.add(c);
          for (final b in buffered) {
            crc = Crc32.update(crc, b);
            sink.add(b);
          }
          buffered.clear();
        }
        conv.close();
        for (final b in buffered) {
          crc = Crc32.update(crc, b);
          sink.add(b);
        }
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await part.delete();
      } catch (_) {}
      rethrow;
    }
    if (crc != e.crc) {
      await part.delete();
      throw const FormatException('בדיקת CRC נכשלה');
    }
    if (await out.exists()) await out.delete();
    await part.rename(target);
    try {
      await out.setLastModified(DateTime.fromMillisecondsSinceEpoch(e.version * 1000));
    } catch (_) {}
  }

  /// כותב מחדש את הקובץ בלי הבלוקים המתים. מחליף את הקובץ הקיים אחרי הצלחה.
  /// מחזיר כמה בתים נחסכו. אחרי הקריאה ה-instance הזה סגור — יש לפתוח את הקובץ מחדש.
  Future<int> compact({void Function(double)? onProgress}) async {
    if (readOnly) throw StateError('ה-PAK בקריאה בלבד');
    final tmpPath = '$path.compact';
    final tmp = await File(tmpPath).open(mode: FileMode.write);
    final fresh = <String, PakEntry>{};
    var pos = headerSize;
    await tmp.writeFrom(_headerBytes());
    var done = 0;
    final entries = files.entries.toList()..sort((a, b) => a.value.offset.compareTo(b.value.offset));
    for (final me in entries) {
      final e = me.value;
      final start = pos;
      await for (final c in rawStream(e)) {
        await tmp.writeFrom(c);
        pos += c.length;
      }
      fresh[me.key] = PakEntry(
        offset: start,
        compressedSize: e.compressedSize,
        size: e.size,
        method: e.method,
        crc: e.crc,
        version: e.version,
      );
      onProgress?.call(++done / entries.length);
    }
    await tmp.close();
    final oldLen = _end;
    await _raf.close();
    // נפתח מחדש כדי לכתוב אינדקס וכותרת על הקובץ החדש.
    final tmpFile = File(tmpPath);
    final raf = await tmpFile.open(mode: FileMode.append);
    final replacement = PakFile._(tmpPath, raf, false)
      ..files.addAll(fresh)
      ..meta = meta
      .._end = pos;
    await replacement._commit();
    await raf.close();
    await File(path).delete();
    await tmpFile.rename(path);
    return oldLen - pos;
  }

  Future<void> close() => _raf.close();
}

class _ListSink implements Sink<List<int>> {
  _ListSink(this.out);
  final List<List<int>> out;
  @override
  void add(List<int> data) => out.add(data);
  @override
  void close() {}
}
