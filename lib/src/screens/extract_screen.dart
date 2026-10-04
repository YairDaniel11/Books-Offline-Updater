import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import '../services/repo_service.dart';
import '../theme/app_tokens.dart';

class _Row {
  _Row(this.item, this.depth, this.hasKids, this.expanded);
  final BookItem item;
  final int depth;
  final bool hasKids;
  final bool expanded;
}

class ExtractScreen extends StatefulWidget {
  const ExtractScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<ExtractScreen> createState() => _ExtractScreenState();
}

class _ExtractScreenState extends State<ExtractScreen> {
  final Set<String> _expanded = {};
  final Set<String> _selected = {};
  final TextEditingController _search = TextEditingController();

  AppController get c => widget.controller;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Map<String, List<BookItem>> _kidsMap(List<BookItem> all) {
    final paths = all.map((e) => e.path).toSet();
    final m = <String, List<BookItem>>{};
    for (final i in all) {
      m.putIfAbsent(paths.contains(i.parent) ? i.parent : '', () => []).add(i);
    }
    return m;
  }

  List<BookItem> _subtree(BookItem n, Map<String, List<BookItem>> kids) {
    final out = <BookItem>[n];
    for (final k in kids[n.path] ?? const <BookItem>[]) {
      out.addAll(_subtree(k, kids));
    }
    return out;
  }

  List<_Row> _rows(Map<String, List<BookItem>> kids) {
    final q = _search.text.trim();
    final out = <_Row>[];
    bool visit(BookItem n, int depth, List<_Row> sink) {
      final ks = kids[n.path] ?? const <BookItem>[];
      final sub = <_Row>[];
      var any = false;
      for (final k in ks) {
        if (visit(k, depth + 1, sub)) any = true;
      }
      final self = q.isEmpty || n.name.contains(q);
      if (!self && !any) return false;
      final exp = q.isNotEmpty ? any : _expanded.contains(n.path);
      sink.add(_Row(n, depth, ks.isNotEmpty, exp));
      if (exp) sink.addAll(sub);
      return true;
    }

    for (final r in kids[''] ?? const <BookItem>[]) {
      visit(r, 0, out);
    }
    return out;
  }

  bool? _stateOf(BookItem n, Map<String, List<BookItem>> kids) {
    final sub = _subtree(n, kids);
    final sel = sub.where((e) => _selected.contains(e.path)).length;
    if (sel == 0) return false;
    if (sel == sub.length) return true;
    return null;
  }

  void _toggleSelect(BookItem n, Map<String, List<BookItem>> kids) {
    final st = _stateOf(n, kids);
    final sub = _subtree(n, kids);
    setState(() {
      for (final e in sub) {
        if (st == true) {
          _selected.remove(e.path);
        } else {
          _selected.add(e.path);
        }
      }
    });
  }

  /// הנתיבים העליונים ביותר שנבחרו (בלי צאצאים של תיקייה שכבר נבחרה).
  List<String> _topPrefixes() {
    final out = <String>[];
    for (final p in _selected) {
      var covered = false;
      var i = p.lastIndexOf('/');
      while (i > 0) {
        if (_selected.contains(p.substring(0, i))) {
          covered = true;
          break;
        }
        i = p.lastIndexOf('/', i - 1);
      }
      if (!covered) out.add(p);
    }
    out.sort();
    return out;
  }

  Future<void> _run({List<String>? prefixes}) async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'בחר תיקייה לחילוץ הקבצים');
    if (dir == null || !mounted) return;
    await c.extract(dir, prefixes: prefixes);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final theme = Theme.of(context);
        final all = c.items.where(c.inPak).toList();
        final kids = _kidsMap(all);
        final rows = _rows(kids);
        final tops = _topPrefixes();
        final busy = c.busy;
        final total = c.pak?.totalUncompressed;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppTokens.spaceMD),
                  child: Card(
                    margin: EdgeInsets.zero,
                    shape: const RoundedRectangleBorder(borderRadius: AppTokens.borderRadiusAll),
                    child: Padding(
                      padding: const EdgeInsets.all(AppTokens.spaceMD),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('חילוץ למחשב',
                              style: TextStyle(fontSize: AppTokens.fontXL, fontWeight: FontWeight.w600)),
                          const SizedBox(height: AppTokens.spaceXS),
                          Text(
                            'במאגר ${c.pakFileCount} קבצים'
                            '${total != null ? ' (${AppController.formatBytes(total)} לא דחוס)' : ''}',
                            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                          ),
                          Text(
                            'החילוץ אינו מוחק את המאגר — אפשר לחלץ למחשבים רבים. '
                            'קבצים שכבר עדכניים ביעד מדולגים.',
                            style:
                                TextStyle(fontSize: AppTokens.fontSM, color: theme.colorScheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: AppTokens.spaceMD),
                          Wrap(
                            spacing: AppTokens.spaceSM,
                            runSpacing: AppTokens.spaceSM,
                            children: [
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                    shape: const RoundedRectangleBorder(borderRadius: AppTokens.borderRadiusAll)),
                                onPressed: busy || c.pakFileCount == 0 ? null : () => _run(),
                                icon: const Icon(Icons.folder_open),
                                label: const Text('חלץ הכול…'),
                              ),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                    shape: const RoundedRectangleBorder(borderRadius: AppTokens.borderRadiusAll)),
                                onPressed: busy || tops.isEmpty ? null : () => _run(prefixes: tops),
                                icon: const Icon(Icons.checklist),
                                label: Text('חלץ את הנבחרים (${tops.length})…'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppTokens.spaceMD, 0, AppTokens.spaceMD, AppTokens.spaceMD),
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'חיפוש לפי שם',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_search.clear)),
                      isDense: true,
                      border: const OutlineInputBorder(borderRadius: AppTokens.borderRadiusAll),
                    ),
                  ),
                ),
                Expanded(
                  child: rows.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(AppTokens.spaceLG),
                            child: Text(
                              all.isEmpty ? 'אין עדיין קבצים במאגר' : 'לא נמצאו פריטים',
                              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(AppTokens.spaceMD, 0, AppTokens.spaceMD, AppTokens.spaceMD),
                          itemCount: rows.length,
                          itemBuilder: (context, i) {
                            final r = rows[i];
                            return Padding(
                              padding: EdgeInsetsDirectional.only(start: r.depth * 20.0),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 32,
                                    child: r.hasKids
                                        ? IconButton(
                                            padding: EdgeInsets.zero,
                                            iconSize: 20,
                                            icon: Icon(r.expanded ? Icons.expand_more : Icons.chevron_left),
                                            onPressed: () => setState(() {
                                              if (!_expanded.remove(r.item.path)) _expanded.add(r.item.path);
                                            }),
                                          )
                                        : null,
                                  ),
                                  Checkbox(
                                    tristate: true,
                                    value: _stateOf(r.item, kids),
                                    onChanged: (_) => _toggleSelect(r.item, kids),
                                  ),
                                  Expanded(
                                    child: InkWell(
                                      borderRadius: AppTokens.borderRadiusAll,
                                      onTap: () => _toggleSelect(r.item, kids),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 8),
                                        child: Text(
                                          r.item.name,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: AppTokens.fontLG,
                                            fontWeight: r.depth == 0 ? FontWeight.w600 : FontWeight.normal,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
