import 'dart:io';

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
    return driftDatabase(
      name: 'friends_vault.sqlite',
      native: const DriftNativeOptions(
        // Keep defaults; sqlite3_flutter_libs provides the engine.
      ),
    );
  }

  Future<void> bootstrap() async {
    // Ensure attachments dir exists
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'attachments'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
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

  Future<String> createCategory({required String name, int sortOrder = 0}) async {
    final id = const Uuid().v4();
    final now = DateTime.now();
    await into(categories).insert(CategoriesCompanion.insert(
      id: id,
      name: name,
      createdAt: now,
      updatedAt: now,
    ));
    return id;
  }

  Future<void> renameCategory({required String id, required String name}) async {
    await (update(categories)..where((t) => t.id.equals(id))).write(
      CategoriesCompanion(
        name: Value(name),
        updatedAt: Value(DateTime.now()),
      ),
    );
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
    await (delete(attachments)..where((t) => t.entryId.equals(id))).go();
    await (delete(entries)..where((t) => t.id.equals(id))).go();
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
  OR REPLACE(LOWER(e.title), ' ', '') LIKE ? ESCAPE '\\'
  OR REPLACE(LOWER(IFNULL(e.content, '')), ' ', '') LIKE ? ESCAPE '\\'
  OR REPLACE(LOWER(IFNULL(e.source_text, '')), ' ', '') LIKE ? ESCAPE '\\'
  OR REPLACE(LOWER(IFNULL(e.source_url, '')), ' ', '') LIKE ? ESCAPE '\\'
)
''');

      variables.addAll([
        Variable<String>(pattern),
        Variable<String>(pattern),
        Variable<String>(pattern),
        Variable<String>(pattern),
        Variable<String>(pattern),
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
WHERE ${tokenConditions.join(' AND ')}
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

