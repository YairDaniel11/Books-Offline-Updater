import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:path/path.dart' as p;

/// המפתח הציבורי (ed25519, base64) שחותם את מניפסט מסד "מאגר ספרים לא רשמי".
/// זהה ל-`schema_meta.update_public_key` שבתוך המסד עצמו.
const dbPublicKey = 'mLRPx/L43Th/nAVhJ2rDecHFQH/vfdv2xRjIz/IvEBY=';

const dbLibraryId = 'otzarya-unofficial-books';

class DbManifestException implements Exception {
  DbManifestException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// חלק בודד של קובץ (המסד או קובץ עדכון יכולים להיות מפוצלים לכמה חלקים).
class DbPart {
  DbPart({required this.url, required this.size, required this.sha256});
  final String url;
  final int size;
  final String sha256;

  /// שם הקובץ בדיסק: סוף הכתובת, כך שהמראה שטוחה ונשארת קריאה גם כשמעתיקים קבצים ידנית.
  String get fileName {
    final raw = p.posix.basename(Uri.parse(url).path);
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }
}

/// אובייקט הורדה: המסד המלא (`full`) או קובץ עדכון מגרסה מסוימת (`delta`).
class DbArtifact {
  DbArtifact({
    required this.compression,
    required this.size,
    required this.sha256,
    required this.parts,
    this.fromVersion,
    this.fromSha256,
  });

  /// zstd (מלא), none (מלא לא דחוס) או zstd-patch (עדכון).
  final String compression;

  /// גודל ו-sha256 של ה-DB **אחרי** פענוח.
  final int size;
  final String sha256;
  final List<DbPart> parts;
  final int? fromVersion;
  final String? fromSha256;

  bool get isDelta => compression == 'zstd-patch';
  int get downloadSize => parts.fold(0, (a, b) => a + b.size);
}

class DbManifest {
  DbManifest({
    required this.libraryId,
    required this.version,
    required this.notes,
    required this.full,
    required this.deltas,
  });

  final String libraryId;
  final int version;
  final String notes;
  final DbArtifact full;
  final List<DbArtifact> deltas;

  /// עדכון שמתאים ל-sha256 של מסד מקומי, או `null`.
  DbArtifact? deltaForSha(String sha) {
    for (final d in deltas) {
      if (d.fromSha256 == sha) return d;
    }
    return null;
  }

  DbArtifact? deltaForVersion(int v) {
    for (final d in deltas) {
      if (d.fromVersion == v) return d;
    }
    return null;
  }

  static DbManifest parse(Uint8List bytes) {
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw DbManifestException('נתוני הגרסה אינם תקינים');
    }
    if (j is! Map<String, dynamic>) throw DbManifestException('נתוני הגרסה אינם תקינים');
    if (j['format'] != 1) throw DbManifestException('פורמט נתוני הגרסה לא נתמך. ייתכן שנדרשת גרסה חדשה של התוכנה');
    final lib = j['library_id'];
    final ver = j['db_version'];
    if (lib is! String || lib.isEmpty) throw DbManifestException('library_id חסר');
    if (ver is! int || ver < 1) throw DbManifestException('db_version חסר');
    final full = _artifact(j['full'], delta: false);
    final deltas = [
      for (final d in (j['delta'] as List?) ?? const []) _artifact(d, delta: true),
    ];
    return DbManifest(
      libraryId: lib,
      version: ver,
      notes: (j['release_notes'] as String?) ?? '',
      full: full,
      deltas: deltas,
    );
  }

  static DbArtifact _artifact(Object? a, {required bool delta}) {
    if (a is! Map<String, dynamic>) throw DbManifestException('חסר רכיב בנתוני הגרסה');
    final comp = a['compression'];
    final allowed = delta ? const ['zstd-patch'] : const ['zstd', 'none'];
    if (comp is! String || !allowed.contains(comp)) throw DbManifestException('סוג דחיסה לא נתמך: $comp');
    final size = a['size'];
    final sha = a['sha256'];
    if (size is! int || size < 1 || sha is! String || sha.length != 64) {
      throw DbManifestException('size/sha256 לא תקינים');
    }
    final rawParts = a['parts'];
    if (rawParts is! List || rawParts.isEmpty || rawParts.length > 64) {
      throw DbManifestException('parts לא תקין');
    }
    final parts = <DbPart>[];
    for (final r in rawParts) {
      if (r is! Map<String, dynamic>) throw DbManifestException('חלק לא תקין');
      final url = r['url'];
      final psize = r['size'];
      final psha = r['sha256'];
      if (url is! String || psize is! int || psha is! String || psha.length != 64) {
        throw DbManifestException('חלק לא תקין');
      }
      final u = Uri.tryParse(url);
      if (u == null || u.scheme != 'https' || u.host.isEmpty) {
        throw DbManifestException('כתובת חלק חייבת להיות https');
      }
      final part = DbPart(url: url, size: psize, sha256: psha);
      final n = part.fileName;
      // שם הקובץ הופך לנתיב מקומי: חייב להיות שם פשוט בלבד.
      if (n.isEmpty || n == '.' || n == '..' || n.contains(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'))) {
        throw DbManifestException('שם קובץ לא תקין');
      }
      parts.add(part);
    }
    final fromV = a['from_db_version'];
    final fromSha = a['from_sha256'];
    if (delta && (fromV is! int || fromSha is! String || fromSha.length != 64)) {
      throw DbManifestException('נתוני גרסת מקור חסרים בקובץ עדכון');
    }
    return DbArtifact(
      compression: comp,
      size: size,
      sha256: sha,
      parts: parts,
      fromVersion: delta ? fromV as int : null,
      fromSha256: delta ? fromSha as String : null,
    );
  }
}

/// אימות חתימת ed25519 של המניפסט מול המפתח הציבורי המוטמע.
bool verifyManifestSignature(Uint8List manifest, String sigText, {String publicKey = dbPublicKey}) {
  try {
    final key = base64.decode(publicKey.trim());
    final sig = base64.decode(sigText.trim());
    if (key.length != 32 || sig.length != 64) return false;
    return ed.verify(ed.PublicKey(key), manifest, sig);
  } catch (_) {
    return false;
  }
}
