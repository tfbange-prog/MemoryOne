import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show OrderingMode, OrderingTerm;
import 'package:intl/intl.dart';

import '../db/app_db.dart';
import '../settings/app_settings.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:url_launcher/url_launcher.dart';

String? _extractUrl(String text) {
  final regExp = RegExp(r'https?://[a-zA-Z0-9\-\.]+\.[a-zA-Z]{2,}(?:/[^ \s]*)?');
  final match = regExp.firstMatch(text);
  return match?.group(0);
}

class DisplayNameParts {
  final String prefix;
  final String suffix;

  DisplayNameParts({required this.prefix, required this.suffix});
}

class HomeScreen extends StatefulWidget {
  final AppDb db;
  final String displayName;

  const HomeScreen({super.key, required this.db, required this.displayName});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _fmt = DateFormat('yyyy/MM/dd HH:mm');
  StreamSubscription? _intentDataStreamSubscription;

  @override
  void initState() {
    super.initState();
    _initSharingIntent();
  }

  void _initSharingIntent() {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return;

    try {
      _intentDataStreamSubscription = ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> value) {
        _handleSharedMedia(value);
      }, onError: (err) {
        print("getIntentDataStream error: $err");
      });

      ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> value) {
        _handleSharedMedia(value);
      });
    } catch (e) {
      print("Sharing intent not supported: $e");
    }
  }

  @override
  void dispose() {
    _intentDataStreamSubscription?.cancel();
    super.dispose();
  }

  void _handleSharedMedia(List<SharedMediaFile> value) {
    if (value.isEmpty) return;
    _showShareTargetDialog(value);
    ReceiveSharingIntent.instance.reset();
  }

  Future<void> _showShareTargetDialog(List<SharedMediaFile> files) async {
    final first = files.first;
    String content = first.path;

    final categories = await (widget.db.select(widget.db.categories)..orderBy([(t) => OrderingTerm(expression: t.sortOrder)])).get();

    if (!mounted) return;
    
    final selectedCategory = await showDialog<String>(
      context: context,
      builder: (context) {
         return AlertDialog(
           title: const Text('分享內容要存到哪個區塊？'),
           content: SizedBox(
             width: double.maxFinite,
             child: ListView.builder(
               shrinkWrap: true,
               itemCount: categories.length,
               itemBuilder: (context, index) {
                 final cat = categories[index];
                 return ListTile(
                   title: Text(cat.name),
                   onTap: () => Navigator.pop(context, cat.id),
                 );
               },
             ),
           ),
           actions: [
             TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
           ],
         );
      }
    );

    if (selectedCategory != null && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EditEntryScreen(
            db: widget.db,
            categoryId: selectedCategory,
            categoryName: categories.firstWhere((c) => c.id == selectedCategory).name,
            initialContent: content,
          ),
        ),
      );
    }
  }

  Future<void> _editDisplayName() async {
    final parts = await AppSettings.getDisplayNameParts();
    final prefix = TextEditingController(text: parts.prefix ?? '');
    final suffix = TextEditingController(text: parts.suffix);

    final result = await showDialog<DisplayNameParts>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改名稱'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: prefix,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '前面（例如：小明）',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: suffix,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '後面（例如：的書坊）',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              DisplayNameParts(prefix: prefix.text.trim(), suffix: suffix.text.trim()),
            ),
            child: const Text('儲存'),
          ),
        ],
      ),
    );

    if (result == null) return;
    if (result.prefix.trim().isEmpty) return;
    await AppSettings.setDisplayNameParts(
      prefix: result.prefix,
      suffix: result.suffix.isEmpty ? '' : result.suffix,
    );
    if (!mounted) return;
    // simplest: restart the widget tree by popping to root and rebuilding via Bootstrapper
    // (Bootstrapper reads settings again on next build)
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _addCategory() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增區塊'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '區塊名稱'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('新增'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await widget.db.createCategory(name: name.trim());
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SearchScreen(db: widget.db)),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('剪貼簿是空的')));
      return;
    }
    _showShareTargetDialog([SharedMediaFile(path: text, type: SharedMediaType.text, thumbnail: '')]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.displayName),
        actions: [
          if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS))
            IconButton(
              tooltip: '從剪貼簿讀取(模擬分享)',
              onPressed: _pasteFromClipboard,
              icon: const Icon(Icons.paste),
            ),
          IconButton(
            tooltip: '新增區塊',
            onPressed: _addCategory,
            icon: const Icon(Icons.add),
          ),
          IconButton(
            tooltip: '修改名稱',
            onPressed: _editDisplayName,
            icon: const Icon(Icons.edit),
          ),
          IconButton(
            tooltip: '搜尋',
            onPressed: _openSearch,
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: StreamBuilder<List<CategoryRow>>(
        stream: (widget.db.select(widget.db.categories)
              ..orderBy([
                (t) => OrderingTerm(expression: t.sortOrder),
                (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
              ]))
            .watch()
            .map((rows) => rows
                .map((r) => CategoryRow(id: r.id, name: r.name, updatedAt: r.updatedAt))
                .toList()),
        builder: (context, snapshot) {
          final items = snapshot.data ?? const <CategoryRow>[];
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('還沒有區塊，先新增一個吧。'),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _addCategory,
                      icon: const Icon(Icons.add),
                      label: const Text('新增區塊'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final c = items[i];
              return ListTile(
                title: Text(c.name),
                subtitle: Text('更新：${_fmt.format(c.updatedAt)}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CategoryScreen(
                        db: widget.db,
                        categoryId: c.id,
                        categoryName: c.name,
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(right: 16, bottom: 16),
        child: FloatingActionButton(
          tooltip: '新增區塊',
          onPressed: _addCategory,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}

class CategoryRow {
  final String id;
  final String name;
  final DateTime updatedAt;

  CategoryRow({required this.id, required this.name, required this.updatedAt});
}

class CategoryScreen extends StatefulWidget {
  final AppDb db;
  final String categoryId;
  final String categoryName;

  const CategoryScreen({
    super.key,
    required this.db,
    required this.categoryId,
    required this.categoryName,
  });

  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  final _fmt = DateFormat('yyyy/MM/dd HH:mm');

  Future<void> _addEntry() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditEntryScreen(
          db: widget.db,
          categoryId: widget.categoryId,
          categoryName: widget.categoryName,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.categoryName),
        actions: [
          IconButton(
            tooltip: '新增內容',
            onPressed: _addEntry,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: StreamBuilder<List<EntryRow>>(
        stream: (widget.db.select(widget.db.entries)
              ..where((t) => t.categoryId.equals(widget.categoryId))
              ..orderBy([(t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc)]))
            .watch()
            .map((rows) => rows
                .map((r) => EntryRow(id: r.id, title: r.title, content: r.content, updatedAt: r.updatedAt))
                .toList()),
        builder: (context, snapshot) {
          final items = snapshot.data ?? const <EntryRow>[];
          if (items.isEmpty) {
            return const Center(child: Text('這個區塊還沒有任何紀錄。'));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final e = items[i];
              final url = _extractUrl(e.content ?? '') ?? _extractUrl(e.title);
              Widget? trailing;
              if (url != null) {
                final isYoutube = url.contains('youtube.com') || url.contains('youtu.be');
                trailing = IconButton(
                  icon: Icon(
                    isYoutube ? Icons.play_circle_fill : Icons.open_in_new,
                    color: isYoutube ? Colors.red : null,
                  ),
                  onPressed: () => launchUrl(Uri.parse(url)),
                  tooltip: isYoutube ? '播放影片' : '開啟連結',
                );
              }

              return ListTile(
                title: Text(e.title),
                subtitle: Text('更新：${_fmt.format(e.updatedAt)}'),
                trailing: trailing,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => EditEntryScreen(
                        db: widget.db,
                        categoryId: widget.categoryId,
                        categoryName: widget.categoryName,
                        entryId: e.id,
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(right: 16, bottom: 16),
        child: FloatingActionButton(
          tooltip: '新增內容',
          onPressed: _addEntry,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}

class EntryRow {
  final String id;
  final String title;
  final String? content;
  final DateTime updatedAt;

  EntryRow({required this.id, required this.title, required this.content, required this.updatedAt});
}

class EditEntryScreen extends StatefulWidget {
  final AppDb db;
  final String categoryId;
  final String categoryName;
  final String? entryId;
  final String? initialTitle;
  final String? initialContent;

  const EditEntryScreen({
    super.key,
    required this.db,
    required this.categoryId,
    required this.categoryName,
    this.entryId,
    this.initialTitle,
    this.initialContent,
  });

  @override
  State<EditEntryScreen> createState() => _EditEntryScreenState();
}

class _EditEntryScreenState extends State<EditEntryScreen> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (widget.entryId != null) {
      final row = await (widget.db.select(widget.db.entries)..where((t) => t.id.equals(widget.entryId!))).getSingle();
      _title.text = row.title;
      _content.text = row.content ?? '';
    } else {
      _title.text = widget.initialTitle ?? '';
      _content.text = widget.initialContent ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  String _autoTitle(String content) {
    final t = content.trim();
    if (t.isEmpty) return '未命名';
    final firstLine = t.split('\n').first.trim();
    return firstLine.isEmpty ? '未命名' : (firstLine.length > 40 ? firstLine.substring(0, 40) : firstLine);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final title = _title.text.trim().isEmpty ? _autoTitle(_content.text) : _title.text.trim();
    final content = _content.text.trim().isEmpty ? null : _content.text.trim();

    if (widget.entryId == null) {
      await widget.db.createEntry(
        categoryId: widget.categoryId,
        title: title,
        content: content,
      );
    } else {
      await widget.db.updateEntry(id: widget.entryId!, title: title, content: content);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entryId == null ? '新增紀錄' : '編輯紀錄'),
        actions: [
          IconButton(onPressed: _saving ? null : _save, icon: const Icon(Icons.save)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _content,
              builder: (context, value, child) {
                final url = _extractUrl(value.text) ?? _extractUrl(_title.text);
                if (url == null) return const SizedBox.shrink();
                final isYoutube = url.contains('youtube.com') || url.contains('youtu.be');
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: InkWell(
                    onTap: () => launchUrl(Uri.parse(url)),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(isYoutube ? Icons.play_circle_fill : Icons.open_in_new, 
                            color: Theme.of(context).colorScheme.onPrimaryContainer),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              isYoutube ? '播放 YouTube 影片' : '開啟連結',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            TextField(
              controller: _title,
              decoration: const InputDecoration(
                labelText: '標題（可留空自動抓）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _content,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  labelText: '內容',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save),
                label: Text(_saving ? '儲存中…' : '儲存'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SearchScreen extends StatefulWidget {
  final AppDb db;
  const SearchScreen({super.key, required this.db});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _q = TextEditingController();
  List<SearchHit> _hits = const [];
  bool _searching = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _run({bool showEmptyQuery = false}) async {
    final query = _q.text.trim();
    if (query.isEmpty) {
      if (showEmptyQuery) {
        setState(() => _hits = const []);
      }
      return;
    }

    setState(() => _searching = true);
    final hits = await widget.db.searchAll(query);
    if (!mounted) return;
    setState(() {
      _hits = hits;
      _searching = false;
    });
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(showEmptyQuery: true));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('跨區塊搜尋')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('像 Word 一樣：輸入部分中文或英文即可，不用記完整名稱'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _q,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onChanged: _onQueryChanged,
                    onSubmitted: (_) => _run(showEmptyQuery: true),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '例如：人生、prog、youtube',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _searching ? null : () => _run(showEmptyQuery: true),
                  child: Text(_searching ? '搜尋中…' : '搜尋'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '多個關鍵字用空格分開（例如：人生 砥礪）',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _hits.isEmpty
                  ? Center(
                      child: Text(
                        _q.text.trim().isEmpty ? '輸入關鍵字開始搜尋' : '尚無結果',
                      ),
                    )
                  : ListView.separated(
                      itemCount: _hits.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final h = _hits[i];
                        return ListTile(
                          title: Text(h.title),
                          subtitle: Text('區塊：${h.categoryName}'),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

