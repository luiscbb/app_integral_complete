import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migration from 48 preserves pending operations', () async {
    final directory = await Directory.systemTemp.createTemp('promo_migration_');
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
    final old = await ffi.databaseFactoryFfi.openDatabase(
      dbPath,
      options: ffi.OpenDatabaseOptions(
        version: 48,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE providers (id INTEGER PRIMARY KEY)');
          await db.execute('CREATE TABLE purchases (id INTEGER PRIMARY KEY)');
          await db.execute(
            'CREATE TABLE pending_staff_sales (request_id TEXT, payload TEXT)',
          );
          await db.insert('pending_staff_sales', {
            'request_id': 'staff-pending',
            'payload': '{"total":10}',
          });
          await db.execute(
            'CREATE TABLE products (id INTEGER PRIMARY KEY, synced INTEGER)',
          );
          await db.insert('products', {'id': 42, 'synced': 0});
        },
      ),
    );
    await old.close();
    final db = await DatabaseHelper.instance.database;
    try {
      expect(await db.getVersion(), 53);
      expect((await db.query('pending_staff_sales')).single, {
        'request_id': 'staff-pending',
        'payload': '{"total":10}',
      });
      expect((await db.query('products')).single, {'id': 42, 'synced': 0});
      expect(await db.query('pending_owner_promos'), isEmpty);
    } finally {
      await db.close();
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    }
  });
}
