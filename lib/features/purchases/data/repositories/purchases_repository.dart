import 'package:flutter/foundation.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../features/inventory/data/repositories/product_repository.dart';
import '../../domain/entities/provider_entity.dart';
import '../../domain/entities/purchase_entity.dart';

class PurchasesRepository {
  final _db = DatabaseHelper.instance;
  final _sync = SyncService();

  Future<List<ProviderEntity>> getProviders() async {
    final db = await _db.database;
    final maps = await db.query('providers', orderBy: 'name ASC');
    return maps.map((m) => ProviderEntity.fromMap(m)).toList();
  }

  Future<int> insertProvider(ProviderEntity p) async {
    final db = await _db.database;
    final id = await db.insert('providers', p.toMap());
    _sync.pushProviderToCloud(p.toMap(), id);
    return id;
  }

  Future<void> deleteProvider(int id) async {
    final db = await _db.database;
    await db.delete('providers', where: 'id = ?', whereArgs: [id]);
    _sync.deleteProviderFromCloud(id);
  }

  Future<int> savePurchase({required PurchaseEntity purchase}) async {
    final db = await _db.database;

    final purchaseId = await db.transaction((txn) async {
      final id = await txn.insert('purchases', {
        'provider_id': purchase.providerId,
        'total': purchase.total,
        'date': DateTime.now().toIso8601String(),
        'reference': purchase.reference,
        'synced': 0,
      });
      for (final item in purchase.items) {
        await txn.insert('purchase_details', {
          'purchase_id': id,
          'product_id': item.productId,
          'quantity': item.quantity,
          'cost_per_unit': item.costPerUnit,
        });
        await txn.rawUpdate('UPDATE products SET stock = stock + ?, cost = ? WHERE id = ?', [
          item.quantity,
          item.costPerUnit,
          item.productId,
        ]);
      }
      return id;
    });

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
      await ProductRepository().syncProductById(productId);
      debugPrint('[Sync] Stock de producto $productId sincronizado tras compra');
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
}
