import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('upgrading an existing local database preserves unclassified sales', () async {
    final directory = await Directory.systemTemp.createTemp('sale_origin_migration_');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pathChannel, (call) async => directory.path);
    final dbPath = path.join(
      directory.path,
      'BaumarSolutions',
      'database',
      'integral_pos_v1.db',
    );
    await Directory(path.dirname(dbPath)).create(recursive: true);
    ffi.sqfliteFfiInit();

    Database? upgraded;
    try {
      final old = await ffi.databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 36,
          onCreate: (db, version) async {
            await db.execute('create table sale_details (id integer primary key)');
            await db.execute('create table pending_sales (id integer primary key, product text, synced integer)');
            await db.insert('pending_sales', {'id': 1, 'product': 'VENTA ANTERIOR', 'synced': 0});
            await db.execute(
              'create table purchases (id integer primary key, reference text, synced integer)',
            );
            await db.insert('purchases', {'id': 1, 'reference': 'ANTERIOR', 'synced': 0});
            await db.execute('create table sales_history (id integer primary key, type text)');
            await db.insert('sales_history', {'id': 1, 'type': 'Venta anterior'});
            await db.execute('''
              create table products (
                id integer primary key, barcode text, name text, description text,
                price real, cost real, stock real, image_path text, is_promo integer,
                parent_id integer, pieces_per_unit integer, category text,
                presentation text, is_active integer, synced integer
              )
            ''');
            await db.insert('products', {'id': 1, 'name': 'PRODUCTO', 'stock': 10, 'synced': 0});
            await db.execute('create table providers (id integer primary key, name text not null)');
            await db.insert('providers', {'id': 1, 'name': 'PROVEEDOR'});
          },
        ),
      );
      await old.close();

      upgraded = await DatabaseHelper.instance.database;
      final rows = await upgraded.query('sales_history');
      expect(rows.single['type'], 'Venta anterior');
      expect(rows.single['source_module'], isNull);
      await upgraded.update('sales_history', {'source_module': 'quick_sale'});
      expect((await upgraded.query('sales_history')).single['source_module'], 'quick_sale');
      final product = (await upgraded.query('products')).single;
      expect(product['stock'], 10);
      expect(product['stock_revision'], isNull);
      expect(product['stock_conflict'], 0);
      await upgraded.rawUpdate('UPDATE products SET stock = 9, synced = 0 WHERE id = 1');
      expect((await upgraded.query('products')).single['local_revision'], 1);
      expect(await upgraded.query('pending_staff_account_requests'), isEmpty);
      expect(await upgraded.query('pending_provider_operations'), isEmpty);
      expect((await upgraded.query('providers')).single['is_active'], 1);
      final purchase = (await upgraded.query('purchases')).single;
      expect(purchase['reference'], 'ANTERIOR');
      expect(purchase['synced'], 0);
      expect(purchase['billar_id'], isNull);
      final pending = (await upgraded.query('pending_sales')).single;
      expect(pending['product'], 'VENTA ANTERIOR');
      expect(pending['synced'], 0);
      expect(pending['actor_id'], isNull);
      expect(pending['billar_id'], isNull);
    } finally {
      await upgraded?.close();
      messenger.setMockMethodCallHandler(pathChannel, null);
      await directory.delete(recursive: true);
    }
  });
}
