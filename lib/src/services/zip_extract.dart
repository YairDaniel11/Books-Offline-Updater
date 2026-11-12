import 'dart:io';

import 'package:path/path.dart' as p;

import '../pak/crc32.dart';
import '../pak/zip_reader.dart';

class _ListSink implements Sink<List<int>> {
  _ListSink(this.out);
  final List<List<int>> out;
  @override
  void add(List<int> data) => out.add(data);
  @override
  void close() {}
}

/// נתיב יחסי בטוח בתוך zip (ראו [safeZipPath]); backslash נחשב מפריד.
bool isSafeZipName(String name) => safeZipPath(name) != null;

/// CRC32 של קובץ קיים, בסטרימינג.
Future<int> _fileCrc(File f) async {
  var crc = 0;
  await for (final c in f.openRead()) {
    crc = Crc32.update(crc, c);
  }
  return crc;
}

/// מחלץ את כל קבצי [zipPath] אל [destDir] (נוצר לפי הצורך), עם אימות CRC. קבצים קיימים באותו גודל ו-CRC מדולגים.
/// מחזיר את מספר הקבצים שנכתבו.
Future<int> extractZipTo(
  String zipPath,
  String destDir, {
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final zip = await ZipReader.open(zipPath);
  var written = 0;
  try {
    final list = zip.entries.where((e) => !e.isDirectory).toList();
    var done = 0;
    for (final e in list) {
      if (isCancelled?.call() ?? false) break;
      final safe = safeZipPath(e.name);
      if (safe == null) throw FormatException('שם קובץ לא בטוח בארכיון: ${e.name}');
      if (e.method != 0 && e.method != 8) throw FormatException('שיטת דחיסה לא נתמכת בקובץ ${e.name}');
      final target = p.joinAll([destDir, ...safe.split('/')]);
      final out = File(target);
      if (await out.exists() && await out.length() == e.size && await _fileCrc(out) == e.crc) {
        onProgress?.call(++done, list.length);
        continue;
      }
      await out.parent.create(recursive: true);
      final part = File('$target.part');
      final sink = part.openWrite();
      var crc = 0;
      try {
        if (e.method == 0) {
          await for (final c in zip.rawStream(e)) {
            crc = Crc32.update(crc, c);
            sink.add(c);
          }
        } else {
          final buffered = <List<int>>[];
          final conv = ZLibCodec(raw: true).decoder.startChunkedConversion(_ListSink(buffered));
          await for (final c in zip.rawStream(e)) {
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
        throw FormatException('בדיקת תקינות נכשלה בקובץ ${e.name}');
      }
      if (await out.exists()) await out.delete();
      await part.rename(target);
      written++;
      onProgress?.call(++done, list.length);
    }
  } finally {
    await zip.close();
  }
  return written;
}
