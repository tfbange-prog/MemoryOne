import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show OrderingMode, OrderingTerm;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';

import '../db/app_db.dart';
import '../settings/app_settings.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

String? extractUrl(String text) {
  final normalized = text
      .replaceAll('\u00A0', ' ')
      .replaceAll('\r', ' ')
      .replaceAll('\n', ' ')
      .trim();
  if (normalized.isEmpty) return null;

  final patterns = <RegExp>[
    RegExp(r'https?://[^\s<>"\)\]\}]*'),
  ];

  for (final pattern in patterns) {
    for (final match in pattern.allMatches(normalized)) {
      final raw = match.group(0)?.trim();
      if (raw == null || raw.isEmpty) continue;
      final cleaned = raw.replaceAll(RegExp(r'[\.,;:!?\)\]\}]+$'), '');
      if (cleaned.isEmpty) continue;
      return cleaned;
    }
  }

  return null;
}

String buildLinkLabel(String url) {
  if (url.contains('youtube.com') || url.contains('youtu.be')) return '播放影片';
  return '開啟連結';
}

class DisplayNameParts {
  final String prefix;
  final String suffix;

  DisplayNameParts({required this.prefix, required this.suffix});
}

class HomeScreen extends StatefulWidget {
  final AppDb db;
  final String displayName;
  final ValueChanged<double> onFontScaleChanged;

  const HomeScreen({
    super.key,
    required this.db,
    required this.displayName,
    required this.onFontScaleChanged,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _fmt = DateFormat('yyyy/MM/dd HH:mm');
  String? _draggingCategoryId;
  double _fontScale = 1.0;
  StreamSubscription? _intentDataStreamSubscription;
  StreamSubscription? _intentTextStreamSubscription;

  @override
  void initState() {
    super.initState();
    _initSharingIntent();
    _loadFontScale();
  }

  Future<void> _loadFontScale() async {
    final scale = await AppSettings.getFontScale();
    if (!mounted) return;
    setState(() => _fontScale = scale);
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

      // Note: text stream API may not be available on all platforms (e.g. Windows).
      // We only listen for media streams above. Plain text from clipboard is
      // handled via the paste action which routes into the incoming share screen.
    } catch (e) {
      print("Sharing intent not supported: $e");
    }
  }

  @override
  void dispose() {
    _intentDataStreamSubscription?.cancel();
    _intentTextStreamSubscription?.cancel();
    super.dispose();
  }

  void _handleSharedMedia(List<SharedMediaFile> value) {
    if (value.isEmpty) return;
    _openIncomingShareScreen(sharedText: null, sharedFiles: value);
    ReceiveSharingIntent.instance.reset();
  }

  void _handleSharedText(String text) {
    if (text.trim().isEmpty) return;
    _openIncomingShareScreen(sharedText: text, sharedFiles: const []);
  }

  Future<void> _openIncomingShareScreen({String? sharedText, required List<SharedMediaFile> sharedFiles}) async {
    final rows = await (widget.db.select(widget.db.categories)
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .get();
    if (rows.isEmpty) return;
    final categories = rows
        .map((r) => CategoryRow(id: r.id, name: r.name, updatedAt: r.updatedAt, entryCount: 0))
        .toList(growable: false);
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => IncomingShareScreen(
          db: widget.db,
          categories: categories,
          sharedText: sharedText,
          sharedFiles: sharedFiles,
        ),
      ),
    );
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
    String? errorText;
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('新增資料框'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: '資料框名稱',
                      errorText: errorText,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                FilledButton(
                  onPressed: () {
                    final text = controller.text.trim();
                    if (text.isEmpty) {
                      setDialogState(() => errorText = '請輸入資料框名稱');
                      return;
                    }
                    Navigator.pop(context, text);
                  },
                  child: const Text('新增'),
                ),
              ],
            );
          },
        );
      },
    );

    if (name == null || name.trim().isEmpty) return;

    try {
      await widget.db.createCategory(name: name.trim());
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('資料框已新增')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('新增資料框失敗：${e.toString()}')));
    }
  }

  Future<void> _attemptDeleteCategory(String categoryId, String categoryName) async {
    final canDelete = await widget.db.canDeleteCategory(categoryId);
    if (!canDelete) {
      final view = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('無法刪除'),
          content: const Text('此資料框底下仍有資料，請先清空內容後再刪除。是否要查看內容？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('查看內容')),
          ],
        ),
      );
      if (view == true) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => CategoryScreen(db: widget.db, categoryId: categoryId, categoryName: categoryName),
          ),
        );
      }
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確定刪除？'),
        content: Text('確定要刪除資料框「$categoryName」嗎？此操作無法復原。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('刪除')),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await widget.db.deleteCategory(categoryId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已刪除資料框')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('刪除失敗：${e.toString()}')));
    }
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SearchScreen(db: widget.db)),
    );
  }

  Future<void> _editFontScale() async {
    var selectedScale = _fontScale;
    final result = await showDialog<double>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('字體大小'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('當前：${selectedScale.toStringAsFixed(1)}'),
                  const SizedBox(height: 16),
                  Slider(
                    min: 0.8,
                    max: 1.8,
                    divisions: 10,
                    value: selectedScale,
                    label: selectedScale.toStringAsFixed(1),
                    onChanged: (value) {
                      setDialogState(() => selectedScale = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  const Text('拖曳滑桿可放大或縮小字體。'),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                FilledButton(onPressed: () => Navigator.pop(context, selectedScale), child: const Text('儲存')),
              ],
            );
          },
        );
      },
    );

    if (result == null) return;
    await AppSettings.setFontScale(result);
    if (!mounted) return;
    setState(() => _fontScale = result);
    widget.onFontScaleChanged(result);
  }

  Future<void> _reorderCategory(String draggedId, String targetId, List<CategoryRow> currentItems) async {
    final updated = List<CategoryRow>.from(currentItems);
    final draggedIndex = updated.indexWhere((item) => item.id == draggedId);
    final targetIndex = updated.indexWhere((item) => item.id == targetId);
    if (draggedIndex < 0 || targetIndex < 0 || draggedIndex == targetIndex) return;
    final dragged = updated.removeAt(draggedIndex);
    updated.insert(targetIndex, dragged);
    await widget.db.reorderCategories(updated.map((item) => item.id).toList());
  }

  Widget _buildCategoryCard(CategoryRow item, List<CategoryRow> currentItems, double width) {
    return DragTarget<CategoryRow>(
      onWillAccept: (data) => data != null && data.id != item.id,
      onAccept: (dragged) => _reorderCategory(dragged.id, item.id, currentItems),
      builder: (context, candidateData, rejectedData) {
        final highlight = candidateData.isNotEmpty;
        return LongPressDraggable<CategoryRow>(
          data: item,
          onDragStarted: () => setState(() => _draggingCategoryId = item.id),
          onDraggableCanceled: (_, __) => setState(() => _draggingCategoryId = null),
          onDragEnd: (_) => setState(() => _draggingCategoryId = null),
          feedback: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              width: width,
              child: _categoryCard(item, isDragging: true),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.25,
            child: SizedBox(width: width, child: _categoryCard(item, isOverlay: true)),
          ),
          child: SizedBox(width: width, child: _categoryCard(item, isHighlighted: highlight)),
        );
      },
    );
  }

  Widget _categoryCard(CategoryRow item, {bool isDragging = false, bool isOverlay = false, bool isHighlighted = false}) {
    final accent = const Color(0xFFF6CFBE);
    final accentStrong = const Color(0xFFB9DCF2);
    final entryCountLabel = item.entryCount == 1 ? '1 筆紀錄' : '${item.entryCount} 筆紀錄';
    return Material(
      color: isDragging ? Colors.white : null,
      elevation: isDragging ? 8 : 2,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => CategoryScreen(
                db: widget.db,
                categoryId: item.id,
                categoryName: item.name,
              ),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                accent,
                accentStrong,
              ],
            ),
            border: Border.all(
              color: isHighlighted ? const Color(0xFF2F80ED) : const Color(0xFF3DAA9A),
              width: isHighlighted ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      item.name,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多操作',
                    padding: EdgeInsets.zero,
                    iconSize: 20,
                    onSelected: (value) async {
                      if (value == 'rename') {
                        final controller = TextEditingController(text: item.name);
                        final name = await showDialog<String>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('重命名資料框'),
                            content: TextField(controller: controller, decoration: const InputDecoration(labelText: '名稱')),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                              FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('儲存')),
                            ],
                          ),
                        );
                        if (name != null && name.isNotEmpty) {
                          await widget.db.renameCategory(id: item.id, name: name);
                        }
                      } else if (value == 'reorder') {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('長按資料框即可拖曳重新排序')),
                        );
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(value: 'reorder', child: Text('長按拖曳排序')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(entryCountLabel, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
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
    _openIncomingShareScreen(sharedText: text, sharedFiles: const []);
  }

  Future<void> _showBackupOptions() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('資料備份與還原'),
        content: const Text('可將整份資料備份成 zip 檔；手動上傳到雲端時會使用固定檔名，方便每次覆蓋同一份備份。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, 'backup'), child: const Text('備份到本機')),
          TextButton(onPressed: () => Navigator.pop(context, 'cloud'), child: const Text('上傳雲端')),
          FilledButton(onPressed: () => Navigator.pop(context, 'restore'), child: const Text('從備份還原')),
        ],
      ),
    );

    if (choice == 'backup') {
      await _backupAllData();
    } else if (choice == 'cloud') {
      await _uploadBackupToCloud();
    } else if (choice == 'restore') {
      await _restoreFromBackup();
    }
  }

  Future<void> _backupAllData() async {
    try {
      final tempFile = await widget.db.exportFullBackupArchive(fileName: 'friends_vault_full_backup.zip');
      final bytes = await tempFile.readAsBytes();
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '儲存整份資料庫備份',
        fileName: 'friends_vault_full_backup.zip',
        type: FileType.custom,
        allowedExtensions: ['zip'],
        bytes: bytes,
      );
      if (savePath == null || savePath.trim().isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已取消備份')));
        return;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('整份資料庫備份已儲存到你選擇的位置。')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('備份失敗：${e.toString()}')));
    }
  }

  Future<void> _uploadBackupToCloud() async {
    try {
      final file = await widget.db.exportFullBackupArchive(fileName: 'friends_vault_cloud_backup.zip');
      await Share.shareXFiles(
        [XFile(file.path)],
        text: '請把這份備份上傳到你的雲端空間，並覆蓋原本的同名檔：friends_vault_cloud_backup.zip',
        subject: 'Friends Vault 雲端備份',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已生成雲端備份檔，請在雲端 app 中覆蓋同名檔。')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('上傳雲端失敗：${e.toString()}')));
    }
  }

  Future<void> _restoreFromBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result == null || result.files.isEmpty) {
        return;
      }
      final filePath = result.files.single.path;
      if (filePath == null) {
        return;
      }
      await widget.db.importBackupArchive(archiveFile: File(filePath));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('備份已成功還原')));
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('還原失敗：${e.toString()}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.displayName, style: const TextStyle(color: Color(0xFF7397AB))),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFD78A), Color(0xFFF4762D)],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '從剪貼簿讀取(模擬分享)',
            onPressed: _pasteFromClipboard,
            icon: const Icon(Icons.paste),
          ),
          IconButton(
            tooltip: '新增資料框',
            onPressed: _addCategory,
            icon: const Icon(Icons.add),
          ),
          IconButton(
            tooltip: '修改名稱',
            onPressed: _editDisplayName,
            icon: const Icon(Icons.edit),
          ),
          IconButton(
            tooltip: '字體大小',
            onPressed: _editFontScale,
            icon: const Icon(Icons.format_size),
          ),
          IconButton(
            tooltip: '備份/還原',
            onPressed: _showBackupOptions,
            icon: const Icon(Icons.backup_outlined),
          ),
          IconButton(
            tooltip: '搜尋',
            onPressed: _openSearch,
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFFF9F5), Color(0xFFFFF5F0)],
          ),
        ),
        child: StreamBuilder<List<CategoryRow>>(
          stream: widget.db.customSelect(
            '''
            SELECT
              c.id AS id,
              c.name AS name,
              c.updated_at AS updated_at,
              COUNT(e.id) AS entry_count
            FROM categories c
            LEFT JOIN entries e ON e.category_id = c.id
            GROUP BY c.id
            ORDER BY c.sort_order, c.updated_at DESC
            ''',
            readsFrom: {widget.db.categories, widget.db.entries},
          ).watch().map((rows) => rows
              .map((row) => CategoryRow(
                    id: row.read<String>('id'),
                    name: row.read<String>('name'),
                    updatedAt: row.read<DateTime>('updated_at'),
                    entryCount: row.read<int>('entry_count'),
                  ))
              .toList(growable: false)),
          builder: (context, snapshot) {
            final items = snapshot.data ?? const <CategoryRow>[];
            if (items.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFFDF7),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF3DAA9A), width: 1.5),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('還沒有資料框，先新增一個吧。'),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _addCategory,
                          icon: const Icon(Icons.add),
                          label: const Text('新增資料框'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            return LayoutBuilder(
              builder: (context, constraints) {
                const scrollPadding = EdgeInsets.fromLTRB(12, 12, 12, 16);
                final spacing = 10.0;
                final maxWidth = constraints.maxWidth;
                const columns = 2;
                final horizontalPadding = scrollPadding.left + scrollPadding.right;
                final availableWidth = maxWidth - horizontalPadding - (columns - 1) * spacing;
                final itemWidth = availableWidth / columns;
                return SingleChildScrollView(
                  padding: scrollPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (items.length > 1)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF2E8),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: const Color(0xFFEDB38A)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(Icons.drag_indicator, size: 15),
                                SizedBox(width: 4),
                                Text('長按資料框可拖曳重新排序', style: TextStyle(fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                      Wrap(
                        spacing: spacing,
                        runSpacing: 12,
                        children: items
                            .map((c) => SizedBox(width: itemWidth, child: _buildCategoryCard(c, items, itemWidth)))
                            .toList(),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(right: 16, bottom: 16),
        child: FloatingActionButton(
          tooltip: '新增資料框',
          backgroundColor: const Color(0xFF4F8DE8),
          foregroundColor: Colors.white,
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
  final int entryCount;

  CategoryRow({required this.id, required this.name, required this.updatedAt, required this.entryCount});
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

  Future<void> _exportCurrentCategory() async {
    try {
      final file = await widget.db.exportCategoryArchive(categoryId: widget.categoryId);
      await Share.shareXFiles(
        [XFile(file.path)],
        text: '這是資料框「${widget.categoryName}」的匯出檔，可直接寄出或存到雲端。',
        subject: 'Friends Vault 資料框匯出',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('資料框匯出檔已建立，請選擇分享目標。')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('匯出失敗：${e.toString()}')));
    }
  }

  Future<void> _downloadCurrentCategoryArchive() async {
    try {
      final file = await widget.db.exportCategoryArchive(categoryId: widget.categoryId);
      final bytes = await file.readAsBytes();
      final safeName = widget.categoryName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '儲存資料框備份',
        fileName: 'friends_vault_category_${safeName}.zip',
        type: FileType.custom,
        allowedExtensions: ['zip'],
        bytes: bytes,
      );
      if (savePath == null || savePath.trim().isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已取消儲存資料框備份')));
        return;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('資料框備份已儲存到你選擇的位置。')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('儲存失敗：${e.toString()}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.categoryName, style: const TextStyle(color: Color(0xFF7397AB))),
        iconTheme: const IconThemeData(color: Color(0xFF7397AB)),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFD78A), Color(0xFFF4762D)],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '匯出此資料框',
            onPressed: _exportCurrentCategory,
            icon: const Icon(Icons.share_outlined),
          ),
          IconButton(
            tooltip: '下載資料框備份',
            onPressed: _downloadCurrentCategoryArchive,
            icon: const Icon(Icons.download_outlined),
          ),
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
            return const Center(child: Text('這個資料框還沒有任何紀錄。'));
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final e = items[i];
              final url = extractUrl(e.content ?? '') ?? extractUrl(e.title);
              final isEven = i.isEven;
              Widget? trailing;
              if (url != null) {
                final isYoutube = url.contains('youtube.com') || url.contains('youtu.be');
                trailing = IconButton(
                  icon: Icon(
                    isYoutube ? Icons.play_circle_fill : Icons.open_in_new,
                    color: isYoutube ? Colors.red : null,
                  ),
                  onPressed: () => launchUrl(Uri.parse(url)),
                  tooltip: buildLinkLabel(url),
                );
              }

              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isEven ? const Color(0xFFFFF7E8) : const Color(0xFFF3F7FF),
                  borderRadius: BorderRadius.circular(14),
                  border: Border(left: BorderSide(color: isEven ? const Color(0xFFF0A24B) : const Color(0xFF5A8DFF), width: 4)),
                ),
                child: ListTile(
                  title: e.title.trim().isNotEmpty
                      ? Text(e.title)
                      : const Text('（無標題）', style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)),
                  subtitle: Text(
                    '更新：${_fmt.format(e.updatedAt)}',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
                  ),
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
                ),
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
  List<StoredAttachment> _attachments = const [];
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _title.addListener(() {
      if (mounted) setState(() {});
    });
    _init();
  }

  Future<void> _init() async {
    if (widget.entryId != null) {
      final row = await (widget.db.select(widget.db.entries)..where((t) => t.id.equals(widget.entryId!))).getSingle();
      _title.text = row.title;
      _content.text = row.content ?? '';
      _attachments = await widget.db.getAttachmentsForEntry(widget.entryId!);
    } else {
      _title.text = widget.initialTitle ?? '';
      _content.text = widget.initialContent ?? '';
      _attachments = const [];
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
    final contentText = _content.text.trim();
    final hasUrl = extractUrl(contentText) != null;
    // 若正文含有網址且標題留空，允許標題保持空白；否則套用自動標題
    final title = _title.text.trim().isNotEmpty
        ? _title.text.trim()
        : (hasUrl ? '' : _autoTitle(contentText));
    final content = contentText.isEmpty ? null : contentText;

    late final String entryId;
    if (widget.entryId == null) {
      entryId = await widget.db.createEntry(
        categoryId: widget.categoryId,
        title: title,
        content: content,
      );
    } else {
      entryId = widget.entryId!;
      await widget.db.updateEntry(id: entryId, title: title, content: content);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.pop(context);
  }

  Future<void> _deleteEntry() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確定刪除？'),
        content: const Text('此筆資料將完全刪除，包含附件與紀錄。此操作無法復原。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('刪除')),
        ],
      ),
    );
    if (confirmed != true || widget.entryId == null) return;

    setState(() => _saving = true);
    await widget.db.deleteEntry(widget.entryId!);
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.pop(context);
  }

  Future<void> _pickAttachment() async {
    final source = await showDialog<_AttachmentSource>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增附件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('選擇圖片'),
              subtitle: const Text('從相簿加入照片'),
              onTap: () => Navigator.of(context).pop(_AttachmentSource.image),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('選擇檔案'),
              subtitle: const Text('加入文件、音訊、其他檔案'),
              onTap: () => Navigator.of(context).pop(_AttachmentSource.file),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;
    if (widget.entryId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請先先儲存主題，再加入附件。')),
      );
      return;
    }

    File? pickedFile;
    if (source == _AttachmentSource.image) {
      final picked = await _picker.pickImage(source: ImageSource.gallery);
      if (picked != null) {
        pickedFile = File(picked.path);
      }
    } else {
      final result = await FilePicker.platform.pickFiles(allowMultiple: false);
      if (result != null && result.files.single.path != null) {
        pickedFile = File(result.files.single.path!);
      }
    }

    if (pickedFile == null) return;

    await widget.db.addAttachment(
      entryId: widget.entryId!,
      file: pickedFile,
      originalName: p.basename(pickedFile.path),
    );
    _attachments = await widget.db.getAttachmentsForEntry(widget.entryId!);
    if (mounted) setState(() {});
  }

  Future<void> _openAttachment(StoredAttachment attachment) async {
    final file = File(attachment.filePath);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('檔案不存在')));
      return;
    }

    final isImage = attachment.mimeType?.startsWith('image/') ?? false;
    if (isImage) {
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(attachment.originalName ?? '圖片預覽')),
          body: InteractiveViewer(
            panEnabled: true,
            minScale: 1.0,
            maxScale: 5.0,
            child: Center(child: Image.file(file, fit: BoxFit.contain)),
          ),
        ),
      ));
      return;
    }

    final result = await OpenFile.open(
      file.path,
      type: attachment.mimeType,
    );

    if (result.type == ResultType.done) {
      return;
    }

    if (!mounted) return;

    if (Platform.isAndroid || Platform.isIOS) {
      final shareResult = await Share.shareXFiles(
        [
          XFile(
            file.path,
            mimeType: attachment.mimeType,
            name: attachment.originalName ?? p.basename(file.path),
          ),
        ],
        subject: attachment.originalName ?? p.basename(file.path),
      );

      if (shareResult.status == ShareResultStatus.success) {
        return;
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '無法直接開啟，請改用分享或在其他應用程式中開啟。${result.message.isEmpty ? '' : '(${result.message})'}',
        ),
      ),
    );
  }

  Future<void> _deleteAttachment(String attachmentId) async {
    await widget.db.deleteAttachment(attachmentId: attachmentId, entryId: widget.entryId!);
    _attachments = await widget.db.getAttachmentsForEntry(widget.entryId!);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final currentTitle = _title.text.trim().isEmpty ? '未命名' : _title.text.trim();
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '資料框：${widget.categoryName}',
              style: const TextStyle(fontSize: 14, color: Color(0xFF7397AB)),
            ),
            Text(
              '標題：$currentTitle',
              style: const TextStyle(fontSize: 12, color: Color(0xFF7397AB)),
            ),
          ],
        ),
        iconTheme: const IconThemeData(color: Color(0xFF7397AB)),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFD78A), Color(0xFFF4762D)],
            ),
          ),
        ),
        actions: [
          if (widget.entryId != null)
            IconButton(
              tooltip: '刪除資料',
              onPressed: _saving ? null : _deleteEntry,
              icon: const Icon(Icons.delete_forever),
            ),
          IconButton(onPressed: _saving ? null : _save, icon: const Icon(Icons.save)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom + 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _content,
                builder: (context, value, child) {
                  final url = extractUrl(value.text) ?? extractUrl(_title.text);
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
                            Icon(
                              isYoutube ? Icons.play_circle_fill : Icons.open_in_new,
                              color: Theme.of(context).colorScheme.onPrimaryContainer,
                            ),
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
              SizedBox(
                height: 260,
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
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickAttachment,
                      icon: const Icon(Icons.attach_file),
                      label: const Text('新增附件'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _copyEntryContent,
                      icon: const Icon(Icons.copy),
                      label: const Text('複製內容'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _shareEntry,
                      icon: const Icon(Icons.share),
                      label: const Text('分享整筆'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_attachments.isNotEmpty)
                SizedBox(
                  height: 120,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _attachments.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final attachment = _attachments[index];
                      final isImage = attachment.mimeType?.startsWith('image/') ?? false;
                      final file = File(attachment.filePath);
                      return Stack(
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _openAttachment(attachment),
                            child: Container(
                              width: 100,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              ),
                              child: isImage && file.existsSync()
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: Image.file(file, fit: BoxFit.cover),
                                    )
                                  : Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.insert_drive_file),
                                            const SizedBox(height: 4),
                                            Text(
                                              attachment.originalName ?? '檔案',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                          Positioned(
                            bottom: 4,
                            right: 4,
                            child: IconButton.filledTonal(
                              iconSize: 14,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              onPressed: () => _deleteAttachment(attachment.id),
                              icon: const Icon(Icons.close),
                            ),
                          ),
                        ],
                      );
                    },
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
      ),
    );
  }

  Future<void> _copyEntryContent() async {
    final title = _title.text.trim();
    final content = _content.text.trim();
    final text = '''資料框：${widget.categoryName}
標題：$title

$content''';

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已複製整筆資料')),
    );
  }

  Future<void> _shareEntry() async {
    final title = _title.text.trim();
    final content = _content.text.trim();
    final text = '''資料框：${widget.categoryName}
標題：$title

$content''';

    final files = _attachments.map((attachment) {
      return XFile(
        attachment.filePath,
        mimeType: attachment.mimeType,
        name: attachment.originalName ?? p.basename(attachment.filePath),
      );
    }).toList();

    if (files.isEmpty) {
      await Share.share(text, subject: '${widget.categoryName} / $title');
      return;
    }

    await Share.shareXFiles(
      files,
      text: text,
      subject: '${widget.categoryName} / $title',
    );
  }
}

enum _AttachmentSource { image, file }

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
      appBar: AppBar(title: const Text('跨資料框搜尋')),
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
                          title: h.title.trim().isNotEmpty
                              ? Text(h.title)
                              : const Text('（無標題）', style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)),
                          subtitle: Text('資料框：${h.categoryName}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => EditEntryScreen(
                                  db: widget.db,
                                  categoryId: h.categoryId,
                                  categoryName: h.categoryName,
                                  entryId: h.entryId,
                                ),
                              ),
                            );
                          },
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

class IncomingShareScreen extends StatefulWidget {
  final AppDb db;
  final List<CategoryRow> categories;
  final String? sharedText;
  final List<SharedMediaFile> sharedFiles;

  const IncomingShareScreen({
    super.key,
    required this.db,
    required this.categories,
    required this.sharedText,
    required this.sharedFiles,
  });

  @override
  State<IncomingShareScreen> createState() => _IncomingShareScreenState();
}

class _IncomingShareScreenState extends State<IncomingShareScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  bool _saveText = true;
  bool _saveFiles = true;
  String? _selectedCategoryId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedCategoryId = widget.categories.first.id;
    final text = widget.sharedText?.trim();
    _contentController = TextEditingController(text: text ?? '');
    // 若分享內容偵測到任何網址（http/https），標題留空讓使用者自行輸入
    final detectedUrl = text != null && extractUrl(text) != null;
    _titleController = TextEditingController(
        text: (text != null && !detectedUrl) ? _autoTitle(text) : '');
    if (widget.sharedFiles.isEmpty) {
      _saveFiles = false;
    }
    if (text == null || text.isEmpty) {
      _saveText = false;
    }
  }

  String _autoTitle(String content) {
    final t = content.trim();
    if (t.isEmpty) return '未命名';
    final firstLine = t.split('\n').first.trim();
    return firstLine.isEmpty ? '未命名' : (firstLine.length > 40 ? firstLine.substring(0, 40) : firstLine);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _saveSharedContent() async {
    if (_saving) return;
    if (_selectedCategoryId == null) return;
    setState(() => _saving = true);

    final content = _saveText ? _contentController.text.trim() : null;
    final detectedUrl = content != null ? extractUrl(content) : null;
    // 若正文含有網址，標題允許保持空白（不自動填入）；否則才套用自動標題
    final titleInput = _titleController.text.trim();
    final title = titleInput.isNotEmpty
        ? titleInput
        : (detectedUrl != null
            ? ''
            : _autoTitle(content ?? widget.sharedFiles.map((e) => e.path).join(' ')));

    final entryId = await widget.db.createEntry(
      categoryId: _selectedCategoryId!,
      title: title,
      content: content,
      sourceText: content,
      sourceUrl: detectedUrl ?? extractUrl(_titleController.text),
    );

    if (_saveFiles) {
      for (final file in widget.sharedFiles) {
        final localFile = File(file.path);
        if (await localFile.exists()) {
          await widget.db.addAttachment(
            entryId: entryId,
            file: localFile,
            originalName: p.basename(localFile.path),
          );
        }
      }
    }

    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop();
  }

  Widget _buildSharedFileTile(SharedMediaFile file) {
    final name = p.basename(file.path);
    return ListTile(
      leading: const Icon(Icons.attach_file),
      title: Text(name),
      subtitle: Text(file.type.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('分享內容預覽'),
        actions: [
          IconButton(
            onPressed: _saving ? null : _saveSharedContent,
            icon: const Icon(Icons.save),
            tooltip: '儲存到資料框',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('請選擇要將分享內容存到哪個資料框：'),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _selectedCategoryId,
                      decoration: const InputDecoration(border: OutlineInputBorder(), labelText: '資料框'),
                      items: widget.categories
                          .map((cat) => DropdownMenuItem(value: cat.id, child: Text(cat.name)))
                          .toList(),
                      onChanged: (value) => setState(() => _selectedCategoryId = value),
                    ),
                    const SizedBox(height: 16),
                    if (widget.sharedText != null && widget.sharedText!.trim().isNotEmpty) ...[
                      Row(
                        children: [
                          Checkbox(value: _saveText, onChanged: (value) => setState(() => _saveText = value ?? false)),
                          const Expanded(child: Text('將分享文字或連結存為正文')),
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('如果分享內容是長網址，建議補上一兩句中文說明內容主題或用途。'),
                      ),
                      TextField(
                        controller: _titleController,
                        decoration: const InputDecoration(border: OutlineInputBorder(), labelText: '主題名稱'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _contentController,
                        minLines: 4,
                        maxLines: 12,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: '正文內容',
                          hintText: '例如：這個影片是關於川西稻城亞丁旅行行程',
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (widget.sharedFiles.isNotEmpty) ...[
                      Row(
                        children: [
                          Checkbox(value: _saveFiles, onChanged: (value) => setState(() => _saveFiles = value ?? false)),
                          const Expanded(child: Text('將分享檔案存為附件')),
                        ],
                      ),
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: widget.sharedFiles.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) => _buildSharedFileTile(widget.sharedFiles[index]),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _saveSharedContent,
                  child: Text(_saving ? '儲存中…' : '儲存到資料框'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

