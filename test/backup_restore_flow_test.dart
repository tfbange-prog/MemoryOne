import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:friends_vault/db/app_db.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final baseDir = Directory('${Directory.systemTemp.path}/friends_vault_test_${DateTime.now().microsecondsSinceEpoch}');
  baseDir.createSync(recursive: true);

  final documentsDir = Directory('${baseDir.path}/documents');
  final tempDir = Directory('${baseDir.path}/tmp');
  final supportDir = Directory('${baseDir.path}/support');
  documentsDir.createSync(recursive: true);
  tempDir.createSync(recursive: true);
  supportDir.createSync(recursive: true);

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    pathProviderChannel,
    (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
          return documentsDir.path;
        case 'getTemporaryPath':
          return tempDir.path;
        case 'getTemporaryDirectory':
          return tempDir.path;
        case 'getApplicationSupportDirectory':
          return supportDir.path;
        default:
          return null;
      }
    },
  );

  test('backup and restore full database flow works', () async {
    final docsDir = await getApplicationDocumentsDirectory();
    final docsPath = Directory(docsDir.path);
    await docsPath.create(recursive: true);

    for (final entity in docsPath.listSync(recursive: false)) {
      if (entity is File && entity.path.contains('friends_vault.sqlite')) {
        await entity.delete();
      } else if (entity is Directory && entity.path.endsWith('attachments')) {
        await entity.delete(recursive: true);
      }
    }

    final dbFile = File(p.join(docsDir.path, 'friends_vault.sqlite'));
    if (await dbFile.exists()) {
      await dbFile.delete();
    }

    final attachmentsDir = Directory(p.join(docsDir.path, 'attachments'));
    if (await attachmentsDir.exists()) {
      await attachmentsDir.delete(recursive: true);
    }

    final db = AppDb();
    await db.bootstrap();

    final categoryId = await db.createCategory(name: '測試資料框');
    final entryId = await db.createEntry(
      categoryId: categoryId,
      title: '測試標題',
      content: '測試內容',
    );

    final tempFile = File(p.join(docsDir.path, 'temp_test.bin'));
    await tempFile.writeAsBytes([1, 2, 3, 4]);
    await db.addAttachment(
      entryId: entryId,
      file: tempFile,
      originalName: 'test.bin',
    );

    final backupFile = await db.exportFullBackupArchive(fileName: 'test_backup.zip');
    expect(await backupFile.exists(), isTrue);

    await db.close();

    final restoredDb = AppDb();
    await restoredDb.bootstrap();
    await restoredDb.importBackupArchive(archiveFile: backupFile);

    final restoredCategories = await (restoredDb.select(restoredDb.categories)
          ..where((t) => t.name.equals('測試資料框')))
        .get();
    expect(restoredCategories, hasLength(1));

    final restoredEntries = await (restoredDb.select(restoredDb.entries)
          ..where((t) => t.title.equals('測試標題')))
        .get();
    expect(restoredEntries, hasLength(1));
    expect(restoredEntries.single.content, '測試內容');

    final attachments = await restoredDb.getAttachmentsForEntry(restoredEntries.single.id);
    expect(attachments, hasLength(1));
    expect(attachments.single.originalName, 'test.bin');

    await restoredDb.close();
  });
}
