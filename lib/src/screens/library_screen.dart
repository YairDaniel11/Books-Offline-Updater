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

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final Set<String> _expanded = {};
  final TextEditingController _search = TextEditingController();
  bool _onlyChanges = false;

  AppController get c => widget.controller;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _hasChange(BookItem i) {
    if (c.statusOf(i) != ItemStatus.ok) return true;
    final ch = c.changesInside(i);
    return ch.added.isNotEmpty || ch.updated.isNotEmpty;
  }

  List<_Row> _visibleRows() {
    final q = _search.text.trim();
    final filtering = q.isNotEmpty || _onlyChanges;
    final kidsOf = <String, List<BookItem>>{};
    for (final i in c.books) {
      if (c.isIgnored(i)) continue;
      kidsOf.putIfAbsent(i.parent, () => []).add(i);
    }
    final out = <_Row>[];

    bool visit(BookItem n, int depth, List<_Row> sink) {
      final kids = kidsOf[n.path] ?? const <BookItem>[];
      final selfMatch = (q.isEmpty || n.name.contains(q)) && (!_onlyChanges || _hasChange(n));
      final sub = <_Row>[];
      var anyKid = false;
      for (final k in kids) {
        if (visit(k, depth + 1, sub)) anyKid = true;
      }
      if (!selfMatch && !anyKid) return false;
      final exp = filtering ? anyKid : _expanded.contains(n.path);
      sink.add(_Row(n, depth, kids.isNotEmpty, exp));
      if (exp) sink.addAll(sub);
      return true;
    }

    for (final r in c.books.where((i) => i.depth == 0 && !c.isIgnored(i))) {
      visit(r, 0, out);
    }
    return out;
  }

  void _toggle(String path) {
    setState(() {
      if (!_expanded.remove(path)) _expanded.add(path);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (c.items.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(AppTokens.spaceLG),
              child: Text('אין נתונים עדיין — התחבר לרשת והורד את המאגר', textAlign: TextAlign.center),
            ),
          );
        }
        final rows = _visibleRows();
        final theme = Theme.of(context);
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppTokens.spaceMD, AppTokens.spaceMD, AppTokens.spaceMD, 0),
                  child: _LinksCard(controller: c),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppTokens.spaceMD),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: 'חיפוש לפי שם',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.close),
                                    onPressed: () => setState(_search.clear),
                                  ),
                            isDense: true,
                            border: const OutlineInputBorder(borderRadius: AppTokens.borderRadiusAll),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppTokens.spaceSM),
                      FilterChip(
                        label: const Text('חדשים ועדכונים בלבד'),
                        selected: _onlyChanges,
                        onSelected: (v) => setState(() => _onlyChanges = v),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: rows.isEmpty
                      ? Center(
                          child: Text('לא נמצאו פריטים', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(AppTokens.spaceMD, 0, AppTokens.spaceMD, AppTokens.spaceMD),
                          itemCount: rows.length,
                          itemBuilder: (context, i) => _TreeRow(
                            row: rows[i],
                            controller: c,
                            onToggle: () => _toggle(rows[i].item.path),
                          ),
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

class _TreeRow extends StatelessWidget {
  const _TreeRow({required this.row, required this.controller, required this.onToggle});
  final _Row row;
  final AppController controller;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final item = row.item;
    final theme = Theme.of(context);
    final canAct = c.online && !c.readOnly && !c.busy;
    final status = c.statusOf(item);
    return InkWell(
      borderRadius: AppTokens.borderRadiusAll,
      onTap: row.hasKids ? onToggle : null,
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: row.depth * 20.0, top: 2, bottom: 2),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: row.hasKids ? Icon(row.expanded ? Icons.expand_more : Icons.chevron_left, size: 20) : null,
            ),
            Expanded(
              child: Text(
                item.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTokens.fontLG,
                  fontWeight: row.depth == 0 ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (item.size.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppTokens.spaceSM),
                child: Text(item.size,
                    style: TextStyle(fontSize: AppTokens.fontSM, color: theme.colorScheme.onSurfaceVariant)),
              ),
            _Chip(status: status),
            const SizedBox(width: AppTokens.spaceSM),
            SizedBox(
              width: 84,
              child: status == ItemStatus.ok
                  ? null
                  : OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 34),
                        shape: const RoundedRectangleBorder(borderRadius: AppTokens.borderRadiusAll),
                      ),
                      onPressed: canAct
                          ? () => c.downloadTargets(c.updateTargets(item), title: 'מוריד: ${item.name}')
                          : null,
                      child: Text(status == ItemStatus.update ? 'עדכן' : 'הורד'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.status});
  final ItemStatus status;

  @override
  Widget build(BuildContext context) {
    final (String text, Color color) = switch (status) {
      ItemStatus.ok => ('מעודכן', Colors.green),
      ItemStatus.update => ('יש עדכון', Colors.orange),
      ItemStatus.none => ('לא הורד', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: AppTokens.borderRadiusAll,
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(text, style: TextStyle(fontSize: AppTokens.fontSM, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _LinksCard extends StatelessWidget {
  const _LinksCard({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final canAct = c.online && !c.readOnly && !c.busy;
    final status = c.dorotStatus();
    return Card(
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(borderRadius: AppTokens.borderRadiusAll),
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.spaceMD),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.link, size: 20),
                      const SizedBox(width: AppTokens.spaceSM),
                      const Text('קישורים וסדר הדורות',
                          style: TextStyle(fontSize: AppTokens.fontLG, fontWeight: FontWeight.w600)),
                      const SizedBox(width: AppTokens.spaceSM),
                      _Chip(status: status),
                    ],
                  ),
                  const SizedBox(height: AppTokens.spaceXS),
                  Text(
                    'קבצים אלה מקשרים את ספרי המאגר למאגר הכללי של אוצריא; יש לייבא אותם באוצריא דרך '
                    'הגדרות ← ספרייה ← ייבוא דורות וקשרים',
                    style: TextStyle(
                        fontSize: AppTokens.fontMD, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppTokens.spaceMD),
            FilledButton(
              style: FilledButton.styleFrom(
                  shape: const RoundedRectangleBorder(borderRadius: AppTokens.borderRadiusAll)),
              onPressed: canAct
                  ? () => c.downloadTargets(
                        c.linksItem != null ? [c.linksItem!] : [],
                        includeLinks: true,
                        title: 'מוריד: קישורים וסדר הדורות',
                      )
                  : null,
              child: Text(status == ItemStatus.ok ? 'הורד שוב' : (status == ItemStatus.update ? 'עדכן' : 'הורד')),
            ),
          ],
        ),
      ),
    );
  }
}
