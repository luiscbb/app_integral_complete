import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'migration preserves occupied tables and permits the same id in another business',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'table_business_migration_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      final file = path.join(
        directory.path,
        'BaumarSolutions',
        'database',
        'integral_pos_v1.db',
      );
      await Directory(path.dirname(file)).create(recursive: true);
      ffi.sqfliteFfiInit();
      Database? upgraded;
      try {
        final old = await ffi.databaseFactoryFfi.openDatabase(
          file,
          options: OpenDatabaseOptions(
            version: 43,
            onCreate: (db, _) async {
              await db.execute('CREATE TABLE providers (id INTEGER PRIMARY KEY)');
              await db.execute('CREATE TABLE purchases (id INTEGER PRIMARY KEY)');
              await db.execute('''
                CREATE TABLE sale_details (
                  id INTEGER PRIMARY KEY,
                  sale_id INTEGER NOT NULL,
                  product_id INTEGER,
                  product_name TEXT NOT NULL,
                  quantity REAL NOT NULL,
                  price_at_sale REAL NOT NULL,
                  cost_at_sale REAL NOT NULL DEFAULT 0,
                  cancelled INTEGER NOT NULL DEFAULT 0
                )
              ''');
              await db.insert('sale_details', {
                'id': 7,
                'sale_id': 2,
                'product_id': 4,
                'product_name': 'Producto anterior',
                'quantity': 2,
                'price_at_sale': 25,
                'cost_at_sale': 10,
              });
              await db.execute('''
              CREATE TABLE billiard_tables (
                id INTEGER PRIMARY KEY,
                billar_id TEXT NOT NULL,
                name TEXT NOT NULL,
                table_type TEXT NOT NULL DEFAULT 'Pool',
                is_occupied INTEGER NOT NULL DEFAULT 0,
                start_time TEXT,
                orders TEXT DEFAULT '[]',
                synced INTEGER NOT NULL DEFAULT 1,
                is_deleted INTEGER NOT NULL DEFAULT 0
              )
            ''');
              await db.execute(
                'CREATE INDEX table_name_idx ON billiard_tables(name)',
              );
              await db.insert('billiard_tables', {
                'id': 1,
                'billar_id': 'A',
                'name': 'Mesa abierta',
                'is_occupied': 1,
                'start_time': '2026-01-03T12:00:00Z',
                'orders': '[{"productId":7,"quantity":2}]',
                'synced': 0,
              });
            },
          ),
        );
        await old.close();
        upgraded = await DatabaseHelper.instance.database;
        final original = (await upgraded.query('billiard_tables')).single;
        expect(original['is_occupied'], 1);
        expect(original['start_time'], '2026-01-03T12:00:00Z');
        expect(original['orders'], '[{"productId":7,"quantity":2}]');
        expect(original['synced'], 0);
        expect(
          (await upgraded.rawQuery(
            'PRAGMA index_list(billiard_tables)',
          )).any((index) => index['name'] == 'table_name_idx'),
          isTrue,
        );
        await upgraded.insert('billiard_tables', {
          'id': 1,
          'billar_id': 'B',
          'name': 'Otra mesa',
        });
        expect(await upgraded.query('billiard_tables'), hasLength(2));
        final sale = (await upgraded.query('sale_details')).single;
        expect(sale['product_id'], 4);
        expect(sale['product_name'], 'Producto anterior');
        expect(sale['quantity'], 2);
        expect(sale['price_at_sale'], 25);
        expect(sale['cost_at_sale'], 10);
        expect(sale['cost_available'], 1);
      } finally {
        await upgraded?.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
