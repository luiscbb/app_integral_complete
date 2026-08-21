import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../features/inventory/data/repositories/product_repository.dart';
import '../../../reports/data/repositories/reports_repository.dart';
import '../../domain/entities/provider_entity.dart';
import '../../domain/entities/purchase_entity.dart';

class PurchasesRepository {
  final _db = DatabaseHelper.instance;
  final _sync = SyncService();
  final _reports = ReportsRepository();

  Future<List<ProviderEntity>> getProviders() async {
    final db = await _db.database;
    // Descargar proveedores de la nube en background
    unawaited(_sync.pullProvidersFromCloud());
    final maps = await db.query('providers', orderBy: 'name ASC');
    return maps.map((m) => ProviderEntity.fromMap(m)).toList();
  }

  Future<int> insertProvider(ProviderEntity p) async {
    final db = await _db.database;
    final id = await db.insert('providers', p.toMap());
    unawaited(_sync.pushProviderToCloud({...p.toMap(), 'id': id}, id));
    return id;
  }

  Future<void> updateProvider(ProviderEntity p) async {
    final db = await _db.database;
    if (p.id == null) return;
    await db.update('providers', p.toMap(), where: 'id = ?', whereArgs: [p.id]);
    unawaited(_sync.pushProviderToCloud({...p.toMap(), 'id': p.id}, p.id!));
  }

  Future<void> deleteProvider(int id) async {
    final db = await _db.database;
    await db.delete('providers', where: 'id = ?', whereArgs: [id]);
    await db.delete('provider_products', where: 'provider_id = ?', whereArgs: [id]);
    unawaited(_sync.deleteProviderFromCloud(id));
  }

  Future<int> savePurchase({required PurchaseEntity purchase}) async {
    final db = await _db.database;
    final createdBy = PreferencesService().userName;

    // Registrar movimientos de inventario (kardex) FUERA de la transacción.
    // `recordInventoryMovement` usa `_db.database` (no el objeto `txn`), y
    // escribir sobre la misma conexión con una transacción activa hace que la
    // operación falle y revierta toda la compra (historial/PDF no se generan).
    // Se acumulan los datos durante el bucle y se insertan al final, replicando
    // el patrón que ya usa `saveSale` en ventas.
    final movements = <({int productId, double pieces, double costPerPiece})>[];

    final purchaseId = await db.transaction((txn) async {
      final id = await txn.insert('purchases', {
        'provider_id': purchase.providerId,
        'total': purchase.total,
        'date': DateTime.now().toIso8601String(),
        'reference': purchase.reference,
        'created_by': createdBy,
        'synced': 0,
      });
      for (final item in purchase.items) {
        await txn.insert('purchase_details', {
          'purchase_id': id,
          'product_id': item.productId,
          'quantity': item.quantity,
          'cost_per_unit': item.costPerUnit,
          'created_by': createdBy,
        });

        // Ajustar stock considerando cajas/paquetes.
        final prodRows = await txn.query('products', where: 'id = ?', whereArgs: [item.productId]);
        if (prodRows.isNotEmpty) {
          final prod = prodRows.first;
          final parentId = prod['parent_id'] as int?;
          final piecesPerUnit = (prod['pieces_per_unit'] as int?) ?? 1;
          final targetId = parentId ?? item.productId;
          final pieces = parentId != null ? item.quantity * piecesPerUnit : item.quantity;
          final costPerPiece = parentId != null ? item.costPerUnit / piecesPerUnit : item.costPerUnit;

          await txn.rawUpdate('UPDATE products SET stock = stock + ? WHERE id = ?', [
            pieces,
            targetId,
          ]);

          await txn.rawUpdate('UPDATE products SET cost = ? WHERE id = ?', [
            costPerPiece,
            targetId,
          ]);

          final childRows = await txn.query(
            'products',
            where: 'parent_id = ?',
            whereArgs: [targetId],
          );
          if (childRows.isNotEmpty) {
            final child = childRows.first;
            final childPieces = (child['pieces_per_unit'] as int?) ?? 1;
            await txn.rawUpdate('UPDATE products SET cost = ? WHERE id = ?', [
              costPerPiece * childPieces,
              child['id'],
            ]);
          }

          // Acumular el movimiento para registrarlo tras la transacción.
          movements.add((
            productId: targetId,
            pieces: pieces,
            costPerPiece: costPerPiece,
          ));
        }
      }
      return id;
    });

    // Registrar movimientos de inventario (kardex) fuera de la transacción.
    for (final m in movements) {
      await _reports.recordInventoryMovement(
        productId: m.productId,
        movementType: 'purchase',
        quantity: m.pieces,
        unitCost: m.costPerPiece,
        referenceId: purchaseId,
        referenceType: 'purchases',
        notes: 'Compra ${purchase.reference}',
      );
    }

    // Sincronizar stock de productos a Supabase
    for (final item in purchase.items) {
      await _syncProductStockToCloud(item.productId);
    }

    // Disparar sync de la compra completa
    _sync.schedulePendingSync();

    return purchaseId;
  }

  Future<void> _syncProductStockToCloud(int productId) async {
    try {
      final db = await _db.database;
      final rows = await db.query('products', columns: ['parent_id'], where: 'id = ?', whereArgs: [productId]);
      final parentId = rows.isNotEmpty ? rows.first['parent_id'] as int? : null;
      final targetId = parentId ?? productId;
      await ProductRepository().syncProductById(targetId);
      debugPrint('[Sync] Stock de producto $targetId sincronizado tras compra');
    } catch (e) {
      debugPrint('[Sync] ERROR sincronizando stock de $productId: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getHistory() async {
    final db = await _db.database;
    return db.rawQuery('''
      SELECT p.*, pr.name as provider_name
      FROM purchases p
      LEFT JOIN providers pr ON p.provider_id = pr.id
      ORDER BY p.date DESC
      LIMIT 100
    ''');
  }

  Future<List<Map<String, dynamic>>> getPurchaseDetails(int purchaseId) async {
    final db = await _db.database;
    return db.rawQuery('''
      SELECT d.*, pd.name as product_name
      FROM purchase_details d
      LEFT JOIN products pd ON d.product_id = pd.id
      WHERE d.purchase_id = ?
      ORDER BY d.id ASC
    ''', [purchaseId]);
  }

  // ── Relación proveedores ↔ productos ──

  Future<void> setProviderProducts(int providerId, List<int> productIds) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.delete('provider_products', where: 'provider_id = ?', whereArgs: [providerId]);
      for (final productId in productIds) {
        await txn.insert('provider_products', {
          'provider_id': providerId,
          'product_id': productId,
        });
      }
    });
    unawaited(_sync.pushProviderProductsToCloud(providerId));
  }

  Future<List<int>> getProviderProductIds(int providerId) async {
    final db = await _db.database;
    final rows = await db.query(
      'provider_products',
      columns: ['product_id'],
      where: 'provider_id = ?',
      whereArgs: [providerId],
    );
    return rows.map((r) => r['product_id'] as int).toList();
  }

  Future<List<int>> getProductProviderIds(int productId) async {
    final db = await _db.database;
    final rows = await db.query(
      'provider_products',
      columns: ['provider_id'],
      where: 'product_id = ?',
      whereArgs: [productId],
    );
    return rows.map((r) => r['provider_id'] as int).toList();
  }

  Future<void> setProductProviders(int productId, List<int> providerIds) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.delete('provider_products', where: 'product_id = ?', whereArgs: [productId]);
      for (final providerId in providerIds) {
        await txn.insert('provider_products', {
          'provider_id': providerId,
          'product_id': productId,
        });
      }
    });
    for (final providerId in providerIds) {
      unawaited(_sync.pushProviderProductsToCloud(providerId));
    }
  }
}
