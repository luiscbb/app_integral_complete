import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'migration 57 to 61 preserves consumptions and creates staff table caches',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'staff_table_late_',
      );
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
          version: 57,
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE staff_table_service_drafts (
              service_id TEXT PRIMARY KEY, actor_id TEXT NOT NULL, billar_id TEXT NOT NULL,
              table_id INTEGER NOT NULL, table_type TEXT NOT NULL, opened_at TEXT NOT NULL,
              state TEXT NOT NULL
            )
          ''');
            await db.execute('''
            CREATE TABLE staff_table_service_consumptions (
              sequence INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL UNIQUE,
              service_id TEXT NOT NULL, actor_id TEXT NOT NULL, billar_id TEXT NOT NULL,
              product_id INTEGER NOT NULL, product_name TEXT NOT NULL, quantity REAL NOT NULL,
              price REAL NOT NULL, recorded_at TEXT NOT NULL, confirmed INTEGER NOT NULL DEFAULT 0
            )
          ''');
            for (final confirmed in [0, 1]) {
              await db.insert('staff_table_service_consumptions', {
                'request_id': 'request-$confirmed',
                'service_id': 'service',
                'actor_id': 'waiter',
                'billar_id': 'A',
                'product_id': confirmed + 1,
                'product_name': 'Producto',
                'quantity': 1.0,
                'price': 10.0,
                'recorded_at': '2026-01-01T00:00:00Z',
                'confirmed': confirmed,
              });
            }
          },
        ),
      );
      await previous.close();
      final db = await DatabaseHelper.instance.database;
      try {
        expect(await db.getVersion(), 61);
        final items = await db.query(
          'staff_table_service_consumptions',
          orderBy: 'sequence',
        );
        expect(items.map((row) => row['confirmed']), [0, 1]);
        expect(items.map((row) => row['late']), [0, 0]);
        expect(items.map((row) => row['request_id']), [
          'request-0',
          'request-1',
        ]);
        expect(await db.query('staff_table_checkout_outbox'), isEmpty);
        expect(await db.query('staff_table_visibility_cache'), isEmpty);
        expect(await db.query('staff_table_late_adjustment_outbox'), isEmpty);
      } finally {
        await db.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
