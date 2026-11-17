import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../../core/services/sync_session.dart';
import '../domain/entities/staff_sale_product.dart';

class StaffSaleCache {
  const StaffSaleCache(this.database, this.requireSession);

  final Database database;
  final void Function(SyncSession) requireSession;

  Future<void> replaceCatalog(
    SyncSession session,
    List<StaffSaleProduct> products,
  ) async {
    final ids = <int>{};
    if (products.any(
      (product) => product.billarId != session.billarId || !ids.add(product.id),
    )) {
      throw StateError(
        'El catálogo no corresponde al billar o está duplicado.',
      );
    }
    await database.transaction((txn) async {
      requireSession(session);
      await txn.update(
        'staff_sale_catalog',
        {'is_active': 0},
        where: 'actor_id = ? AND billar_id = ?',
        whereArgs: [session.actorId, session.billarId],
      );
      for (final product in products) {
        final rows = await txn.query(
          'staff_sale_catalog',
          where: 'actor_id = ? AND billar_id = ? AND product_id = ?',
          whereArgs: [session.actorId, session.billarId, product.id],
        );
        final current = rows.isEmpty ? null : rows.single;
        if (current != null &&
            current['stock_revision'] == product.stockRevision &&
            current['stock'] != product.inventoryStock) {
          throw StateError(
            'La revisión de inventario tiene valores diferentes.',
          );
        }
        final preserveStock =
            current != null &&
            (current['stock_revision'] as int) > product.stockRevision;
        await txn.insert('staff_sale_catalog', {
          'actor_id': session.actorId,
          'billar_id': session.billarId,
          'product_id': product.id,
          'product_json': jsonEncode(product.toMap()),
          'stock': preserveStock ? current['stock'] : product.inventoryStock,
          'stock_revision':
              preserveStock ? current['stock_revision'] : product.stockRevision,
          'is_active': product.isActive ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      requireSession(session);
    });
  }

  Future<List<StaffSaleProduct>> catalog(SyncSession session) async {
    requireSession(session);
    final rows = await database.query(
      'staff_sale_catalog',
      where: 'actor_id = ? AND billar_id = ?',
      whereArgs: [session.actorId, session.billarId],
      orderBy: 'product_id',
    );
    requireSession(session);
    return rows.map((row) {
      final payload = jsonDecode(row['product_json'] as String);
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('El catálogo local no es válido.');
      }
      return StaffSaleProduct.fromMap({
        ...payload,
        'inventory_stock': row['stock'],
        'stock_revision': row['stock_revision'],
        'is_active': row['is_active'] == 1,
      }, billarId: session.billarId);
    }).toList();
  }

  Future<List<Map<String, Object?>>> reservations(
    DatabaseExecutor db,
    SyncSession session,
  ) async {
    requireSession(session);
    final rows = await db.query(
      'staff_sale_cart',
      columns: ['id', 'product_id', 'quantity'],
      where: 'actor_id = ? AND billar_id = ?',
      whereArgs: [session.actorId, session.billarId],
      orderBy: 'id',
    );
    requireSession(session);
    return rows;
  }

  Future<Map<int, int>> cart(SyncSession session) async => {
    for (final row in await reservations(database, session))
      row['product_id'] as int: row['quantity'] as int,
  };

  Future<void> saveCart(SyncSession session, Map<int, int> cart) async {
    if (cart.entries.any((entry) => entry.key <= 0 || entry.value <= 0)) {
      throw ArgumentError('Las cantidades del carrito no son válidas.');
    }
    await database.transaction((txn) async {
      requireSession(session);
      final pending = await txn.query(
        'pending_staff_sales',
        columns: ['request_id'],
        where: 'actor_id = ? AND billar_id = ?',
        whereArgs: [session.actorId, session.billarId],
        limit: 1,
      );
      if (pending.isNotEmpty) {
        throw StateError(
          'Recupera la venta pendiente antes de editar el carrito.',
        );
      }
      for (final id in cart.keys) {
        final product = await txn.query(
          'staff_sale_catalog',
          columns: ['product_id'],
          where: 'actor_id = ? AND billar_id = ? AND product_id = ?',
          whereArgs: [session.actorId, session.billarId, id],
          limit: 1,
        );
        if (product.isEmpty) {
          throw StateError(
            'El producto no pertenece al catálogo de la cuenta.',
          );
        }
      }
      await clearCart(txn, session);
      for (final entry in cart.entries) {
        await txn.insert('staff_sale_cart', {
          'actor_id': session.actorId,
          'billar_id': session.billarId,
          'product_id': entry.key,
          'quantity': entry.value,
        });
      }
      requireSession(session);
    });
  }

  Future<void> clearCart(DatabaseExecutor db, SyncSession session) async {
    requireSession(session);
    await db.delete(
      'staff_sale_cart',
      where: 'actor_id = ? AND billar_id = ?',
      whereArgs: [session.actorId, session.billarId],
    );
    requireSession(session);
  }

  Future<void> reconcileStock(
    DatabaseExecutor db,
    SyncSession session, {
    required int productId,
    required double stock,
    required int revision,
  }) async {
    requireSession(session);
    final rows = await db.query(
      'staff_sale_catalog',
      where: 'actor_id = ? AND billar_id = ? AND product_id = ?',
      whereArgs: [session.actorId, session.billarId, productId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Falta el producto del comprobante en la caché local.');
    }
    final current = rows.single;
    if (current['stock_revision'] == revision && current['stock'] != stock) {
      throw StateError('La revisión de inventario tiene valores diferentes.');
    }
    if ((current['stock_revision'] as int) < revision) {
      await db.update(
        'staff_sale_catalog',
        {'stock': stock, 'stock_revision': revision},
        where: 'actor_id = ? AND billar_id = ? AND product_id = ?',
        whereArgs: [session.actorId, session.billarId, productId],
      );
    }
    requireSession(session);
  }
}
