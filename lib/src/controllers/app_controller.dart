import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../pak/pak_file.dart';
import '../services/app_paths.dart';
import '../services/repo_service.dart';

enum ItemStatus { none, ok, update }

/// התקדמות של פעולה ארוכה (הורדה / חילוץ), להצגה בכרטיס ההתקדמות.
class Activity {
  Activity(this.title);
  String title;
  String detail = '';
  double? progress; // null = לא מוגדר
  bool cancelled = false;
}

class AppController extends ChangeNotifier {
  AppController();

  final RepoService _repo = RepoService();

  String dataDir = '';
  PakFile? pak;
  String? fatalError;

  List<BookItem> items = [];
  List<SingleFile> singleFiles = [];
  List<RemovalEntry> removals = [];
  List<Map<String, dynamic>> tombstones = [];
  Map<String, String> hashes = {};
  int? lastUpdated; // epoch seconds של העדכון האחרון מהרשת

  bool online = false;
  bool checkingOnline = false;
  String? onlineError;

  bool ignoreShas = false;
  ThemeMode themeMode = ThemeMode.system;

  Activity? activity;
  String? lastMessage;
  bool lastMessageIsError = false;

  /// מונה ששינוי בו מבטל מטמונים תלויי-PAK.
  int _pakRev = 0;
  final Map<int, Set<String>> _pakPrefixCache = {};

  bool get busy => activity != null;
  bool get readOnly => pak?.readOnly ?? true;
  bool get hasData => items.isNotEmpty;

  // ─── אתחול ────────────────────────────────────────────────────────

  Future<void> init() async {
    dataDir = await AppPaths.dataDir();
    await _loadSettings();
    final path = p.join(dataDir, pakFileName);
    try {
      final exists = await File(path).exists();
      pak = await PakFile.openOrCreate(path);
      if (!exists) {
        // קובץ חדש: אין מה לטעון.
      }
      _loadMeta();
    } on FileSystemException catch (e) {
      fatalError = 'לא ניתן לפתוח או ליצור את קובץ המאגר בתיקייה "$dataDir".\n'
          'ניתן לבחור תיקייה אחרת בהגדרות.\n(${e.osError?.message ?? e.message})';
    } on FormatException catch (e) {
      fatalError = 'קובץ המאגר ($path) אינו תקין: ${e.message}';
    }
    notifyListeners();
    if (fatalError == null) await checkOnline();
  }

  void _loadMeta() {
    final m = pak!.meta;
    items = ((m['items'] as List?) ?? []).map((e) => BookItem.fromJson(e as Map<String, dynamic>)).toList();
    singleFiles = ((m['files'] as List?) ?? []).map((e) => SingleFile.fromJson(e as Map<String, dynamic>)).toList();
    removals = parseRemovals(jsonEncode(m['removals'] ?? []));
    tombstones = ((m['tombstones'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    hashes = ((m['hashes'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, v as String));
    lastUpdated = m['updated'] as int?;
    _pakRev++;
  }

  void _storeMeta() {
    final m = pak!.meta;
    m['items'] = items.map((e) => e.toJson()).toList();
    m['files'] = singleFiles.map((e) => e.toJson()).toList();
    m['removals'] = removals.map((e) => e.toJson()).toList();
    m['tombstones'] = tombstones;
    m['hashes'] = hashes;
    if (lastUpdated != null) m['updated'] = lastUpdated;
    _pakRev++;
  }

  Future<void> _commit() async {
    _storeMeta();
    await pak!.commit();
  }

  // ─── הגדרות ───────────────────────────────────────────────────────

  File get _settingsFile => File(p.join(dataDir, 'settings.json'));

  Future<void> _loadSettings() async {
    try {
      final j = jsonDecode(await _settingsFile.readAsString()) as Map<String, dynamic>;
      ignoreShas = j['ignoreShas'] == true;
      themeMode = switch (j['theme']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    try {
      await _settingsFile.writeAsString(jsonEncode({
        'ignoreShas': ignoreShas,
        'theme': themeMode.name,
      }));
    } catch (_) {
      // כונן לקריאה בלבד: ההגדרות נשארות לריצה הנוכחית.
    }
  }

  void setIgnoreShas(bool v) {
    ignoreShas = v;
    _saveSettings();
    notifyListeners();
  }

  void setThemeMode(ThemeMode m) {
    themeMode = m;
    _saveSettings();
    notifyListeners();
  }

  Future<void> changeDataDir(String? dir) async {
    if (busy) return;
    await pak?.close();
    pak = null;
    fatalError = null;
    items = [];
    singleFiles = [];
    hashes = {};
    await AppPaths.setDataDirOverride(dir);
    await init();
  }

  // ─── רשת ──────────────────────────────────────────────────────────

  Future<void> checkOnline() async {
    if (checkingOnline || pak == null) return;
    checkingOnline = true;
    onlineError = null;
    notifyListeners();
    try {
      final snap = await _repo.fetchSnapshot();
      online = true;
      items = snap.items;
      singleFiles = snap.files;
      removals = snap.removals;
      if (!pak!.readOnly) {
        lastUpdated ??= null;
        await _commit();
      }
    } catch (e) {
      online = false;
      onlineError = e is RepoException ? e.message : 'אין חיבור לרשת';
    }
    checkingOnline = false;
    notifyListeners();
  }

  // ─── סטטוס (בהתאם לתוסף) ─────────────────────────────────────────

  static const _linksPath = 'קבצי קישורים וסדר הדורות';

  bool isLinks(BookItem i) => i.path == _linksPath || i.path.startsWith('$_linksPath/');

  List<BookItem> get books => items.where((i) => !isLinks(i)).toList();

  BookItem? get linksItem {
    for (final i in items) {
      if (i.path == _linksPath) return i;
    }
    return null;
  }

  String? get shasPath {
    for (final i in items) {
      if (i.path.endsWith('תלמוד בבלי/שס וגשל')) return i.path;
    }
    return null;
  }

  bool isIgnored(BookItem i) {
    final s = shasPath;
    return ignoreShas && s != null && (i.path == s || i.path.startsWith('$s/'));
  }

  bool hasIgnoredInside(BookItem i) {
    final s = shasPath;
    return ignoreShas && s != null && s.startsWith('${i.path}/');
  }

  List<BookItem> children(BookItem i) => items.where((c) => c.parent == i.path).toList();

  List<BookItem> subtree(BookItem item, {bool respectIgnore = false}) {
    final prefix = '${item.path}/';
    return items
        .where((i) => (i.path == item.path || i.path.startsWith(prefix)) && !(respectIgnore && isIgnored(i)))
        .toList();
  }

  ItemStatus statusOf(BookItem item) {
    if (!hasIgnoredInside(item)) {
      final stored = hashes[item.key];
      if (stored == null) return ItemStatus.none;
      return stored == item.hash ? ItemStatus.ok : ItemStatus.update;
    }
    final subs = subtree(item, respectIgnore: true).where((n) => n.path != item.path).toList();
    if (!subs.any((n) => hashes[n.key] != null)) return ItemStatus.none;
    return subs.every((n) => hashes[n.key] == n.hash) ? ItemStatus.ok : ItemStatus.update;
  }

  ({List<BookItem> added, List<BookItem> updated}) changesInside(BookItem item) {
    final added = <BookItem>[], updated = <BookItem>[];
    for (final n in subtree(item, respectIgnore: true)) {
      if (n.path == item.path) continue;
      final s = hashes[n.key];
      if (s == null) {
        added.add(n);
      } else if (s != n.hash) {
        updated.add(n);
      }
    }
    return (added: added, updated: updated);
  }

  List<BookItem> updateTargets(BookItem item) {
    if (!hasIgnoredInside(item)) return [item];
    final c = changesInside(item);
    final changed = [...c.added, ...c.updated];
    return changed.where((n) => !changed.any((o) => o.path != n.path && n.path.startsWith('${o.path}/'))).toList();
  }

  ({int ok, int update, int none}) get summary {
    var ok = 0, up = 0, none = 0;
    for (final i in books.where((i) => i.depth == 0)) {
      switch (statusOf(i)) {
        case ItemStatus.ok:
          ok++;
        case ItemStatus.update:
          up++;
        case ItemStatus.none:
          none++;
      }
    }
    return (ok: ok, update: up, none: none);
  }

  /// פריטי שורש שצריך להוריד/לעדכן (בלי קבצי הקישורים).
  List<BookItem> pendingTargets({required bool onlyUpdates}) {
    final out = <BookItem>[];
    for (final n in books.where((i) => i.depth == 0)) {
      final s = statusOf(n);
      if (s == ItemStatus.ok) continue;
      if (onlyUpdates && s != ItemStatus.update) continue;
      out.addAll(s == ItemStatus.none ? (hasIgnoredInside(n) ? updateTargets(n) : [n]) : updateTargets(n));
    }
    return out;
  }

  SingleFile? get dorotFile {
    for (final f in singleFiles) {
      if (f.path == '$_linksPath/דורות.csv') return f;
    }
    return null;
  }

  ItemStatus dorotStatus() {
    final f = dorotFile;
    if (f == null) return ItemStatus.none;
    final s = hashes[f.path];
    if (s == null) return ItemStatus.none;
    return s == f.hash ? ItemStatus.ok : ItemStatus.update;
  }

  // ─── תוכן ה-PAK ───────────────────────────────────────────────────

  Set<String> _prefixesInPak() {
    return _pakPrefixCache.putIfAbsent(_pakRev, () {
      _pakPrefixCache.clear();
      final out = <String>{};
      for (final path in pak?.files.keys ?? const <String>[]) {
        var i = path.indexOf('/');
        while (i > 0) {
          out.add(path.substring(0, i));
          i = path.indexOf('/', i + 1);
        }
      }
      return out;
    });
  }

  bool inPak(BookItem i) => _prefixesInPak().contains(i.path);

  int get pakFileCount => pak?.files.length ?? 0;

  // ─── עזרי הודעות ──────────────────────────────────────────────────

  void _msg(String text, {bool error = false}) {
    lastMessage = text;
    lastMessageIsError = error;
    notifyListeners();
  }

  void clearMessage() {
    lastMessage = null;
    notifyListeners();
  }

  void cancelActivity() {
    activity?.cancelled = true;
    notifyListeners();
  }

  void _progress(String detail, [double? progress]) {
    final a = activity;
    if (a == null) return;
    a.detail = detail;
    a.progress = progress;
    notifyListeners();
  }

  // ─── הורדה ל-PAK ──────────────────────────────────────────────────

  Future<void> downloadTargets(List<BookItem> targets, {required String title, bool includeLinks = false}) async {
    if (busy || pak == null || pak!.readOnly) return;
    if (targets.isEmpty && !includeLinks) {
      _msg('הכול כבר מעודכן');
      return;
    }
    activity = Activity(title);
    lastMessage = null;
    notifyListeners();

    var ok = 0;
    final failed = <String>[];
    try {
      for (var i = 0; i < targets.length; i++) {
        if (activity!.cancelled) break;
        final r = await _downloadRecursive(targets[i], '${i + 1}/${targets.length}');
        ok += r.ok;
        failed.addAll(r.failed);
      }
      if (includeLinks && !activity!.cancelled) {
        await _downloadLinks(failed);
      }
      await _applyRemovalsToPak();
      lastUpdated = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _commit();
      await _maybeCompact();
    } catch (e) {
      failed.add('$e');
    } finally {
      final cancelled = activity?.cancelled ?? false;
      activity = null;
      if (cancelled) {
        _msg('הפעולה נעצרה. מה שכבר ירד נשמר במאגר.');
      } else if (failed.isEmpty) {
        _msg('הושלם: $ok אוספים נשמרו במאגר.');
      } else {
        _msg('${failed.length} כשלים: ${failed.take(3).join(' | ')}', error: true);
      }
    }
  }

  Future<({int ok, List<String> failed})> _downloadRecursive(BookItem node, String counter) async {
    if (activity!.cancelled) return (ok: 0, failed: <String>[]);

    if (hasIgnoredInside(node)) {
      var ok = 0;
      final failed = <String>[];
      for (final c in children(node).where((c) => !isIgnored(c))) {
        final r = await _downloadRecursive(c, counter);
        ok += r.ok;
        failed.addAll(r.failed);
      }
      return (ok: ok, failed: failed);
    }

    final err = await _downloadOne(node, counter);
    if (err == null) return (ok: 1, failed: <String>[]);
    if (activity!.cancelled) return (ok: 0, failed: <String>[]);

    final kids = children(node);
    if (kids.isEmpty) return (ok: 0, failed: <String>['${node.name}: $err']);
    var ok = 0;
    final failed = <String>[];
    for (final c in kids) {
      final r = await _downloadRecursive(c, counter);
      ok += r.ok;
      failed.addAll(r.failed);
    }
    if (failed.isEmpty && !activity!.cancelled) {
      for (final n in subtree(node)) {
        hashes[n.key] = n.hash;
      }
    }
    return (ok: ok, failed: failed);
  }

  /// מוריד אוסף אחד ל-PAK. מחזיר `null` בהצלחה, אחרת תיאור כשל.
  Future<String?> _downloadOne(BookItem node, String counter) async {
    final tmpDir = Directory(p.join(dataDir, '.download_tmp'));
    await tmpDir.create(recursive: true);
    final zipPath = p.join(tmpDir.path, node.zip);
    try {
      await _repo.downloadZip(
        node,
        zipPath,
        onProgress: (got, total) => _progress(
          '[$counter] מוריד: ${node.name}${total != null ? ' (${_mb(got)} מתוך ${_mb(total)})' : ''}',
          total != null ? got / total : null,
        ),
        isCancelled: () => activity?.cancelled ?? true,
      );
      _progress('[$counter] שומר במאגר: ${node.name}', null);
      final seen = await pak!.ingestZip(
        zipPath,
        node.path,
        onProgress: (d, t) => _progress('[$counter] שומר במאגר: ${node.name}', d / t),
        isCancelled: () => activity?.cancelled ?? true,
      );
      if (activity?.cancelled ?? false) return 'בוטל';
      // ה-zip הוא כל תוכן התיקייה: מה שנעלם ממנו נמחק גם מהמאגר.
      final gone = pak!.pruneUnder(node.path, seen);
      for (final g in gone) {
        _addTombstone(g);
      }
      for (final n in subtree(node)) {
        hashes[n.key] = n.hash;
      }
      await _reconcileAncestors(node);
      // התקדמות נשמרת אחרי כל אוסף, כדי שהפסקה לא תאבד עבודה.
      await _commit();
      return null;
    } on DownloadCancelled {
      return 'בוטל';
    } catch (e) {
      return '$e';
    } finally {
      try {
        await File(zipPath).delete();
      } catch (_) {}
    }
  }

  Future<void> _downloadLinks(List<String> failed) async {
    final f = dorotFile;
    if (f == null) return;
    _progress('מוריד: דורות.csv', null);
    try {
      final bytes = await _repo.fetchSingleFile(f.path);
      await pak!.putBytes(f.path, Uint8List.fromList(bytes));
      hashes[f.path] = f.hash;
    } catch (e) {
      failed.add('דורות.csv: $e');
    }
  }

  Future<void> _reconcileAncestors(BookItem node) async {
    var path = node.parent;
    while (path.isNotEmpty) {
      final anc = items.where((i) => i.path == path).firstOrNull;
      if (anc == null || hasIgnoredInside(anc)) break;
      final c = changesInside(anc);
      if (c.added.isNotEmpty || c.updated.isNotEmpty) break;
      hashes[anc.key] = anc.hash;
      path = anc.parent;
    }
  }

  void _addTombstone(String path) {
    tombstones.removeWhere((t) => t['path'] == path);
    tombstones.add({'path': path, 't': DateTime.now().millisecondsSinceEpoch ~/ 1000});
  }

  /// מחיל את removed_files.json על ה-PAK: נתיב שהוסר או הועבר נמחק (העברה — רק אחרי שהיעד קיים).
  Future<void> _applyRemovalsToPak() async {
    for (final r in removals) {
      if (pak!.files.containsKey(r.path) && (r.to == null || pak!.files.containsKey(r.to))) {
        pak!.remove(r.path);
        _addTombstone(r.path);
      }
    }
    // נתיב שחזר להתקיים אינו עוד "שנמחק".
    tombstones.removeWhere((t) => pak!.files.containsKey(t['path']));
  }

  Future<void> _maybeCompact() async {
    final dead = pak!.deadBytes;
    if (dead < 50 * 1024 * 1024 || dead < pak!.fileLength * 0.1) return;
    await compactNow(silent: true);
  }

  Future<void> compactNow({bool silent = false}) async {
    if (pak == null || pak!.readOnly) return;
    final path = pak!.path;
    final startedHere = activity == null;
    if (startedHere) {
      activity = Activity('מצמצם את קובץ המאגר');
      notifyListeners();
    }
    try {
      _progress('כותב מחדש בלי מקום מיותר...', 0);
      final saved = await pak!.compact(onProgress: (v) => _progress('כותב מחדש בלי מקום מיותר...', v));
      pak = await PakFile.openOrCreate(path, allowCreate: false);
      _loadMeta();
      if (!silent) _msg('הקובץ צומצם. נחסכו ${_mb(saved)}.');
    } catch (e) {
      pak = await PakFile.openOrCreate(path, allowCreate: false);
      _loadMeta();
      _msg('הצמצום נכשל: $e', error: true);
    } finally {
      if (startedHere) {
        activity = null;
        notifyListeners();
      }
    }
  }

  Future<void> resetStatuses() async {
    hashes = {};
    if (pak != null && !pak!.readOnly) await _commit();
    notifyListeners();
  }

  // ─── חילוץ מה-PAK ─────────────────────────────────────────────────

  /// מחלץ אל [destDir]. [prefixes] = null → הכול; אחרת רק הנתיבים שתחת התיקיות שנבחרו.
  Future<void> extract(String destDir, {List<String>? prefixes}) async {
    if (busy || pak == null) return;
    activity = Activity('מחלץ אל $destDir');
    lastMessage = null;
    notifyListeners();

    final entries = pak!.files.entries.where((e) {
      if (prefixes == null) return true;
      return prefixes.any((pre) => e.key == pre || e.key.startsWith('$pre/'));
    }).toList()
      ..sort((a, b) => a.value.offset.compareTo(b.value.offset));

    final totalBytes = entries.fold<int>(0, (s, e) => s + e.value.size);
    var doneBytes = 0, copied = 0, skipped = 0, deleted = 0;
    final failed = <String>[];
    try {
      for (final e in entries) {
        if (activity!.cancelled) break;
        final target = p.joinAll([destDir, ...e.key.split('/')]);
        final f = File(target);
        var same = false;
        if (await f.exists()) {
          final st = await f.stat();
          same = st.size == e.value.size && st.modified.millisecondsSinceEpoch ~/ 1000 == e.value.version;
        }
        if (same) {
          skipped++;
        } else {
          try {
            await pak!.extractTo(e.value, target);
            copied++;
          } catch (err) {
            failed.add('${e.key}: $err');
          }
        }
        doneBytes += e.value.size;
        _progress(
          'מחלץ: ${p.basename(e.key)}  (${copied + skipped + failed.length}/${entries.length})',
          totalBytes > 0 ? doneBytes / totalBytes : null,
        );
      }
      if (!activity!.cancelled) deleted = await _cleanupDestination(destDir, prefixes);
    } catch (e) {
      failed.add('$e');
    } finally {
      final cancelled = activity?.cancelled ?? false;
      activity = null;
      final parts = <String>[
        '$copied קבצים חולצו',
        if (skipped > 0) '$skipped כבר היו עדכניים',
        if (deleted > 0) '$deleted ישנים נמחקו',
      ];
      if (cancelled) {
        _msg('החילוץ נעצר (${parts.join(', ')}).');
      } else if (failed.isEmpty) {
        _msg('החילוץ הושלם: ${parts.join(', ')}.');
      } else {
        _msg('${parts.join(', ')}. ${failed.length} כשלים: ${failed.take(3).join(' | ')}', error: true);
      }
    }
  }

  /// מוחק ביעד קבצים ישנים שהוסרו או הועברו במאגר, כדי שלא יישארו כפולים אחרי עדכון.
  Future<int> _cleanupDestination(String destDir, List<String>? prefixes) async {
    bool inScope(String path) =>
        prefixes == null || prefixes.any((pre) => path == pre || path.startsWith('$pre/'));
    final candidates = <String>{};
    for (final r in removals) {
      if (inScope(r.path) || (r.to != null && inScope(r.to!))) candidates.add(r.path);
    }
    for (final t in tombstones) {
      final path = t['path'] as String;
      if (inScope(path)) candidates.add(path);
    }
    var n = 0;
    for (final path in candidates) {
      if (!isSafePath(path) || pak!.files.containsKey(path)) continue;
      final f = File(p.joinAll([destDir, ...path.split('/')]));
      try {
        if (await f.exists()) {
          await f.delete();
          n++;
        }
      } catch (_) {}
    }
    return n;
  }

  static String _mb(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).ceil()} KB';
  }

  static String formatBytes(int b) => _mb(b);

  @override
  void dispose() {
    pak?.close();
    _repo.close();
    super.dispose();
  }
}
