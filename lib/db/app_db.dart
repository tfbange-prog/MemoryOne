import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

part 'app_db.g.dart';

class Categories extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Entries extends Table {
  TextColumn get id => text()();
  TextColumn get categoryId => text().references(Categories, #id)();

  TextColumn get title => text()();
  TextColumn get content => text().nullable()();
  TextColumn get sourceText => text().nullable()(); // e.g. shared text/url raw payload
  TextColumn get sourceUrl => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Attachments extends Table {
  TextColumn get id => text()();
  TextColumn get entryId => text().references(Entries, #id)();
  TextColumn get relativePath => text()(); // stored under app documents dir
  TextColumn get originalName => text().nullable()();
  TextColumn get mimeType => text().nullable()();
  IntColumn get byteLength => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

// FTS5 virtual table for cross-category search.
// Drift doesn't have a first-class FTS5 DSL for all cases, so we manage it with custom SQL.
@DriftDatabase(tables: [Categories, Entries, Attachments])
class AppDb extends _$AppDb {
  AppDb() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openConnection() {
    if (kIsWeb) {
      return driftDatabase(
        name: 'friends_vault.sqlite',
        web: DriftWebOptions(
          sqlite3Wasm: Uri.parse('sqlite3.wasm'),
          driftWorker: Uri.parse('drift_worker.js'),
        ),
      );
    }

    return driftDatabase(
      name: 'friends_vault.sqlite',
      native: const DriftNativeOptions(),
    );
  }

  Future<void> bootstrap() async {
    // Ensure attachments dir exists (skip on web where path_provider isn't available)
    if (!kIsWeb) {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'attachments'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }

    // Create FTS table + triggers once.
    await customStatement('''
CREATE VIRTUAL TABLE IF NOT EXISTS entry_fts USING fts5(
  entry_id UNINDEXED,
  title,
  content,
  category_name,
  tokenize = 'unicode61'
);
''');

    await customStatement('''
CREATE TRIGGER IF NOT EXISTS entry_fts_ai AFTER INSERT ON entries BEGIN
  INSERT INTO entry_fts(entry_id, title, content, category_name)
  VALUES (
    new.id,
    new.title,
    coalesce(new.content,''),
    (SELECT name FROM categories WHERE id = new.category_id)
  );
END;
''');

    await customStatement('''
CREATE TRIGGER IF NOT EXISTS entry_fts_ad AFTER DELETE ON entries BEGIN
  DELETE FROM entry_fts WHERE entry_id = old.id;
END;
''');

    await customStatement('''
CREATE TRIGGER IF NOT EXISTS entry_fts_au AFTER UPDATE ON entries BEGIN
  UPDATE entry_fts SET
    title = new.title,
    content = coalesce(new.content,''),
    category_name = (SELECT name FROM categories WHERE id = new.category_id)
  WHERE entry_id = new.id;
END;
''');

    // Seed one default category if none.
    final cnt = await (select(categories)..limit(1)).get();
    if (cnt.isEmpty) {
      final now = DateTime.now();
      await into(categories).insert(CategoriesCompanion.insert(
        id: const Uuid().v4(),
        name: '收集箱',
        createdAt: now,
        updatedAt: now,
      ));
    }
  }

  Future<String> createCategory({required String name, int? sortOrder}) async {
    final id = const Uuid().v4();
    final now = DateTime.now();
    final order = sortOrder ?? await _nextCategorySortOrder();
    await into(categories).insert(CategoriesCompanion.insert(
      id: id,
      name: name,
      sortOrder: Value(order),
      createdAt: now,
      updatedAt: now,
    ));
    return id;
  }

  Future<int> _nextCategorySortOrder() async {
    final row = await customSelect(
      'SELECT MAX(sort_order) AS max_order FROM categories',
      readsFrom: {categories},
    ).getSingle();
    final maxOrder = row.read<int?>('max_order');
    return (maxOrder ?? -1) + 1;
  }

  Future<void> reorderCategories(List<String> orderedIds) async {
    final now = DateTime.now();
    await batch((b) {
      for (var i = 0; i < orderedIds.length; i++) {
        b.update(
          categories,
          CategoriesCompanion(
            sortOrder: Value(i),
            updatedAt: Value(now),
          ),
          where: (t) => t.id.equals(orderedIds[i]),
        );
      }
    });
  }

  Future<void> renameCategory({required String id, required String name}) async {
    await (update(categories)..where((t) => t.id.equals(id))).write(
      CategoriesCompanion(
        name: Value(name),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Return true when a category has no entries (safe to delete).
  Future<bool> canDeleteCategory(String categoryId) async {
    final cnt = await customSelect(
      'SELECT COUNT(1) AS c FROM entries WHERE category_id = ?',
      variables: [Variable<String>(categoryId)],
      readsFrom: {entries},
    ).getSingle();
    final c = cnt.read<int>('c');
    return c == 0;
  }

  /// Delete a category only if it has no entries. Throws if not empty.
  Future<void> deleteCategory(String categoryId) async {
    final ok = await canDeleteCategory(categoryId);
    if (!ok) {
      throw StateError('Category not empty');
    }
    await (delete(categories)..where((t) => t.id.equals(categoryId))).go();
  }

  Future<String> createEntry({
    required String categoryId,
    required String title,
    String? content,
    String? sourceText,
    String? sourceUrl,
  }) async {
    final id = const Uuid().v4();
    final now = DateTime.now();
    await into(entries).insert(EntriesCompanion.insert(
      id: id,
      categoryId: categoryId,
      title: title,
      content: Value(content),
      sourceText: Value(sourceText),
      sourceUrl: Value(sourceUrl),
      createdAt: now,
      updatedAt: now,
    ));
    return id;
  }

  Future<String> addAttachment({
    required String entryId,
    required File file,
    String? originalName,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final storageDir = Directory(p.join(docs.path, 'attachments'));
    if (!await storageDir.exists()) {
      await storageDir.create(recursive: true);
    }

    final ext = p.extension(file.path);
    final targetPath = p.join(storageDir.path, '${const Uuid().v4()}$ext');
    await file.copy(targetPath);

    final id = const Uuid().v4();
    final now = DateTime.now();
    await into(attachments).insert(AttachmentsCompanion.insert(
      id: id,
      entryId: entryId,
      relativePath: p.relative(targetPath, from: docs.path),
      originalName: Value(originalName ?? p.basename(file.path)),
      mimeType: Value(_mimeTypeFor(file.path)),
      byteLength: Value(await file.length()),
      createdAt: now,
    ));

    await (update(entries)..where((t) => t.id.equals(entryId))).write(
      EntriesCompanion(updatedAt: Value(now)),
    );

    return id;
  }

  Future<List<StoredAttachment>> getAttachmentsForEntry(String entryId) async {
    final rows = await (select(attachments)
          ..where((t) => t.entryId.equals(entryId))
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc)]))
        .get();

    final docs = await getApplicationDocumentsDirectory();
    return rows
        .map(
          (row) => StoredAttachment(
            id: row.id,
            entryId: row.entryId,
            filePath: p.join(docs.path, row.relativePath),
            originalName: row.originalName,
            mimeType: row.mimeType,
            byteLength: row.byteLength,
            createdAt: row.createdAt,
          ),
        )
        .toList(growable: false);
  }

  Future<void> deleteAttachment({required String attachmentId, required String entryId}) async {
    final attachment = await (select(attachments)..where((t) => t.id.equals(attachmentId))).getSingleOrNull();
    if (attachment == null) return;

    final docs = await getApplicationDocumentsDirectory();
    final file = File(p.join(docs.path, attachment.relativePath));
    if (await file.exists()) {
      await file.delete();
    }

    await (delete(attachments)..where((t) => t.id.equals(attachmentId))).go();
    await (update(entries)..where((t) => t.id.equals(entryId))).write(
      EntriesCompanion(updatedAt: Value(DateTime.now())),
    );
  }

  Future<void> updateEntry({
    required String id,
    required String title,
    String? content,
  }) async {
    await (update(entries)..where((t) => t.id.equals(id))).write(
      EntriesCompanion(
        title: Value(title),
        content: Value(content),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> deleteEntry(String id) async {
    final attachmentRows = await (select(attachments)..where((t) => t.entryId.equals(id))).get();
    for (final attachment in attachmentRows) {
      final docs = await getApplicationDocumentsDirectory();
      final file = File(p.join(docs.path, attachment.relativePath));
      if (await file.exists()) {
        await file.delete();
      }
    }
    await (delete(attachments)..where((t) => t.entryId.equals(id))).go();
    await (delete(entries)..where((t) => t.id.equals(id))).go();
  }

  Future<File> exportCategoryArchive({required String categoryId, String? fileName}) async {
    final docs = await getApplicationDocumentsDirectory();
    final tempDir = await getTemporaryDirectory();
    final targetPath = p.join(
      tempDir.path,
      fileName ?? 'friends_vault_category_${DateTime.now().millisecondsSinceEpoch}.zip',
    );
    final targetFile = File(targetPath);
    if (await targetFile.exists()) {
      await targetFile.delete();
    }

    final category = await (select(categories)..where((t) => t.id.equals(categoryId))).getSingleOrNull();
    if (category == null) {
      throw StateError('資料框不存在');
    }

    final entryRows = await (select(entries)
          ..where((t) => t.categoryId.equals(categoryId))
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc)]))
        .get();

    final entryIds = entryRows.map((entry) => entry.id).toList();
    final attachmentRows = entryIds.isEmpty
        ? <Attachment>[]
        : await (select(attachments)
              ..where((t) => t.entryId.isIn(entryIds))
              ..orderBy([(t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc)]))
            .get();

    final attachmentManifest = <Map<String, dynamic>>[];
    final archive = Archive();

    for (final attachment in attachmentRows) {
      final sourceFile = File(p.join(docs.path, attachment.relativePath));
      if (!await sourceFile.exists()) continue;
      final bytes = await sourceFile.readAsBytes();
      final archiveName = 'attachments/${const Uuid().v4()}${p.extension(sourceFile.path)}';
      archive.addFile(ArchiveFile(archiveName, bytes.length, bytes));
      attachmentManifest.add({
        'backupId': attachment.id,
        'entryBackupId': attachment.entryId,
        'archiveName': archiveName,
        'originalName': attachment.originalName ?? p.basename(sourceFile.path),
        'mimeType': attachment.mimeType,
        'byteLength': attachment.byteLength,
        'createdAt': attachment.createdAt.toIso8601String(),
      });
    }

    final manifest = {
      'format': 'friends_vault_export',
      'version': 1,
      'kind': 'category',
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'categories': [
        {
          'backupId': category.id,
          'name': category.name,
          'sortOrder': category.sortOrder,
          'createdAt': category.createdAt.toIso8601String(),
          'updatedAt': category.updatedAt.toIso8601String(),
        }
      ],
      'entries': entryRows
          .map((entry) => {
                'backupId': entry.id,
                'categoryBackupId': entry.categoryId,
                'title': entry.title,
                'content': entry.content,
                'sourceText': entry.sourceText,
                'sourceUrl': entry.sourceUrl,
                'createdAt': entry.createdAt.toIso8601String(),
                'updatedAt': entry.updatedAt.toIso8601String(),
              })
          .toList(),
      'attachments': attachmentManifest,
    };

    final manifestBytes = utf8.encode(jsonEncode(manifest));
    archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));

    final encoder = ZipEncoder();
    final output = encoder.encode(archive);
    if (output == null) {
      throw StateError('無法建立備份檔');
    }

    await targetFile.writeAsBytes(output);
    return targetFile;
  }

  Future<File> exportFullBackupArchive({String? fileName}) async {
    final docs = await getApplicationDocumentsDirectory();
    final tempDir = await getTemporaryDirectory();
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }
    final targetPath = p.join(
      tempDir.path,
      fileName ?? 'friends_vault_full_backup_${DateTime.now().millisecondsSinceEpoch}.zip',
    );
    final targetFile = File(targetPath);
    if (await targetFile.exists()) {
      await targetFile.delete();
    }

    final categoryRows = await (select(categories)
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder, mode: OrderingMode.asc)]))
        .get();
    final entryRows = await (select(entries)
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc)]))
        .get();
    final attachmentRows = await (select(attachments)
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc)]))
        .get();

    final archive = Archive();
    final attachmentManifest = <Map<String, dynamic>>[];

    for (final attachment in attachmentRows) {
      final sourceFile = File(p.join(docs.path, attachment.relativePath));
      if (!await sourceFile.exists()) continue;
      final bytes = await sourceFile.readAsBytes();
      final archiveName = 'attachments/${const Uuid().v4()}${p.extension(sourceFile.path)}';
      archive.addFile(ArchiveFile(archiveName, bytes.length, bytes));
      attachmentManifest.add({
        'backupId': attachment.id,
        'entryBackupId': attachment.entryId,
        'archiveName': archiveName,
        'originalName': attachment.originalName ?? p.basename(sourceFile.path),
        'mimeType': attachment.mimeType,
        'byteLength': attachment.byteLength,
        'createdAt': attachment.createdAt.toIso8601String(),
      });
    }

    final manifest = {
      'format': 'friends_vault_export',
      'version': 1,
      'kind': 'full_backup',
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'categories': categoryRows
          .map((category) => {
                'backupId': category.id,
                'name': category.name,
                'sortOrder': category.sortOrder,
                'createdAt': category.createdAt.toIso8601String(),
                'updatedAt': category.updatedAt.toIso8601String(),
              })
          .toList(),
      'entries': entryRows
          .map((entry) => {
                'backupId': entry.id,
                'categoryBackupId': entry.categoryId,
                'title': entry.title,
                'content': entry.content,
                'sourceText': entry.sourceText,
                'sourceUrl': entry.sourceUrl,
                'createdAt': entry.createdAt.toIso8601String(),
                'updatedAt': entry.updatedAt.toIso8601String(),
              })
          .toList(),
      'attachments': attachmentManifest,
    };

    final manifestBytes = utf8.encode(jsonEncode(manifest));
    archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));

    final encoder = ZipEncoder();
    final output = encoder.encode(archive);
    if (output == null) {
      throw StateError('無法建立備份檔');
    }

    await targetFile.writeAsBytes(output);
    return targetFile;
  }

  Future<void> importBackupArchive({required File archiveFile}) async {
    final docs = await getApplicationDocumentsDirectory();
    final attachmentsDir = Directory(p.join(docs.path, 'attachments'));
    if (!await attachmentsDir.exists()) {
      await attachmentsDir.create(recursive: true);
    }

    final archiveBytes = await archiveFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(archiveBytes);
    final manifestFile = archive.files.where((file) => file.name == 'manifest.json').firstOrNull;
    if (manifestFile == null) {
      throw StateError('備份檔缺少 manifest.json');
    }

    final manifest = jsonDecode(utf8.decode(manifestFile.content)) as Map<String, dynamic>;
    final kind = manifest['kind'];
    if (manifest['format'] != 'friends_vault_export' || (kind != 'category' && kind != 'full_backup')) {
      throw StateError('不支援的備份格式');
    }

    final categoryMaps = (manifest['categories'] as List<dynamic>).cast<Map<String, dynamic>>().toList(growable: false);
    final entryMaps = (manifest['entries'] as List<dynamic>).cast<Map<String, dynamic>>().toList(growable: false);
    final attachmentMaps = (manifest['attachments'] as List<dynamic>).cast<Map<String, dynamic>>().toList(growable: false);

    await transaction(() async {
      await delete(attachments).go();
      await delete(entries).go();
      await delete(categories).go();

      if (await attachmentsDir.exists()) {
        await attachmentsDir.delete(recursive: true);
      }
      await attachmentsDir.create(recursive: true);

      final categoryIdMap = <String, String>{};
      for (final categoryData in categoryMaps) {
        final newCategoryId = const Uuid().v4();
        categoryIdMap[categoryData['backupId'] as String] = newCategoryId;
        await into(categories).insert(
          CategoriesCompanion.insert(
            id: newCategoryId,
            name: categoryData['name'] as String,
            sortOrder: Value(int.tryParse(categoryData['sortOrder'].toString()) ?? 0),
            createdAt: DateTime.parse(categoryData['createdAt'] as String),
            updatedAt: DateTime.parse(categoryData['updatedAt'] as String),
          ),
        );
      }

      final entryIdMap = <String, String>{};
      for (final entryData in entryMaps) {
        final newEntryId = const Uuid().v4();
        final categoryBackupId = entryData['categoryBackupId'] as String;
        final categoryId = categoryIdMap[categoryBackupId];
        if (categoryId == null) {
          continue;
        }
        entryIdMap[entryData['backupId'] as String] = newEntryId;
        await into(entries).insert(
          EntriesCompanion.insert(
            id: newEntryId,
            categoryId: categoryId,
            title: entryData['title'] as String,
            content: Value(entryData['content']?.toString()),
            sourceText: Value(entryData['sourceText']?.toString()),
            sourceUrl: Value(entryData['sourceUrl']?.toString()),
            createdAt: DateTime.parse(entryData['createdAt'] as String),
            updatedAt: DateTime.parse(entryData['updatedAt'] as String),
          ),
        );
      }

      for (final attachmentData in attachmentMaps) {
        final entryBackupId = attachmentData['entryBackupId'] as String;
        final entryId = entryIdMap[entryBackupId];
        if (entryId == null) continue;

        final archiveName = attachmentData['archiveName'] as String;
        final archiveFile = archive.files.where((file) => file.name == archiveName).firstOrNull;
        if (archiveFile == null) continue;

        final ext = p.extension(archiveName);
        final targetPath = p.join(attachmentsDir.path, '${const Uuid().v4()}$ext');
        final targetFile = File(targetPath);
        await targetFile.writeAsBytes(archiveFile.content);

        await into(attachments).insert(
          AttachmentsCompanion.insert(
            id: const Uuid().v4(),
            entryId: entryId,
            relativePath: p.relative(targetPath, from: docs.path),
            originalName: Value(attachmentData['originalName']?.toString()),
            mimeType: Value(attachmentData['mimeType']?.toString()),
            byteLength: Value(int.tryParse(attachmentData['byteLength']?.toString() ?? '0') ?? 0),
            createdAt: DateTime.parse(attachmentData['createdAt'] as String),
          ),
        );
      }
    });
  }

  static String? _mimeTypeFor(String path) {
    final ext = p.extension(path).toLowerCase();
    switch (ext) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.pdf':
        return 'application/pdf';
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
        return 'audio/mp4';
      case '.mp4':
        return 'video/mp4';
      case '.mov':
        return 'video/quicktime';
      default:
        return null;
    }
  }

  /// Escape user input for SQL LIKE patterns.
  static String _likePattern(String query, {bool lowercase = false}) {
    final text = lowercase ? query.toLowerCase() : query;
    final escaped = text
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    return '%$escaped%';
  }

  /// Word-like search: partial match for Chinese/English, case-insensitive ASCII,
  /// multiple terms (space-separated) must all match, ignores extra spaces in text.
  Future<List<SearchHit>> searchAll(String query, {int limit = 50}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return [];

    final tokenConditions = <String>[];
    final variables = <Variable<Object>>[];

    for (final token in tokens) {
      final pattern = _likePattern(token, lowercase: true);
      final compactPattern = _likePattern(
        token.replaceAll(RegExp(r'\s+'), ''),
        lowercase: true,
      );

      tokenConditions.add('''
(
  LOWER(e.title) LIKE ? ESCAPE '\\'
  OR LOWER(IFNULL(e.content, '')) LIKE ? ESCAPE '\\'
  OR LOWER(IFNULL(e.source_text, '')) LIKE ? ESCAPE '\\'
  OR LOWER(IFNULL(e.source_url, '')) LIKE ? ESCAPE '\\'
  OR LOWER(c.name) LIKE ? ESCAPE '\\'
  OR LOWER(IFNULL(a.original_name, '')) LIKE ? ESCAPE '\\'
  OR REPLACE(LOWER(e.title), ' ', '') LIKE ? ESCAPE '\\'
  OR REPLACE(LOWER(IFNULL(e.content, '')), ' ', '') LIKE ? ESCAPE '\\'
  OR REPLACE(LOWER(IFNULL(e.source_text, '')), ' ', '') LIKE ? ESCAPE '\\'
  OR REPLACE(LOWER(IFNULL(e.source_url, '')), ' ', '') LIKE ? ESCAPE '\\'
  OR REPLACE(LOWER(IFNULL(a.original_name, '')), ' ', '') LIKE ? ESCAPE '\\'
)
''');

      variables.addAll([
        Variable<String>(pattern),
        Variable<String>(pattern),
        Variable<String>(pattern),
        Variable<String>(pattern),
        Variable<String>(pattern),
        Variable<String>(pattern),
        Variable<String>(compactPattern),
        Variable<String>(compactPattern),
        Variable<String>(compactPattern),
        Variable<String>(compactPattern),
        Variable<String>(compactPattern),
      ]);
    }

    variables.add(Variable<int>(limit));

    final rows = await customSelect(
      '''
SELECT
  e.id AS entry_id,
  e.title AS title,
  e.content AS content,
  e.updated_at AS updated_at,
  c.id AS category_id,
  c.name AS category_name
FROM entries e
JOIN categories c ON c.id = e.category_id
LEFT JOIN attachments a ON a.entry_id = e.id
WHERE ${tokenConditions.join(' AND ')}
GROUP BY e.id
ORDER BY e.updated_at DESC
LIMIT ?
''',
      variables: variables,
      readsFrom: {entries, categories},
    ).get();

    return rows
        .map(
          (r) => SearchHit(
            entryId: r.read<String>('entry_id'),
            title: r.read<String>('title'),
            content: r.readNullable<String>('content'),
            updatedAt: r.read<DateTime>('updated_at'),
            categoryId: r.read<String>('category_id'),
            categoryName: r.read<String>('category_name'),
          ),
        )
        .toList(growable: false);
  }
}

class SearchHit {
  final String entryId;
  final String categoryId;
  final String categoryName;
  final String title;
  final String? content;
  final DateTime updatedAt;

  SearchHit({
    required this.entryId,
    required this.categoryId,
    required this.categoryName,
    required this.title,
    required this.content,
    required this.updatedAt,
  });
}

class StoredAttachment {
  final String id;
  final String entryId;
  final String filePath;
  final String? originalName;
  final String? mimeType;
  final int? byteLength;
  final DateTime createdAt;

  StoredAttachment({
    required this.id,
    required this.entryId,
    required this.filePath,
    required this.originalName,
    required this.mimeType,
    required this.byteLength,
    required this.createdAt,
  });
}

