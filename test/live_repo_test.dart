import 'dart:io';

import 'package:books_offline_update/src/pak/pak_file.dart';
import 'package:books_offline_update/src/services/repo_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// בדיקת אינטגרציה מול GitHub האמיתי (דורשת רשת): הורדה, שמירה ב-PAK וחילוץ של אוסף קטן.
void main() {
  test('הורדה חיה → PAK → חילוץ', () async {
    final repo = RepoService();
    final snap = await repo.fetchSnapshot();
    expect(snap.items, isNotEmpty);
    final small = snap.items.where((i) => i.depth == 0 && i.size.endsWith('KB')).first;
    final tmp = await Directory.systemTemp.createTemp('live_');
    final zip = p.join(tmp.path, small.zip);
    await repo.downloadZip(small, zip, onProgress: (a, b) {}, isCancelled: () => false);
    final pak = await PakFile.openOrCreate(p.join(tmp.path, 'x.pak'));
    final seen = await pak.ingestZip(zip, small.path);
    await pak.commit();
    expect(seen, isNotEmpty);
    final out = p.join(tmp.path, 'out');
    for (final e in pak.files.entries) {
      await pak.extractTo(e.value, p.joinAll([out, ...e.key.split('/')]));
    }
    final count = Directory(out).listSync(recursive: true).whereType<File>().length;
    // ignore: avoid_print
    print('${small.path}: ${pak.files.length} קבצים, חולצו $count, removals=${snap.removals.length}, items=${snap.items.length}');
    expect(count, pak.files.length);
    await pak.close();
    repo.close();
    await tmp.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 3)),
      skip: Platform.environment['LIVE_TEST'] == null ? 'דורש רשת: הרץ עם LIVE_TEST=1' : null);
}
