import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/database/purchase_scope.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/services/sync_session.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/utils/uuid_v4.dart';
import '../../../../features/inventory/data/repositories/product_repository.dart';
import '../../../reports/data/repositories/reports_repository.dart';
import '../../domain/entities/provider_entity.dart';
import '../../domain/entities/purchase_entity.dart';

class PurchasesRepository {
  final _db = DatabaseHelper.instance;
  final _sync = SyncService();
  final _reports = ReportsRepository();
  static final _idRandom = Random.secure();

  Future<void> _enqueueProviderOperation(
    Transaction txn,
    SyncSession session,
    int providerId,
    String operation,
    Object? payload,
  ) async {
    _sync.requireProviderSession(session);
    await txn.insert('pending_provider_operations', {
      'actor_id': session.actorId,
      'billar_id': session.billarId,
      'provider_id': providerId,
      'operation': operation,
      'payload': jsonEncode(payload),
    });
  }

  Future<void> _enqueueProviderProducts(
    Transaction txn,
    SyncSession session,
    int providerId,
  ) async {
    final rows = await txn.query(
      'provider_products',
      columns: ['product_id'],
      where: 'provider_id = ?',
      whereArgs: [providerId],
      orderBy: 'product_id',
    );
    await _enqueueProviderOperation(
      txn,
      session,
      providerId,
      'products',
      rows.map((row) => row['product_id'] as int).toList(),
    );
  }

  Future<List<ProviderEntity>> getProviders() async {
    final db = await _db.database;
    // Descargar proveedores de la nube en background
    unawaited(_sync.pullProvidersFromCloud());
    final maps = await db.query(
      'providers',
      where: 'is_active = ?',
      whereArgs: [1],
      orderBy: 'name ASC',
    );
    return maps.map((m) => ProviderEntity.fromMap(m)).toList();
  }

  Future<int> saveProvider(ProviderEntity p, List<int> productIds) async {
    final session = _sync.captureProviderSession();
    final db = await _db.database;
    final id = p.id ?? (DateTime.now().millisecondsSinceEpoch * 1000000 +
        _idRandom.nextInt(1000000));
    await db.transaction((txn) async {
      _sync.requireProviderSession(session);
      if (p.id == null) {
        await txn.insert('providers', {'id': id, ...p.toMap()});
      } else {
        final updated = await txn.update(
          'providers', p.toMap(), where: 'id = ? AND is_active = 1', whereArgs: [id],
        );
        if (updated != 1) throw StateError('El proveedor ya no existe.');
      }
      await _enqueueProviderOperation(txn, session, id, 'save', p.toMap());
      await _replaceProviderProducts(txn, session, id, productIds);
      _sync.requireProviderSession(session);
    });
    _sync.schedulePendingSync();
    return id;
  }

  Future<void> deleteProvider(int id) async {
    final session = _sync.captureProviderSession();
    final db = await _db.database;
    await db.transaction((txn) async {
      _sync.requireProviderSession(session);
      final archived = await txn.update(
        'providers',
        {'is_active': 0},
        where: 'id = ? AND is_active = 1',
        whereArgs: [id],
      );
      if (archived != 1) throw StateError('El proveedor ya no está activo.');
      await _enqueueProviderOperation(
        txn, session, id, 'delete', {'request_id': newUuidV4()},
      );
      _sync.requireProviderSession(session);
    });
    _sync.schedulePendingSync();
  }

  Future<int> savePurchase({
    required PurchaseEntity purchase,
    SyncSession? expectedSession,
  }) async {
    final session = expectedSession ?? _sync.captureProviderSession();
    _sync.requireProviderSession(session);
    final billarId = session.billarId;
    final payment = purchase.paymentTerms;
    final items = List<PurchaseItemEntity>.unmodifiable(purchase.items);
    final total = items.fold<double>(0, (sum, item) => sum + item.subtotal);
    if (items.isEmpty ||
        !total.isFinite || total < 0 ||
        items.any((item) => item.productId <= 0 ||
            !item.quantity.isFinite || item.quantity <= 0 ||
            !item.costPerUnit.isFinite || item.costPerUnit < 0) ||
        (payment == null
            ? !CashSource.values.contains(purchase.cashSource)
            : purchase.cashSource != payment.legacyCashSource ||
                payment.isCredit && purchase.providerId == null)) {
      throw ArgumentError('Los datos de compra o sus condiciones de pago no son válidos.');
    }
    final recordedAt = DateTime.now().toUtc();
    final snapshot = payment?.snapshot(total: total, recordedAt: recordedAt);
    final db = await _db.database;
    _sync.requireProviderSession(session);
    final createdBy = PreferencesService().userName;

    final purchaseId = await db.transaction((txn) async {
      _sync.requireProviderSession(session);
      if (purchase.providerId != null) {
        final provider = await txn.query(
          'providers', columns: ['id'],
          where: 'id = ? AND is_active = 1', whereArgs: [purchase.providerId],
        );
        if (provider.length != 1) throw StateError('El proveedor ya no está activo.');
      }
      final id = await txn.insert('purchases', {
        'billar_id': billarId,
        'provider_id': purchase.providerId,
        'total': total,
        'date': recordedAt.toIso8601String(),
        'reference': purchase.reference,
        'created_by': createdBy,
        'cash_source': purchase.cashSource,
        if (snapshot != null) ...snapshot,
        'synced': 0,
      });
      for (final item in items) {
        await txn.insert('purchase_details', {
          'purchase_id': id,
          'product_id': item.productId,
          'quantity': item.quantity,
          'cost_per_unit': item.costPerUnit,
          'created_by': createdBy,
        });

        // Ajustar stock considerando cajas/paquetes.
        final prodRows = await txn.query('products', where: 'id = ?', whereArgs: [item.productId]);
        if (prodRows.isEmpty) throw StateError('Un producto ya no está disponible.');
        if (prodRows.isNotEmpty) {
          final prod = prodRows.first;
          final parentId = prod['parent_id'] as int?;
          final piecesPerUnit = (prod['pieces_per_unit'] as int?) ?? 1;
          final targetId = parentId ?? item.productId;
          final pieces = parentId != null ? item.quantity * piecesPerUnit : item.quantity;
          final costPerPiece = parentId != null ? item.costPerUnit / piecesPerUnit : item.costPerUnit;

          await txn.rawUpdate('UPDATE products SET stock = stock + ?, synced = 0 WHERE id = ?', [
            pieces,
            targetId,
          ]);

          await txn.rawUpdate('UPDATE products SET cost = ?, synced = 0 WHERE id = ?', [
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
            await txn.rawUpdate('UPDATE products SET cost = ?, synced = 0 WHERE id = ?', [
              costPerPiece * childPieces,
              child['id'],
            ]);
          }

          await txn.insert('inventory_movements', {
            'billar_id': billarId,
            'product_id': targetId,
            'movement_type': 'purchase',
            'quantity': pieces,
            'unit_cost': costPerPiece,
            'unit_price': 0,
            'reference_id': id,
            'reference_type': 'purchases',
            'notes': 'Compra ${purchase.reference}',
            'created_at': recordedAt.toIso8601String(),
            'synced': 0,
          });
        }
      }
      _sync.requireProviderSession(session);
      return id;
    });

    // Sincronizar stock de productos a Supabase (fire-and-forget: sin
    // conexión no debe demorar/trabar el guardado de la compra, que ya
    // quedó registrada localmente arriba).
    for (final item in items) {
      unawaited(_syncProductStockToCloud(item.productId, expectedSession: session));
    }

    // Disparar sync de la compra completa
    _sync.schedulePendingSync();

    return purchaseId;
  }

  Future<Map<String, dynamic>> getPurchaseHeader(
    int id, {
    required SyncSession session,
  }) async {
    _sync.requireProviderSession(session);
    final db = await _db.database;
    _sync.requireProviderSession(session);
    final rows = await db.query(
      'purchases',
      where: 'id = ? AND billar_id = ?',
      whereArgs: [id, session.billarId],
    );
    _sync.requireProviderSession(session);
    if (rows.length != 1) throw StateError('La compra guardada ya no está disponible.');
    return rows.single;
  }

  /// Anula una compra: descuenta el stock que la compra había sumado,
  /// marca la compra y sus detalles como anulados (lógico, no físico) y
  /// sincroniza la anulación a Supabase. No borra registros.
  Future<bool> cancelPurchase(int purchaseId, {String notes = ''}) async {
    final db = await _db.database;
    final purchases = await db.query(
      'purchases',
      where: 'id = ? AND ${purchaseBusinessScope()}',
      whereArgs: [purchaseId, PreferencesService().billarId],
    );
    if (purchases.isEmpty) return false;
    final purchase = purchases.first;
    if ((purchase['cancelled'] as int? ?? 0) == 1) return true; // ya anulada

    final details = await db.query('purchase_details', where: 'purchase_id = ?', whereArgs: [purchaseId]);
    final reference = purchase['reference']?.toString() ?? '';

    // Descontar el stock que cada producto recibió con esta compra,
    // replicando la lógica de cajas/paquetes de savePurchase (inversa).
    for (final d in details) {
      final productId = d['product_id'] as int?;
      final qty = (d['quantity'] as num?)?.toDouble() ?? 0;
      final costPerUnit = (d['cost_per_unit'] as num?)?.toDouble() ?? 0;
      if (productId == null || qty <= 0) continue;

      final prodRows = await db.query('products', where: 'id = ?', whereArgs: [productId]);
      if (prodRows.isEmpty) continue;
      final prod = prodRows.first;
      final parentId = prod['parent_id'] as int?;
      final piecesPerUnit = (prod['pieces_per_unit'] as int?) ?? 1;
      final targetId = parentId ?? productId;
      final pieces = parentId != null ? qty * piecesPerUnit : qty;

      // Solo descontar si hay stock suficiente (evita stocks negativos si
      // ya se vendió lo comprado; en ese caso el stock puede quedar en 0).
      final targetRows = await db.query('products', columns: ['stock'], where: 'id = ?', whereArgs: [targetId]);
      final currentStock = (targetRows.first['stock'] as num?)?.toDouble() ?? 0;
      final discount = pieces > currentStock ? currentStock : pieces;

      if (discount > 0) {
        await db.rawUpdate('UPDATE products SET stock = stock - ?, synced = 0 WHERE id = ?', [discount, targetId]);
        await _reports.recordInventoryMovement(
          productId: targetId,
          movementType: 'cancel',
          quantity: discount,
          unitCost: parentId != null ? costPerUnit / piecesPerUnit : costPerUnit,
          referenceId: purchaseId,
          referenceType: 'purchases',
          notes: notes.isEmpty ? 'Anulación de compra $reference' : notes,
        );
      }
      unawaited(_syncProductStockToCloud(productId));
    }

    // Marcar compra y detalles como anulados (local).
    await db.update('purchases', {'cancelled': 1, 'synced': 0}, where: 'id = ?', whereArgs: [purchaseId]);
    await db.update('purchase_details', {'cancelled': 1}, where: 'purchase_id = ?', whereArgs: [purchaseId]);

    // La cola sube también el flag cancelled y reintenta si falla la red.
    _sync.schedulePendingSync();

    return true;
  }

  Future<void> _syncProductStockToCloud(int productId, {SyncSession? expectedSession}) async {
    try {
      final session = expectedSession ?? _sync.captureProviderSession();
      _sync.requireProviderSession(session);
      final db = await _db.database;
      _sync.requireProviderSession(session);
      final rows = await db.query('products', columns: ['parent_id'], where: 'id = ?', whereArgs: [productId]);
      _sync.requireProviderSession(session);
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
    // Descargar compras de la nube en background (igual que se hace con
    // proveedores en `getProviders`). Sin esto, el historial solo muestra la
    // BD local y no se ven las compras hechas desde el otro dispositivo.
    unawaited(_sync.pullPurchasesFromCloud());
    return db.rawQuery('''
      SELECT p.*, pr.name as provider_name
      FROM purchases p
      LEFT JOIN providers pr ON p.provider_id = pr.id
      WHERE p.cancelled = 0 AND ${purchaseBusinessScope('p')}
      ORDER BY p.date DESC
      LIMIT 100
    ''', [PreferencesService().billarId]);
  }

  Future<List<Map<String, dynamic>>> getPurchaseDetails(int purchaseId) async {
    final db = await _db.database;
    return db.rawQuery('''
      SELECT d.*, pd.name as product_name
      FROM purchase_details d
      LEFT JOIN products pd ON d.product_id = pd.id
      WHERE d.purchase_id = ? AND EXISTS (
        SELECT 1 FROM purchases p
        WHERE p.id = d.purchase_id AND ${purchaseBusinessScope('p')}
      )
      ORDER BY d.id ASC
    ''', [purchaseId, PreferencesService().billarId]);
  }

  // ── Relación proveedores ↔ productos ──

  Future<void> _replaceProviderProducts(
    Transaction txn,
    SyncSession session,
    int providerId,
    List<int> productIds,
  ) async {
    for (final productId in productIds) {
      final products = await txn.query(
        'products',
        columns: ['id'],
        where: 'id = ? AND billar_id = ?',
        whereArgs: [productId, session.billarId],
        limit: 1,
      );
      if (products.isEmpty) {
        throw StateError('Un producto no pertenece al billar actual.');
      }
    }
    await txn.delete('provider_products', where: 'provider_id = ?', whereArgs: [providerId]);
    for (final productId in productIds) {
      await txn.insert('provider_products', {
        'provider_id': providerId,
        'product_id': productId,
      });
    }
    await _enqueueProviderProducts(txn, session, providerId);
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
    final rows = await db.rawQuery('''
      SELECT pp.provider_id FROM provider_products pp
      JOIN providers p ON p.id = pp.provider_id
      WHERE pp.product_id = ? AND p.is_active = 1
    ''', [productId]);
    return rows.map((r) => r['provider_id'] as int).toList();
  }

  Future<void> setProductProviders(int productId, List<int> providerIds) async {
    final session = _sync.captureProviderSession();
    final db = await _db.database;
    await db.transaction((txn) async {
      _sync.requireProviderSession(session);
      final product = await txn.query(
        'products',
        columns: ['id'],
        where: 'id = ? AND billar_id = ?',
        whereArgs: [productId, session.billarId],
        limit: 1,
      );
      if (product.isEmpty) throw StateError('El producto no pertenece al billar actual.');
      for (final providerId in providerIds) {
        final provider = await txn.query(
          'providers',
          columns: ['id'],
          where: 'id = ? AND is_active = 1',
          whereArgs: [providerId],
          limit: 1,
        );
        if (provider.isEmpty) throw StateError('El proveedor ya no existe.');
      }
      final previous = await txn.rawQuery('''
        SELECT pp.provider_id FROM provider_products pp
        JOIN providers p ON p.id = pp.provider_id
        WHERE pp.product_id = ? AND p.is_active = 1
      ''', [productId]);
      final affectedIds = {
        ...previous.map((row) => row['provider_id'] as int),
        ...providerIds,
      };
      await txn.delete(
        'provider_products',
        where: 'product_id = ? AND provider_id IN (SELECT id FROM providers WHERE is_active = 1)',
        whereArgs: [productId],
      );
      for (final providerId in providerIds) {
        await txn.insert('provider_products', {
          'provider_id': providerId,
          'product_id': productId,
        });
      }
      for (final providerId in affectedIds) {
        await _enqueueProviderProducts(txn, session, providerId);
      }
      _sync.requireProviderSession(session);
    });
    _sync.schedulePendingSync();
  }
}
