import 'dart:convert';
import 'dart:typed_data';

class VectorsException implements Exception {
  VectorsException(this.message);
  final String message;
  @override
  String toString() => message;
}

class VectorsFile {
  VectorsFile({required this.file, required this.size, required this.sha256});
  final String file;
  final int size;
  final String sha256;
}

class VectorsSegment {
  VectorsSegment({required this.id, required this.sha256, required this.size, required this.slots});
  final String id;
  final String sha256;
  final int size;
  final int slots;
}

/// מניפסט וקטורים (`kind: supplement`) מ-release `vectors` של מאגר הספרים.
class VectorsManifest {
  VectorsManifest({
    required this.identityDigest,
    required this.codecParamsSha256,
    required this.segment,
    required this.files,
    required this.dbVersion,
    required this.dbSha256,
    required this.dbSlug,
    required this.libraryVersion,
    this.runId,
  });

  final String identityDigest;
  final String codecParamsSha256;
  final VectorsSegment segment;
  final List<VectorsFile> files;
  final int dbVersion;
  final String dbSha256;
  final String dbSlug;

  /// `dedupAgainst.libraryVersion`: מידע בלבד.
  final int? libraryVersion;
  final String? runId;

  int get downloadSize => files.fold(0, (a, b) => a + b.size);

  static VectorsManifest parse(Uint8List bytes) {
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw VectorsException('מניפסט הוקטורים אינו תקין');
    }
    if (j is! Map<String, dynamic>) throw VectorsException('מניפסט הוקטורים אינו תקין');
    try {
      if (j['formatVersion'] != 1 || j['kind'] != 'supplement') {
        throw VectorsException('פורמט הוקטורים לא נתמך. ייתכן שנדרשת גרסה חדשה של התוכנה');
      }
      if (j['compression'] != 'zstd') throw VectorsException('דחיסת הוקטורים לא נתמכת');
      final seg = j['segment'] as Map<String, dynamic>;
      final db = j['db'] as Map<String, dynamic>;
      final files = [
        for (final f in (j['files'] as List))
          VectorsFile(file: f['file'] as String, size: f['size'] as int, sha256: f['sha256'] as String),
      ];
      if (files.isEmpty) throw VectorsException('במניפסט הוקטורים אין קבצים');
      for (final f in files) {
        // שם קובץ בלבד: מגן מנתיבים זדוניים.
        if (f.file.contains('/') || f.file.contains('\\') || f.file.contains('..')) {
          throw VectorsException('שם קובץ לא תקין במניפסט הוקטורים');
        }
      }
      final dedup = j['dedupAgainst'];
      return VectorsManifest(
        identityDigest: j['identityDigest'] as String,
        codecParamsSha256: j['codecParamsSha256'] as String,
        segment: VectorsSegment(
          id: seg['id'] as String,
          sha256: seg['sha256'] as String,
          size: seg['size'] as int,
          slots: seg['slots'] as int,
        ),
        files: files,
        dbVersion: db['version'] as int,
        dbSha256: db['sha256'] as String,
        dbSlug: db['slug'] as String,
        libraryVersion: dedup is Map ? dedup['libraryVersion'] as int? : null,
        runId: (j['builtBy'] is Map) ? (j['builtBy'] as Map)['runId']?.toString() : null,
      );
    } on VectorsException {
      rethrow;
    } catch (_) {
      throw VectorsException('מניפסט הוקטורים אינו תקין');
    }
  }
}
