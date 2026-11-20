import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/quick_sale/data/staff_quick_sale_outbox.dart';
import 'package:app_integral_complete/features/quick_sale/data/staff_sale_cache.dart';
import 'package:app_integral_complete/features/quick_sale/domain/entities/staff_sale_product.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cache migration, reservations and revisions survive reopening safely',
    () async {
      final directory = await Directory.systemTemp.createTemp('staff_cache_');
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
      final previous = await ffi.databaseFactoryFfi.openDatabase(
        file,
        options: ffi.OpenDatabaseOptions(
          version: 49,
          onCreate: (db, version) async {
            await db.execute('CREATE TABLE providers (id INTEGER PRIMARY KEY)');
            await db.execute('CREATE TABLE purchases (id INTEGER PRIMARY KEY)');
            await db.execute(
              'CREATE TABLE products (id INTEGER PRIMARY KEY, stock REAL, cost REAL)',
            );
            await db.insert('products', {'id': 1, 'stock': 100, 'cost': 77});
            await db.execute('''
          CREATE TABLE pending_staff_sales (
            actor_id TEXT NOT NULL, billar_id TEXT NOT NULL,
            request_id TEXT NOT NULL UNIQUE, payload TEXT NOT NULL,
            remote_sale_id INTEGER, reservation_snapshot TEXT,
            PRIMARY KEY (actor_id, billar_id)
          )
        ''');
          },
        ),
      );
      await previous.close();
      var db = await DatabaseHelper.instance.database;
      var actor = 'A';
      var billar = 'X';
      var generation = 1;
      SyncSession capture() {
        final auth =
            Session.fromJson({
              'access_token': 'token',
              'token_type': 'bearer',
              'user': {
                'id': actor,
                'aud': 'authenticated',
                'app_metadata': <String, dynamic>{},
                'user_metadata': <String, dynamic>{},
                'created_at': '2025-01-01T00:00:00Z',
              },
            })!;
        return (
          actorId: actor,
          billarId: billar,
          token: 'token',
          authSession: auth,
          scopeGeneration: generation,
        );
      }

      void requireSession(SyncSession session) {
        if (session.actorId != actor ||
            session.billarId != billar ||
            session.scopeGeneration != generation) {
          throw StateError('La cuenta o el billar cambió.');
        }
      }

      StaffSaleProduct product(
        int id, {
        int revision = 5,
        double stock = 12,
        int? parent,
        Map<int, int> components = const {},
      }) => StaffSaleProduct.fromMap({
        'id': id,
        'billar_id': billar,
        'name': 'Producto $id',
        'price': 10,
        'stock': stock,
        'inventory_stock': stock,
        'stock_revision': revision,
        'is_promo': components.isEmpty ? 0 : 1,
        'parent_id': parent,
        'pieces_per_unit': parent == null ? 1 : 4,
        'components':
            components.entries
                .map(
                  (entry) => {'product_id': entry.key, 'quantity': entry.value},
                )
                .toList(),
      }, billarId: billar);
      var cache = StaffSaleCache(db, requireSession);
      var session = capture();
      try {
        expect(await db.getVersion(), 61);
        expect((await db.query('products')).single, {
          'id': 1,
          'stock': 100.0,
          'cost': 77.0,
        });
        await cache.replaceCatalog(session, [
          product(1),
          product(2, stock: 20),
          product(10, components: {1: 2, 2: 1}),
          product(11, parent: 1),
        ]);
        await cache.saveCart(session, {10: 1, 11: 1, 1: 2});
        final products = {
          for (final p in await cache.catalog(session)) p.id: p,
        };
        final cart = await cache.cart(session);
        expect(products[1]!.availableStock(products, cart), 4);
        expect(products[10]!.availableStock(products, cart), 2);
        expect(products[11]!.availableStock(products, cart), 1);
        await cache.replaceCatalog(session, [
          product(1, revision: 4, stock: 100),
        ]);
        expect((await cache.catalog(session)).first.inventoryStock, 12);
        await expectLater(
          cache.replaceCatalog(session, [product(1, stock: 99)]),
          throwsStateError,
        );
        expect(await cache.cart(session), cart);
        await expectLater(
          db.transaction((txn) async {
            await cache.reconcileStock(
              txn,
              session,
              productId: 1,
              stock: 9,
              revision: 6,
            );
            await cache.reconcileStock(
              txn,
              session,
              productId: 999,
              stock: 1,
              revision: 6,
            );
          }),
          throwsStateError,
        );
        expect((await cache.catalog(session)).first.inventoryStock, 12);

        final stale = session;
        actor = 'B';
        generation++;
        session = capture();
        expect(await cache.catalog(session), isEmpty);
        expect(await cache.cart(session), isEmpty);
        await expectLater(cache.saveCart(session, {1: 1}), throwsStateError);
        await cache.replaceCatalog(session, [product(1, stock: 999)]);
        await cache.saveCart(session, {1: 2});
        await expectLater(cache.cart(stale), throwsStateError);
        actor = 'A';
        generation++;
        session = capture();
        expect(await cache.cart(session), cart);
        await cache.saveCart(session, {1: 1});
        final outbox = StaffQuickSaleOutbox.staffCache(cache);
        final pending = await outbox.prepare(
          session: session,
          saleDate: '2026-11-16',
          paymentMethod: 'Efectivo',
          total: 10,
          paid: 10,
          items: [
            const StaffQuickSaleItem(
              productId: 1,
              productName: 'Producto 1',
              quantity: 1,
              price: 10,
            ),
          ],
        );
        await expectLater(cache.saveCart(session, {}), throwsStateError);
        await db.close();
        db = await ffi.databaseFactoryFfi.openDatabase(file);
        cache = StaffSaleCache(db, requireSession);
        expect(await cache.cart(session), {1: 1});
        expect(
          (await StaffQuickSaleOutbox.staffCache(
            cache,
          ).pending(session))!.requestId,
          pending.requestId,
        );
        for (final row in await db.query('staff_sale_catalog')) {
          final payload =
              jsonDecode(row['product_json'] as String) as Map<String, dynamic>;
          expect(payload.containsKey('cost'), isFalse);
        }
        expect((await db.query('products')).single, {
          'id': 1,
          'stock': 100.0,
          'cost': 77.0,
        });
      } finally {
        await db.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
