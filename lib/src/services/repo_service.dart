import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const githubRepo = 'YairDaniel11/Otzarya-Unofficial-Books';
const _rawBase = 'https://raw.githubusercontent.com/$githubRepo/main';
const _apiBase = 'https://api.github.com/repos/$githubRepo/contents';
const _latestDl = 'https://github.com/$githubRepo/releases/latest/download';

/// פריט ברשימת הספרים (books_data.js): תיקייה עם zip משלה, שכוללת גם את כל מה שתחתיה.
class BookItem {
  BookItem({
    required this.name,
    required this.path,
    required this.zip,
    required this.parent,
    required this.size,
    required this.depth,
    required this.hash,
  });

  final String name;
  final String path;
  final String zip;
  final String parent;
  final String size;
  final int depth;
  final String hash;

  /// מפתח הסטטוס: שם ה-zip קבוע גם כששם התיקייה משתנה.
  String get key => zip.isNotEmpty ? zip : path;

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'zip': zip,
        'parent': parent,
        'size': size,
        'depth': depth,
        'hash': hash,
      };

  static BookItem fromJson(Map<String, dynamic> j) => BookItem(
        name: (j['name'] ?? '') as String,
        path: (j['path'] ?? '') as String,
        zip: (j['zip'] ?? '') as String,
        parent: (j['parent'] ?? '') as String,
        size: (j['size'] ?? '') as String,
        depth: (j['depth'] ?? 0) as int,
        hash: (j['hash'] ?? '') as String,
      );
}

/// קובץ בודד שאינו zip (דורות.csv), מתוך files_data.json.
class SingleFile {
  SingleFile({required this.path, required this.hash, required this.size});
  final String path;
  final String hash;
  final String size;
  Map<String, dynamic> toJson() => {'path': path, 'hash': hash, 'size': size};
  static SingleFile fromJson(Map<String, dynamic> j) => SingleFile(
        path: j['path'] as String,
        hash: (j['hash'] ?? '') as String,
        size: (j['size'] ?? '') as String,
      );
}

class RemovalEntry {
  RemovalEntry({required this.t, required this.path, this.to});
  final int t;
  final String path;
  final String? to;
  Map<String, dynamic> toJson() => {'t': t, 'path': path, if (to != null) 'to': to};
}

/// נתיב בטוח למחיקה: יחסי, בלי "." / "..", בלי backslash, אות כונן או תווי בקרה.
bool isSafePath(String? p) {
  if (p == null || p.isEmpty || p.length > 600) return false;
  if (RegExp(r'[\\\u0000-\u001f]').hasMatch(p) || RegExp(r'^/|^[A-Za-z]:').hasMatch(p)) return false;
  return p.split('/').every((s) => s.isNotEmpty && s != '.' && s != '..' && s.trim() == s);
}

List<RemovalEntry> parseRemovals(String text) {
  try {
    final d = jsonDecode(text);
    final arr = d is List ? d : (d is Map ? d['removed'] : null);
    if (arr is! List) return [];
    final out = <RemovalEntry>[];
    for (final e in arr) {
      if (e is! Map) continue;
      final t = e['t'];
      final path = e['path'];
      final to = e['to'];
      if (t is! num || path is! String || !isSafePath(path)) continue;
      if (to != null && (to is! String || !isSafePath(to))) continue;
      out.add(RemovalEntry(t: t.toInt(), path: path, to: to as String?));
    }
    return out;
  } catch (_) {
    return [];
  }
}

class RepoSnapshot {
  RepoSnapshot(this.items, this.files, this.removals);
  final List<BookItem> items;
  final List<SingleFile> files;
  final List<RemovalEntry> removals;
}

class DownloadCancelled implements Exception {}

class RepoException implements Exception {
  RepoException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RepoService {
  RepoService() {
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..userAgent = 'books-offline-update'
      ..autoUncompress = false;
  }

  late final HttpClient _client;

  Future<List<int>> _getBytes(String url, {Duration timeout = const Duration(seconds: 25)}) async {
    final req = await _client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw RepoException('שגיאת שרת ${res.statusCode}');
    }
    final b = BytesBuilder();
    await for (final c in res.timeout(timeout)) {
      b.add(c);
    }
    return b.takeBytes();
  }

  /// טוען קובץ טקסט מהמאגר: קודם raw, ואם נחסם (מסנן תוכן מחזיר עמוד חסימה) — דרך Contents API.
  Future<String> _text(String file, bool Function(String) valid) async {
    Object? last;
    try {
      final t = utf8.decode(await _getBytes('$_rawBase/$file?t=${DateTime.now().millisecondsSinceEpoch}'));
      if (valid(t)) return t;
    } catch (e) {
      last = e;
    }
    try {
      final j = jsonDecode(utf8.decode(await _getBytes('$_apiBase/$file?ref=main'))) as Map<String, dynamic>;
      final t = utf8.decode(base64.decode((j['content'] as String).replaceAll('\n', '')));
      if (valid(t)) return t;
    } catch (e) {
      last = e;
    }
    throw RepoException('לא ניתן לטעון את $file${last != null ? ' ($last)' : ''}');
  }

  Future<RepoSnapshot> fetchSnapshot() async {
    final books = await _text('books_data.js', (t) => t.contains('BOOKS_DATA'));
    final start = books.indexOf('[');
    final end = books.lastIndexOf(']');
    final items = (jsonDecode(books.substring(start, end + 1)) as List)
        .map((e) => BookItem.fromJson(e as Map<String, dynamic>))
        .where((i) => i.hash.isNotEmpty && i.zip.isNotEmpty)
        .toList();

    var files = <SingleFile>[];
    try {
      final t = await _text('files_data.json', (t) => t.trimLeft().startsWith('['));
      files = (jsonDecode(t) as List)
          .map((e) => SingleFile.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}

    var removals = <RemovalEntry>[];
    try {
      removals = parseRemovals(await _text('removed_files.json', (t) => t.trimLeft().startsWith('{') || t.trimLeft().startsWith('[')));
    } catch (_) {}

    return RepoSnapshot(items, files, removals);
  }

  Future<List<int>> fetchSingleFile(String repoPath) async {
    final url = '$_rawBase/ספרים/${Uri.encodeFull(repoPath)}';
    return _getBytes(url, timeout: const Duration(seconds: 60));
  }

  /// מוריד zip לקובץ זמני, עם המשכה בהפסקה ואימות MD5. מחזיר כשהקובץ תקין.
  Future<void> downloadZip(
    BookItem item,
    String destPath, {
    required void Function(int received, int? total) onProgress,
    required bool Function() isCancelled,
  }) async {
    final file = File(destPath);
    Object? lastError;
    for (var attempt = 0; attempt < 4; attempt++) {
      if (isCancelled()) throw DownloadCancelled();
      try {
        var have = await file.exists() ? await file.length() : 0;
        final req = await _client.getUrl(Uri.parse('$_latestDl/${item.zip}'));
        if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
        final res = await req.close().timeout(const Duration(seconds: 30));
        if (res.statusCode != 200 && res.statusCode != 206) {
          await res.drain<void>();
          if (res.statusCode == 416) {
            // כבר הורד במלואו — נבדוק hash למטה.
          } else {
            throw RepoException('שגיאת שרת ${res.statusCode}');
          }
        } else {
          if (res.statusCode == 200) have = 0; // השרת התעלם מ-Range
          final total = res.contentLength >= 0 ? res.contentLength + have : null;
          final sink = file.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
          var got = have;
          try {
            await for (final c in res.timeout(const Duration(seconds: 30))) {
              if (isCancelled()) {
                await sink.close();
                throw DownloadCancelled();
              }
              sink.add(c);
              got += c.length;
              onProgress(got, total);
            }
            await sink.flush();
          } finally {
            await sink.close();
          }
        }
        final md5sum = (await md5.bind(file.openRead()).first).toString();
        if (md5sum == item.hash) return;
        await file.delete();
        throw RepoException('בדיקת תקינות הקובץ נכשלה');
      } on DownloadCancelled {
        rethrow;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    throw RepoException('ההורדה של "${item.name}" נכשלה: $lastError');
  }

  void close() => _client.close(force: true);
}
