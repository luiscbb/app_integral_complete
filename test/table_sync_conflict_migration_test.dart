import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migration 56 to 57 preserves existing data', () async {
    final directory = await Directory.systemTemp.createTemp('table_migration_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    final dbPath = path.join(
      directory.path,
      'BaumarSolutions',
      'database',
      'integral_pos_v1.db',
    );
    await Directory(path.dirname(dbPath)).create(recursive: true);
    ffi.sqfliteFfiInit();
    final previous = await ffi.databaseFactoryFfi.openDatabase(
      dbPath,
      options: ffi.OpenDatabaseOptions(
        version: 56,
        onCreate: (db, _) async {
          await db.execute('CREATE TABLE existing_data (value TEXT NOT NULL)');
          await db.insert('existing_data', {'value': 'preserved'});
        },
      ),
    );
    await previous.close();
    final db = await DatabaseHelper.instance.database;
    try {
      expect(await db.getVersion(), 61);
      expect((await db.query('existing_data')).single['value'], 'preserved');
      expect(await db.query('table_sync_conflicts'), isEmpty);
    } finally {
      await db.close();
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    }
  });
}
