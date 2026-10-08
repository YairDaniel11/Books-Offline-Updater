import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../services/app_paths.dart';
import '../services/repo_service.dart' show DownloadCancelled;

/// מספר הגרסה של הבנייה הזו. ה-CI מזריק אותו (`--dart-define=APP_VERSION=0.1.4`); בהרצה מהפיתוח הוא ריק.
const appVersion = String.fromEnvironment('APP_VERSION');

const appRepo = 'YairDaniel11/Books-Offline-Updater';
const releasesPageUrl = 'https://github.com/$appRepo/releases';
const _latestApi = 'https://api.github.com/repos/$appRepo/releases/latest';

/// "v0.1.4" או "0.1.4" ← [0,1,4]; `null` אם אינו מספר גרסה.
List<int>? parseVersion(String v) {
  final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(v.trim());
  if (m == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
}

bool isNewerVersion(String latest, String current) {
  final a = parseVersion(latest);
  final b = parseVersion(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

class UpdateInfo {
  UpdateInfo({required this.version, required this.url, required this.size, required this.sha256, required this.notes});
  final String version;
  final String url;
  final int size;
  final String? sha256;
  final String notes;
}

enum UpdateState { idle, checking, available, downloading, restarting, error }

/// בדיקת גרסה חדשה ב-GitHub Releases, הורדה, והחלפה עצמית: התוכנה נסגרת, הקובץ מוחלף והגרסה החדשה נפתחת.
class UpdateController extends ChangeNotifier {
  UpdateController({this.beforeRestart});

  /// נקרא אחרי ההחלפה ולפני שהגרסה החדשה נפתחת (סגירת קבצים פתוחים, כמו ה-PAK).
  final Future<void> Function()? beforeRestart;

  UpdateState state = UpdateState.idle;
  UpdateInfo? info;
  String? error;
  double? progress;
  bool dismissed = false;

  bool _cancel = false;

  /// עדכון עצמי אפשרי רק בבנייה מסודרת (גרסה ידועה) וכשיש קובץ ברור להחליף.
  bool get canSelfUpdate => appVersion.isNotEmpty && AppPaths.selfUpdateTarget() != null;

  bool get showBanner =>
      !dismissed && (state == UpdateState.available || state == UpdateState.downloading || state == UpdateState.restarting || (state == UpdateState.error && info != null));

  void dismiss() {
    if (state == UpdateState.downloading) return;
    dismissed = true;
    notifyListeners();
  }

  void cancelDownload() {
    _cancel = true;
  }

  Future<void> check({bool manual = false}) async {
    if (state == UpdateState.checking || state == UpdateState.downloading) return;
    if (appVersion.isEmpty) {
      if (manual) {
        error = 'זוהי בנייה לפיתוח ללא מספר גרסה.';
        state = UpdateState.error;
        notifyListeners();
      }
      return;
    }
    state = UpdateState.checking;
    error = null;
    notifyListeners();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'books-offline-update';
    try {
      final req = await client.getUrl(Uri.parse(_latestApi));
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException('שגיאת שרת ${res.statusCode}');
      }
      final j = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final tag = (j['tag_name'] as String?) ?? '';
      if (!isNewerVersion(tag, appVersion)) {
        info = null;
        state = UpdateState.idle;
        if (manual) {
          error = null;
          dismissed = false;
        }
        notifyListeners();
        return;
      }
      final wanted = Platform.isMacOS ? 'BooksOfflineUpdate-macos.zip' : 'BooksOfflineUpdate.exe';
      Map<String, dynamic>? asset;
      for (final a in (j['assets'] as List? ?? const [])) {
        if (a is Map<String, dynamic> && a['name'] == wanted) asset = a;
      }
      if (asset == null) throw const HttpException('הגרסה החדשה אינה כוללת קובץ מתאים לפלטפורמה');
      final digest = asset['digest'] as String?;
      info = UpdateInfo(
        version: tag.startsWith('v') ? tag.substring(1) : tag,
        url: asset['browser_download_url'] as String,
        size: (asset['size'] as num?)?.toInt() ?? 0,
        sha256: digest != null && digest.startsWith('sha256:') ? digest.substring(7) : null,
        notes: (j['body'] as String?) ?? '',
      );
      dismissed = false;
      state = UpdateState.available;
    } catch (e) {
      // בדיקה אוטומטית שנכשלה (אין רשת) שקטה; רק בדיקה ידנית מציגה שגיאה.
      state = UpdateState.idle;
      if (manual) {
        error = 'לא ניתן לבדוק גרסה חדשה ($e)';
        state = UpdateState.error;
      }
    } finally {
      client.close(force: true);
    }
    notifyListeners();
  }

  /// מוריד את הגרסה החדשה, ובסיומה סוגר את התוכנה ופותח את החדשה.
  Future<void> downloadAndRestart() async {
    final i = info;
    final target = AppPaths.selfUpdateTarget();
    if (i == null || target == null || state == UpdateState.downloading) return;
    _cancel = false;
    state = UpdateState.downloading;
    progress = null;
    error = null;
    notifyListeners();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'books-offline-update';
    // ב-Windows הקובץ החדש נשמר ליד הישן (אותו כונן, אותן הרשאות); ב-Mac בתיקייה זמנית.
    final dl = File(Platform.isMacOS
        ? p.join(Directory.systemTemp.path, 'BooksOfflineUpdate-${i.version}.zip')
        : '$target.new');
    try {
      final req = await client.getUrl(Uri.parse(i.url));
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException('שגיאת שרת ${res.statusCode}');
      }
      final total = res.contentLength > 0 ? res.contentLength : (i.size > 0 ? i.size : null);
      final sink = dl.openWrite();
      final digestOut = _DigestBox();
      final hasher = sha256.startChunkedConversion(digestOut);
      var got = 0;
      try {
        await for (final c in res.timeout(const Duration(seconds: 30))) {
          if (_cancel) throw DownloadCancelled();
          sink.add(c);
          hasher.add(c);
          got += c.length;
          if (total != null) {
            progress = got / total;
            notifyListeners();
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
        hasher.close();
      }
      if (i.sha256 != null && digestOut.value.toString() != i.sha256) {
        throw const HttpException('בדיקת תקינות הקובץ נכשלה');
      }
      state = UpdateState.restarting;
      notifyListeners();
      if (Platform.isMacOS) {
        await _restartMac(dl, target);
      } else {
        await _restartWindows(dl, target);
      }
      // נותנים לתהליך ההחלפה להתחיל ואז נסגרים (בנתיב ה-SFX זה גם משחרר את קובץ ה-exe המקורי).
      await Future<void>.delayed(const Duration(milliseconds: 400));
      exit(0);
    } on DownloadCancelled {
      await _tryDelete(dl);
      state = UpdateState.available;
    } catch (e) {
      await _tryDelete(dl);
      error = 'העדכון נכשל: $e';
      state = UpdateState.error;
    } finally {
      client.close(force: true);
    }
    notifyListeners();
  }

  Future<void> _tryDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Windows: אי אפשר למחוק או לדרוס קובץ שרץ, אבל אפשר לשנות את שמו. לכן מחליפים בתוך התהליך עצמו
  /// (הישן ← `.old`, החדש ← השם המקורי), מפעילים את החדש וסוגרים. ה-`.old` נמחק בהפעלה הבאה.
  /// (סקריפט PowerShell מנותק לא עבד: התהליך המנותק לא הספיק לבצע את ההחלפה.)
  Future<void> _restartWindows(File downloaded, String target) async {
    final old = File('$target.old');
    try {
      if (await old.exists()) await old.delete();
    } catch (_) {}
    await File(target).rename(old.path);
    try {
      await downloaded.rename(target);
    } catch (e) {
      await old.rename(target); // החזרה למצב הקודם
      rethrow;
    }
    await beforeRestart?.call();
    await Process.start(target, const [], mode: ProcessStartMode.detached);
  }

  /// מוחק שאריות של עדכון קודם (בהפעלה).
  static Future<void> cleanupLeftovers() async {
    final t = AppPaths.selfUpdateTarget();
    if (t == null || !Platform.isWindows) return;
    for (final n in ['$t.old', '$t.new']) {
      try {
        final f = File(n);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<void> _restartMac(File zip, String target) async {
    final dir = Directory(p.join(Directory.systemTemp.path, 'BooksOfflineUpdate-new-$pid'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final r = await Process.run('ditto', ['-x', '-k', zip.path, dir.path]);
    if (r.exitCode != 0) throw const HttpException('פתיחת קובץ ה-zip נכשלה');
    String? app;
    await for (final e in dir.list()) {
      if (e is Directory && e.path.endsWith('.app')) app = e.path;
    }
    if (app == null) throw const HttpException('לא נמצאה אפליקציה בתוך הקובץ');
    await zip.delete();
    await Process.start(
      'sh',
      [
        '-c',
        r'while kill -0 "$0" 2>/dev/null; do sleep 0.5; done; rm -rf "$1" && mv "$2" "$1" && open "$1"',
        '$pid',
        target,
        app,
      ],
      mode: ProcessStartMode.detached,
    );
  }
}

class _DigestBox implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
