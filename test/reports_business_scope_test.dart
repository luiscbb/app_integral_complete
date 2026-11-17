import 'dart:async';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_service.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/features/reports/data/repositories/reports_repository.dart';
import 'package:app_integral_complete/features/sales/data/repositories/billiard_table_repository.dart';
import 'package:app_integral_complete/features/sales/data/repositories/sales_repository.dart';
import 'package:app_integral_complete/features/sales/data/repositories/stock_reservation_service.dart';
import 'package:app_integral_complete/features/sales/domain/entities/sale_item_entity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reports exclude sales, expenses and movements from another business',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'reports_business_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const path = MethodChannel('plugins.flutter.io/path_provider');
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity',
      );
      const events = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      messenger.setMockMethodCallHandler(path, (_) async => directory.path);
      messenger.setMockMethodCallHandler(connectivity, (_) async => ['none']);
      messenger.setMockMethodCallHandler(events, (_) async => null);
      SharedPreferences.setMockInitialValues({'billar_id': 'A'});
      await PreferencesService().init();

      Database? db;
      try {
        db = await DatabaseHelper.instance.database;
        final saleIds = <String, int>{};
        final purchaseIds = <String, int>{};
        for (final (business, amount) in [('A', 10.0), ('B', 70.0)]) {
          saleIds[business] = await db.insert('sales_history', {
            'billar_id': business,
            'total': amount,
            'paid': amount,
            'date': '2026-01-03T12:00:00',
            'type': 'Venta Rápida',
            'payment_method': 'Efectivo',
            'synced': 1,
          });
          await db.insert('sale_details', {
            'sale_id': saleIds[business],
            'product_name': business,
            'quantity': 1,
            'price_at_sale': amount,
            'cost_at_sale': 2,
          });
          await db.insert('cash_outflows', {
            'billar_id': business,
            'outflow_type': 'gasto',
            'amount': amount,
            'description': business,
            'created_at': '2026-01-03T12:00:00',
            'synced': 1,
          });
          await db.insert('inventory_movements', {
            'billar_id': business,
            'product_id': 1,
            'movement_type': 'sale',
            'quantity': -1,
            'created_at': '2026-01-03T12:00:00',
            'synced': 1,
          });
          purchaseIds[business] = await db.insert('purchases', {
            'billar_id': business,
            'total': amount,
            'reference': business,
            'date': '2026-01-03T12:00:00',
            'synced': 1,
          });
          await db.insert('purchase_details', {
            'purchase_id': purchaseIds[business],
            'product_id': 1,
            'quantity': 1,
            'cost_per_unit': amount,
          });
        }
        final legacyId = await db.insert('purchases', {
          'total': 5,
          'reference': 'ANTERIOR',
          'date': '2026-01-03T12:00:00',
          'synced': 1,
        });
        await db.insert('purchase_details', {
          'purchase_id': legacyId,
          'product_id': 1,
          'quantity': 1,
          'cost_per_unit': 5,
        });
        final repo = ReportsRepository();
        final start = DateTime(2026, 1, 3);
        final end = DateTime(2026, 1, 3);
        expect(
          (await repo.getSalesByDateRange(start, end)).single['billar_id'],
          'A',
        );
        expect(await repo.getSaleDetails(saleIds['B']!), isEmpty);
        expect(
          (await repo.getSaleDetails(saleIds['A']!)).single['product_name'],
          'A',
        );
        expect(
          (await repo.getCashOutflows(start, end)).single['billar_id'],
          'A',
        );
        expect((await repo.getInventoryMovements(1)).single['billar_id'], 'A');
        expect(
          (await repo.getPurchasesByDateRange(
            start,
            end,
          )).map((row) => row['reference']).toSet(),
          {'A'},
        );
        expect((await repo.getPurchasesSummary(start, end))['total'], 10);
        expect((await repo.getCashFlowSummary(start, end))['purchases'], 10);
        expect(await repo.getPurchaseDetails(purchaseIds['B']!), isEmpty);
        expect(await repo.getPurchaseDetails(purchaseIds['A']!), hasLength(1));
        expect(await repo.getPurchaseDetails(legacyId), isEmpty);
        final profit = await repo.getProfitSummary(start, end);
        expect(profit['sales'], 10);
        expect(profit['expenses'], 10);
        expect(profit['costOfGoodsSold'], 2);
        await db.update(
          'sale_details', {'cost_available': 0},
          where: 'sale_id = ?', whereArgs: [saleIds['A']],
        );
        final incomplete = await repo.getProfitSummary(start, end);
        expect(incomplete['costsAvailable'], isFalse);
        expect(incomplete['costOfGoodsSold'], isNull);
        expect(incomplete['profit'], isNull);
        await db.update(
          'sale_details', {'cost_available': 1},
          where: 'sale_id = ?', whereArgs: [saleIds['A']],
        );

        await PreferencesService().setBillarId('B');
        expect(
          (await repo.getSalesByDateRange(start, end)).single['billar_id'],
          'B',
        );
        expect(await repo.getSaleDetails(saleIds['A']!), isEmpty);
        expect(
          (await repo.getCashOutflows(start, end)).single['billar_id'],
          'B',
        );
        expect((await repo.getInventoryMovements(1)).single['billar_id'], 'B');
        expect(
          (await repo.getPurchasesByDateRange(
            start,
            end,
          )).map((row) => row['reference']).toSet(),
          {'B'},
        );
        expect(await repo.getPurchaseDetails(purchaseIds['A']!), isEmpty);

        await PreferencesService().setBillarId('A');
        var currentActorId = 'admin-A';
        final salesRepo = SalesRepository(currentActorId: () => currentActorId);
        expect(
          (await salesRepo.getSalesByDate(
            start,
          )).map((row) => row['billar_id']),
          ['A'],
        );
        expect(
          (await salesRepo.getSalesByDateRange(
            start,
            end,
          )).map((row) => row['billar_id']),
          ['A'],
        );
        expect(
          (await salesRepo.getSalesByMonth(
            2026,
            1,
          )).map((row) => row['billar_id']),
          ['A'],
        );
        expect(await salesRepo.getSalesDetails(saleIds['B']!), isEmpty);
        expect(await salesRepo.getSalesDetails(saleIds['A']!), hasLength(1));
        expect(await salesRepo.cancelSale(saleIds['B']!), isFalse);
        expect(
          (await db.query(
            'sales_history',
            where: 'id = ?',
            whereArgs: [saleIds['B']],
          )).single['cancelled'],
          0,
        );
        for (final business in ['A', 'B']) {
          await db.insert('sales_history', {
            'billar_id': business,
            'total': 5,
            'paid': 5,
            'date': DateTime.now().toIso8601String(),
            'type': 'Venta Rápida',
            'payment_method': 'Efectivo',
            'synced': 1,
          });
        }
        expect(
          (await salesRepo.getTodaySales()).map((row) => row['billar_id']),
          ['A'],
        );
        await db.insert('products', {
          'id': 42,
          'billar_id': 'B',
          'name': 'OTRO',
        });
        final before = (await db.query('sales_history')).length;
        await expectLater(
          salesRepo.saveSale(
            items: [
              SaleItemEntity(productId: 42, productName: 'OTRO', price: 10),
            ],
            total: 10,
            paid: 10,
            paymentMethod: 'Efectivo',
            saleType: 'Venta Rápida',
            origin: SaleOrigin.quickSale,
          ),
          throwsStateError,
        );
        expect(await db.query('sales_history'), hasLength(before));

        await db.insert('billiard_tables', {
          'id': 42,
          'billar_id': 'B',
          'name': 'Mesa B',
          'is_occupied': 1,
          'orders': '[{"productId":42,"quantity":1}]',
        });
        await db.insert('temp_reservations', {
          'source': 'table',
          'source_id': 42,
          'product_id': 42,
          'quantity': 1,
          'created_at': '2026-01-03T12:00:00',
        });
        await expectLater(salesRepo.occupyTable(42), throwsStateError);
        await expectLater(
          salesRepo.saveTableOrder(tableId: 42, items: [], tableName: 'Mesa B'),
          throwsStateError,
        );
        await expectLater(salesRepo.freeTable(42), throwsStateError);
        final table =
            (await db.query(
              'billiard_tables',
              where: 'id = ?',
              whereArgs: [42],
            )).single;
        expect(table['is_occupied'], 1);
        expect(table['orders'], '[{"productId":42,"quantity":1}]');
        expect(
          await db.query(
            'temp_reservations',
            where: 'source_id = ?',
            whereArgs: [42],
          ),
          hasLength(1),
        );
        for (final id in [51, 52]) {
          await db.insert('products', {
            'id': id,
            'billar_id': 'A',
            'name': 'PRODUCTO $id',
          });
        }
        for (final (source, productId) in [
          ('quick_sale', 51),
          ('customer', 52),
          ('quick_sale', 42),
        ]) {
          await db.insert('temp_reservations', {
            'source': source,
            'source_id': 0,
            'product_id': productId,
            'quantity': 1,
            'created_at': '2026-01-03T12:00:00',
          });
        }
        final reservations = StockReservationService(
          currentActorId: () => currentActorId,
        );
        await db.insert('pending_staff_sales', {
          'actor_id': currentActorId, 'billar_id': 'A',
          'request_id': 'pending-test', 'payload': '{}',
        });
        await expectLater(reservations.clearQuickSaleReservation(), throwsStateError);
        await expectLater(
          salesRepo.saveSale(
            items: [SaleItemEntity(productId: 51, productName: 'Producto', price: 10)],
            total: 10, paid: 10, paymentMethod: 'Efectivo',
            saleType: 'Venta Rápida', origin: SaleOrigin.quickSale,
          ),
          throwsA(isA<SaleScopeException>()),
        );
        await db.delete('pending_staff_sales', where: 'request_id = ?', whereArgs: ['pending-test']);
        expect(
          await reservations.getReservedQuantities(includeSource: 'quick_sale'),
          {51: 1.0},
        );
        await expectLater(
          reservations.setQuickSaleReservation([
            SaleItemEntity(productId: 42, productName: 'OTRO', price: 10),
          ]),
          throwsStateError,
        );
        expect(
          await reservations.getReservedQuantities(includeSource: 'quick_sale'),
          {51: 1.0},
        );
        await reservations.setQuickSaleReservation([
          SaleItemEntity(
            productId: 51,
            productName: 'PRODUCTO 51',
            price: 10,
            quantity: 2,
          ),
        ]);
        expect(
          await reservations.getReservedQuantities(includeSource: 'quick_sale'),
          {51: 2.0},
        );
        final saleItems = [
          SaleItemEntity(
            productId: 51,
            productName: 'PRODUCTO 51',
            price: 10,
            quantity: 2,
          ),
          SaleItemEntity(productId: 52, productName: 'PRODUCTO 52', price: 5),
        ];
        final saleCount = (await db.query('sales_history')).length;
        final movementCount = (await db.query('inventory_movements')).length;
        await db.execute('''
          CREATE TRIGGER reject_test_movement
          BEFORE INSERT ON inventory_movements
          WHEN NEW.movement_type = 'sale' AND NEW.product_id = 52
          BEGIN SELECT RAISE(ABORT, 'test failure'); END
        ''');
        Future<int> saveQuickSale() => salesRepo.saveSale(
          items: saleItems,
          total: 25,
          paid: 25,
          paymentMethod: 'Efectivo',
          saleType: 'Venta Rápida',
          origin: SaleOrigin.quickSale,
        );
        await expectLater(saveQuickSale(), throwsA(isA<DatabaseException>()));
        expect(await db.query('sales_history'), hasLength(saleCount));
        expect(await db.query('inventory_movements'), hasLength(movementCount));
        expect(
          await reservations.getReservedQuantities(includeSource: 'quick_sale'),
          {51: 2.0},
        );
        await db.execute('DROP TRIGGER reject_test_movement');
        final savedSale = await saveQuickSale();
        expect(
          await db.query(
            'inventory_movements',
            where: 'reference_id = ? AND movement_type = ?',
            whereArgs: [savedSale, 'sale'],
          ),
          hasLength(2),
        );
        expect(
          await reservations.getReservedQuantities(includeSource: 'quick_sale'),
          isEmpty,
        );
        expect(
          await db.query(
            'temp_reservations',
            where: 'source = ? AND product_id = ?',
            whereArgs: ['quick_sale', 42],
          ),
          hasLength(1),
        );
        await reservations.setQuickSaleReservation([
          SaleItemEntity(
            productId: 51,
            productName: 'PRODUCTO 51',
            price: 10,
            quantity: 2,
          ),
        ]);
        await db.insert('billiard_tables', {
          'id': 70,
          'billar_id': 'A',
          'name': 'Mesa A',
          'is_occupied': 0,
          'orders': '[]',
        });
        final actorLockStarted = Completer<void>();
        final actorLockRelease = Completer<void>();
        final actorLock = db.transaction((_) async {
          actorLockStarted.complete();
          await actorLockRelease.future;
        });
        await actorLockStarted.future;
        final countBeforeSwitch = saleCount + 1;
        final actorRejected = expectLater(saveQuickSale(), throwsStateError);
        final actorCancelRejected = expectLater(
          salesRepo.cancelSale(saleIds['A']!),
          throwsStateError,
        );
        final actorReservationRejected = expectLater(
          reservations.setQuickSaleReservation([
            SaleItemEntity(
              productId: 51,
              productName: 'PRODUCTO 51',
              price: 10,
              quantity: 3,
            ),
          ]),
          throwsStateError,
        );
        final actorTableRejected = expectLater(
          salesRepo.occupyTable(70),
          throwsStateError,
        );
        final actorReservationReadRejected = expectLater(
          reservations.getReservedQuantities(),
          throwsStateError,
        );
        final actorCombinedReadRejected = expectLater(
          salesRepo.getReservedQuantities(),
          throwsStateError,
        );
        final actorTableReadRejected = expectLater(
          salesRepo.getTables(),
          throwsStateError,
        );
        currentActorId = 'admin-B';
        actorLockRelease.complete();
        await actorLock;
        await actorRejected;
        await actorCancelRejected;
        await actorReservationRejected;
        await actorTableRejected;
        await actorReservationReadRejected;
        await actorCombinedReadRejected;
        await actorTableReadRejected;
        currentActorId = 'admin-A';
        final withoutSession = StockReservationService(
          currentActorId: () => null,
        );
        await expectLater(
          withoutSession.clearQuickSaleReservation(),
          throwsStateError,
        );
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ? AND billar_id = ?',
            whereArgs: [70, 'A'],
          )).single['is_occupied'],
          0,
        );
        await db.delete(
          'billiard_tables',
          where: 'id = ? AND billar_id = ?',
          whereArgs: [70, 'A'],
        );
        expect(await db.query('sales_history'), hasLength(countBeforeSwitch));
        expect(
          (await db.query(
            'sales_history',
            where: 'id = ?',
            whereArgs: [saleIds['A']],
          )).single['cancelled'],
          0,
        );
        expect(
          await reservations.getReservedQuantities(includeSource: 'quick_sale'),
          {51: 2.0},
        );
        await reservations.clearQuickSaleReservation();
        expect(await reservations.getReservedQuantities(), {52: 1.0});

        await db.update(
          'products',
          {'stock': 10},
          where: 'id = ?',
          whereArgs: [51],
        );
        await db.update(
          'products',
          {'stock': 20},
          where: 'id = ?',
          whereArgs: [52],
        );
        await db.insert('products', {
          'id': 53,
          'billar_id': 'A',
          'name': 'CAJA',
          'parent_id': 51,
          'pieces_per_unit': 6,
        });
        await db.insert('products', {
          'id': 54,
          'billar_id': 'A',
          'name': 'PROMO',
          'is_promo': 1,
        });
        await db.insert('promo_items', {
          'parent_id': 54,
          'child_id': 51,
          'quantity': 2,
        });
        await db.insert('promo_items', {
          'parent_id': 54,
          'child_id': 52,
          'quantity': 3,
        });
        Future<int> saleWithItems(List<(int, double)> items) async {
          final id = await db!.insert('sales_history', {
            'billar_id': 'A',
            'total': 10,
            'paid': 10,
            'date': '2026-01-03T12:00:00',
            'type': 'Venta Rápida',
            'payment_method': 'Efectivo',
          });
          for (final (productId, quantity) in items) {
            await db!.insert('sale_details', {
              'sale_id': id,
              'product_id': productId,
              'product_name': 'PRODUCTO $productId',
              'quantity': quantity,
              'price_at_sale': 10,
            });
          }
          return id;
        }

        final cancelledSale = await saleWithItems([(51, 2), (53, 1), (54, 2)]);
        expect(
          await Future.wait([
            salesRepo.cancelSale(cancelledSale),
            salesRepo.cancelSale(cancelledSale),
          ]),
          [true, true],
        );
        expect(
          (await db.query(
            'products',
            where: 'id = ?',
            whereArgs: [51],
          )).single['stock'],
          22,
        );
        expect(
          (await db.query(
            'products',
            where: 'id = ?',
            whereArgs: [52],
          )).single['stock'],
          26,
        );
        expect(
          await db.query(
            'inventory_movements',
            where: 'reference_id = ? AND movement_type = ?',
            whereArgs: [cancelledSale, 'cancel'],
          ),
          hasLength(3),
        );
        await db.insert('promo_items', {
          'parent_id': 54,
          'child_id': 42,
          'quantity': 1,
        });
        final invalidSale = await saleWithItems([(54, 1)]);
        await expectLater(salesRepo.cancelSale(invalidSale), throwsStateError);
        expect(
          (await db.query(
            'products',
            where: 'id = ?',
            whereArgs: [51],
          )).single['stock'],
          22,
        );
        expect(
          (await db.query(
            'products',
            where: 'id = ?',
            whereArgs: [52],
          )).single['stock'],
          26,
        );
        expect(
          (await db.query(
            'sales_history',
            where: 'id = ?',
            whereArgs: [invalidSale],
          )).single['cancelled'],
          0,
        );
        expect(
          await db.query(
            'inventory_movements',
            where: 'reference_id = ? AND movement_type = ?',
            whereArgs: [invalidSale, 'cancel'],
          ),
          isEmpty,
        );
        final missingSale = await saleWithItems([(9999, 1)]);
        await expectLater(salesRepo.cancelSale(missingSale), throwsStateError);
        expect(
          (await db.query(
            'sales_history',
            where: 'id = ?',
            whereArgs: [missingSale],
          )).single['cancelled'],
          0,
        );
        final interruptedSale = await saleWithItems([(51, 1)]);

        final tableRepo = BilliardTableRepository();
        expect(await tableRepo.getAll(), isEmpty);
        expect(await tableRepo.getById(42), isNull);
        await expectLater(tableRepo.getAll(billarId: 'B'), throwsStateError);
        await expectLater(
          tableRepo.update(id: 42, name: 'Cambio'),
          throwsStateError,
        );
        await expectLater(
          tableRepo.updateWithoutSync(id: 42, name: 'Cambio'),
          throwsStateError,
        );
        await expectLater(tableRepo.free(42), throwsStateError);
        await expectLater(tableRepo.delete(42), throwsStateError);
        await expectLater(tableRepo.deleteAll(billarId: 'B'), throwsStateError);
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ?',
            whereArgs: [42],
          )).single['orders'],
          '[{"productId":42,"quantity":1}]',
        );
        await tableRepo.insert(
          id: 42,
          billarId: 'A',
          name: 'Mesa A',
          tableType: 'Billar',
        );
        await reservations.setTableReservation(42, [
          SaleItemEntity(productId: 51, productName: 'PRODUCTO 51', price: 10),
        ]);
        await salesRepo.freeTable(42);
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ? AND billar_id = ?',
            whereArgs: [42, 'B'],
          )).single['orders'],
          '[{"productId":42,"quantity":1}]',
        );
        expect(
          await db.query(
            'temp_reservations',
            where: 'source = ? AND source_id = ? AND product_id = ?',
            whereArgs: ['table', 42, 42],
          ),
          hasLength(1),
        );
        expect(
          await db.query(
            'temp_reservations',
            where: 'source = ? AND source_id = ? AND product_id = ?',
            whereArgs: ['table', 42, 51],
          ),
          isEmpty,
        );
        await db.delete(
          'billiard_tables',
          where: 'id = ? AND billar_id = ?',
          whereArgs: [42, 'A'],
        );

        await salesRepo.ensureTablesExist(2);
        expect((await tableRepo.getAll()).map((row) => row['id']), [43, 44]);
        await salesRepo.ensureTablesExist(3);
        expect((await tableRepo.getAll()).map((row) => row['id']), [43, 44]);
        expect(await tableRepo.getNextId(), 45);
        await tableRepo.insert(
          id: 45,
          billarId: 'A',
          name: 'Mesa nueva',
          tableType: 'Billar',
        );
        await tableRepo.updateWithoutSync(id: 45, name: 'Mesa editada');
        expect((await tableRepo.getById(45))!['name'], 'Mesa editada');
        await expectLater(
          tableRepo.insert(
            id: 45,
            billarId: 'A',
            name: 'Duplicada',
            tableType: 'Billar',
          ),
          throwsStateError,
        );
        expect((await tableRepo.getById(45))!['name'], 'Mesa editada');

        await reservations.setQuickSaleReservation([
          SaleItemEntity(productId: 51, productName: 'PRODUCTO 51', price: 10),
        ]);
        final locked = Completer<void>();
        final release = Completer<void>();
        final transaction = db.transaction((_) async {
          locked.complete();
          await release.future;
        });
        await locked.future;
        final pendingUpdate = tableRepo.updateWithoutSync(
          id: 45,
          name: 'No debe guardarse',
        );
        final rejected = expectLater(pendingUpdate, throwsStateError);
        final pendingReservation = reservations.setQuickSaleReservation([
          SaleItemEntity(
            productId: 51,
            productName: 'PRODUCTO 51',
            price: 10,
            quantity: 3,
          ),
        ]);
        final rejectedReservation = expectLater(
          pendingReservation,
          throwsStateError,
        );
        final rejectedCancellation = expectLater(
          salesRepo.cancelSale(interruptedSale),
          throwsStateError,
        );
        final rejectedOccupy = expectLater(
          salesRepo.occupyTable(45),
          throwsStateError,
        );
        final rejectedOrder = expectLater(
          salesRepo.saveTableOrder(
            tableId: 45,
            tableName: 'Mesa editada',
            items: [
              SaleItemEntity(
                productId: 51,
                productName: 'PRODUCTO 51',
                price: 10,
              ),
            ],
          ),
          throwsStateError,
        );
        await PreferencesService().setBillarId('B');
        release.complete();
        await transaction;
        await rejected;
        await rejectedReservation;
        await rejectedCancellation;
        await rejectedOccupy;
        await rejectedOrder;
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ?',
            whereArgs: [45],
          )).single['name'],
          'Mesa editada',
        );
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ? AND billar_id = ?',
            whereArgs: [45, 'A'],
          )).single['is_occupied'],
          0,
        );
        expect(
          (await db.query(
            'products',
            where: 'id = ?',
            whereArgs: [51],
          )).single['stock'],
          22,
        );
        expect(
          (await db.query(
            'sales_history',
            where: 'id = ?',
            whereArgs: [interruptedSale],
          )).single['cancelled'],
          0,
        );
        expect(
          (await db.query(
            'temp_reservations',
            where: 'source = ? AND product_id = ?',
            whereArgs: ['quick_sale', 51],
          )).single['quantity'],
          1.0,
        );

        expect(await reservations.getReservedQuantities(), {42: 2.0});
        expect(
          await salesRepo.getReservedQuantities(excludeSource: 'quick_sale'),
          {42: 1.0},
        );
        expect(await salesRepo.getSalesDetails(saleIds['A']!), isEmpty);
        expect(await salesRepo.cancelSale(saleIds['A']!), isFalse);
        expect(await salesRepo.cancelSale(saleIds['B']!), isTrue);
        expect(
          (await db.query(
            'sales_history',
            where: 'id = ?',
            whereArgs: [saleIds['B']],
          )).single['cancelled'],
          1,
        );
        expect(
          (await db.query(
            'sale_details',
            where: 'sale_id = ?',
            whereArgs: [saleIds['B']],
          )).single['cancelled'],
          1,
        );
      } finally {
        SyncService().dispose();
        await db?.close();
        messenger.setMockMethodCallHandler(path, null);
        messenger.setMockMethodCallHandler(connectivity, null);
        messenger.setMockMethodCallHandler(events, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
