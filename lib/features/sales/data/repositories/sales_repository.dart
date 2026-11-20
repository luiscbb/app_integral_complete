import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/services/table_sync_conflicts.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../inventory/data/repositories/product_repository.dart';
import '../../../inventory/domain/entities/product_entity.dart';
import '../../domain/entities/sale_item_entity.dart';
import 'stock_reservation_service.dart';

enum SaleOrigin {
  quickSale('quick_sale'),
  billiardTables('billiard_tables'),
  dineIn('dine_in'),
  personalAccount('personal_account');

  const SaleOrigin(this.moduleId);
  final String moduleId;
}

class SaleScopeException extends StateError {
  SaleScopeException(super.message);
}

class SalesRepository {
  SalesRepository({String? Function()? currentActorId})
    : _currentActorId =
          currentActorId ??
          (() => Supabase.instance.client.auth.currentUser?.id),
      _reservations = StockReservationService(currentActorId: currentActorId);

  final String? Function() _currentActorId;
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  final _sync = SyncService();
  final StockReservationService _reservations;
  final _productRepo = ProductRepository();

  String _captureActorId() {
    final actorId = _currentActorId();
    if (actorId == null || actorId.isEmpty) {
      throw StateError('Se requiere una sesión para operar con mesas.');
    }
    return actorId;
  }

  void _requireTableScope(String actorId, String billarId) {
    if (_currentActorId() != actorId || _prefs.billarId != billarId) {
      throw StateError(
        'La cuenta o el billar cambió durante la operación de mesas.',
      );
    }
  }

  Future<int> saveSale({
    required List<SaleItemEntity> items,
    required double total,
    required double paid,
    required String paymentMethod,
    required String saleType,
    required SaleOrigin origin,
    int? tableId,
    String? customerKey,
  }) async {
    if ((origin == SaleOrigin.billiardTables || origin == SaleOrigin.dineIn) &&
        (tableId == null || tableId <= 0)) {
      throw SaleScopeException('Se requiere identificar la mesa para cobrar.');
    }
    if ((origin == SaleOrigin.billiardTables || origin == SaleOrigin.dineIn) &&
        (!total.isFinite ||
            !paid.isFinite ||
            total < 0 ||
            paid < 0 ||
            paid + 0.000000001 < total)) {
      throw SaleScopeException('El monto recibido debe cubrir el total.');
    }
    final actorId = _currentActorId();
    if (actorId == null || actorId.isEmpty) {
      throw SaleScopeException(
        'Se requiere una sesión para registrar la venta.',
      );
    }
    final billarId = _prefs.billarId;
    final db = await _db.database;
    final now = DateTime.now().toIso8601String();

    final saleId = await db.transaction((txn) async {
      if (_prefs.billarId != billarId || _currentActorId() != actorId) {
        throw SaleScopeException(
          'La cuenta o el billar cambió durante el registro de la venta.',
        );
      }
      if (origin == SaleOrigin.quickSale) {
        final pending = await txn.query(
          'pending_staff_sales',
          columns: ['request_id'],
          where: 'actor_id = ? AND billar_id = ?',
          whereArgs: [actorId, billarId],
          limit: 1,
        );
        if (pending.isNotEmpty) {
          throw SaleScopeException(
            'Hay una venta pendiente que debe recuperarse antes de cobrar.',
          );
        }
      }
      if (tableId != null &&
          await TableSyncConflicts.contains(txn, actorId, billarId, tableId)) {
        throw SaleScopeException(
          'Esta mesa tiene cambios en conflicto. No se puede cobrar hasta revisarlos.',
        );
      }
      final id = await txn.insert('sales_history', {
        'billar_id': billarId,
        'total': total,
        'paid': paid,
        'date': now,
        'type': saleType,
        'source_module': origin.moduleId,
        'payment_method': paymentMethod,
        if (customerKey != null) 'customer_key': customerKey,
        'synced': 0,
      });
      for (final item in items) {
        // Informe de UTILIDAD (Etapa 4): guardar el costo del producto al
        // momento de vender (costo histórico real). El tiempo de mesa no es
        // producto, no tiene costo.
        double costAtSale = 0;
        if (item.productId != null &&
            !item.productName.startsWith('Tiempo de juego')) {
          final prodRows = await txn.query(
            'products',
            columns: ['cost'],
            where: 'id = ? AND billar_id = ?',
            whereArgs: [item.productId, billarId],
          );
          if (prodRows.isEmpty) {
            throw SaleScopeException(
              'El producto no pertenece al billar actual o no existe.',
            );
          }
          costAtSale = (prodRows.first['cost'] as num?)?.toDouble() ?? 0;
        }
        await txn.insert('sale_details', {
          'sale_id': id,
          'product_id': item.productId,
          'product_name': item.productName,
          'quantity': item.quantity,
          'price_at_sale': item.price,
          'cost_at_sale': costAtSale,
        });
        if (item.productId != null &&
            !item.productName.startsWith('Tiempo de juego')) {
          await txn.insert('inventory_movements', {
            'billar_id': billarId,
            'product_id': item.productId,
            'movement_type': 'sale',
            'quantity': -item.quantity,
            'unit_price': item.price,
            'reference_id': id,
            'reference_type': 'sales_history',
            'notes': 'Venta $saleType',
            'synced': 0,
          });
        }
      }
      if (saleType == 'Venta Rápida') {
        await txn.delete(
          'temp_reservations',
          where:
              'source = ? AND product_id IN '
              '(SELECT id FROM products WHERE billar_id = ?)',
          whereArgs: ['quick_sale', billarId],
        );
      }
      if (_prefs.billarId != billarId || _currentActorId() != actorId) {
        throw SaleScopeException(
          'La cuenta o el billar cambió durante el registro de la venta.',
        );
      }
      return id;
    });

    // Intentar sync inmediata (fire-and-forget); si falla, SyncService reintentará luego.
    _sync.schedulePendingSync();

    return saleId;
  }

  /// Anula una venta ya registrada (Etapa 3, requiere PIN en la UI).
  /// Anulación LÓGICA (no borra filas) para que el pull de la nube no la
  /// re-inserte en otro dispositivo. Además:
  ///  - Devuelve el stock de los productos vendidos (promos/cajas incluidos).
  ///  - Registra el movimiento inverso en el kardex.
  ///  - La venta queda excluida de informes/caja (cancelled = 1).
  Future<bool> cancelSale(int saleId, {String notes = ''}) async {
    final actorId = _currentActorId();
    if (actorId == null || actorId.isEmpty) {
      throw SaleScopeException('Se requiere una sesión para anular la venta.');
    }
    final billarId = _prefs.billarId;
    final db = await _db.database;
    final changedProducts = <int>{};
    final result = await db.transaction((txn) async {
      void requireBillar() {
        if (_prefs.billarId != billarId || _currentActorId() != actorId) {
          throw SaleScopeException(
            'La cuenta o el billar cambió durante la anulación.',
          );
        }
      }

      requireBillar();
      final sales = await txn.query(
        'sales_history',
        where: 'id = ? AND billar_id = ?',
        whereArgs: [saleId, billarId],
      );
      requireBillar();
      if (sales.isEmpty) return false;
      final sale = sales.first;
      if ((sale['cancelled'] as int? ?? 0) == 1) return true;

      final details = await txn.query(
        'sale_details',
        where: 'sale_id = ?',
        whereArgs: [saleId],
      );
      final saleType = sale['type']?.toString() ?? '';
      for (final detail in details) {
        final productId = detail['product_id'] as int?;
        final name = detail['product_name']?.toString() ?? '';
        final qty = (detail['quantity'] as num?)?.toDouble() ?? 0;
        if (productId == null ||
            qty <= 0 ||
            name.startsWith('Tiempo de juego')) {
          continue;
        }
        final products = await txn.query(
          'products',
          where: 'id = ? AND billar_id = ?',
          whereArgs: [productId, billarId],
        );
        if (products.isEmpty) {
          throw StateError(
            'El producto de la venta no pertenece al billar o no existe.',
          );
        }
        final product = ProductEntity.fromMap(products.first);
        final adjustments = <(int, double)>[];
        if (product.parentId != null) {
          adjustments.add((product.parentId!, qty * product.piecesPerUnit));
        } else if (product.isPromo == 1) {
          final components = await txn.query(
            'promo_items',
            where: 'parent_id = ?',
            whereArgs: [productId],
          );
          for (final component in components) {
            adjustments.add((
              component['child_id'] as int,
              qty * (component['quantity'] as num).toDouble(),
            ));
          }
        } else {
          adjustments.add((productId, qty));
        }
        for (final (stockId, amount) in adjustments) {
          final count = await txn.rawUpdate(
            'UPDATE products SET stock = stock + ?, synced = 0 '
            'WHERE id = ? AND billar_id = ?',
            [amount, stockId, billarId],
          );
          if (count != 1) {
            throw StateError(
              'Un componente de la venta no pertenece al billar o no existe.',
            );
          }
          changedProducts.add(stockId);
        }
        await txn.insert('inventory_movements', {
          'billar_id': billarId,
          'product_id': productId,
          'movement_type': 'cancel',
          'quantity': qty,
          'unit_price': (detail['price_at_sale'] as num?)?.toDouble() ?? 0,
          'reference_id': saleId,
          'reference_type': 'sales_history',
          'notes': notes.isEmpty ? 'Anulación de venta $saleType' : notes,
          'synced': 0,
        });
      }
      await txn.update(
        'sales_history',
        {'cancelled': 1, 'synced': 0},
        where: 'id = ? AND billar_id = ?',
        whereArgs: [saleId, billarId],
      );
      await txn.update(
        'sale_details',
        {'cancelled': 1},
        where: 'sale_id = ?',
        whereArgs: [saleId],
      );
      requireBillar();
      return true;
    });

    // La cola procesa tanto anulaciones nuevas como pendientes y reintenta si
    // falla la red, incluso cuando la venta ya tiene cloud_id.
    if (result) {
      _sync.schedulePendingSync();
      for (final productId in changedProducts) {
        await _productRepo.syncProductById(productId);
      }
    }

    return result;
  }

  Future<List<Map<String, dynamic>>> getSalesByDate(DateTime date) async {
    final db = await _db.database;
    // Descargar ventas de la nube en background (mismo patrón que el
    // historial de compras). Sin esto, un dispositivo nuevo/vacío no ve
    // las ventas hechas desde el otro dispositivo.
    unawaited(_sync.pullSalesFromCloud());
    final start = DateTime(date.year, date.month, date.day).toIso8601String();
    final end =
        DateTime(date.year, date.month, date.day, 23, 59, 59).toIso8601String();
    return db.query(
      'sales_history',
      where: 'billar_id = ? AND date >= ? AND date <= ? AND cancelled = 0',
      whereArgs: [_prefs.billarId, start, end],
      orderBy: 'date DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getTodaySales() async {
    final db = await _db.database;
    final today = DateTime.now();
    final start =
        DateTime(today.year, today.month, today.day).toIso8601String();
    final end =
        DateTime(
          today.year,
          today.month,
          today.day,
          23,
          59,
          59,
        ).toIso8601String();
    return db.query(
      'sales_history',
      where: 'billar_id = ? AND date >= ? AND date <= ? AND cancelled = 0',
      whereArgs: [_prefs.billarId, start, end],
      orderBy: 'date DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getSalesDetails(int saleId) async {
    final db = await _db.database;
    return db.query(
      'sale_details',
      where:
          'sale_id = ? AND EXISTS '
          '(SELECT 1 FROM sales_history s WHERE s.id = sale_details.sale_id AND s.billar_id = ?)',
      whereArgs: [saleId, _prefs.billarId],
    );
  }

  Future<List<Map<String, dynamic>>> getSalesByDateRange(
    DateTime start,
    DateTime end,
  ) async {
    final db = await _db.database;
    unawaited(_sync.pullSalesFromCloud());
    final s = DateTime(start.year, start.month, start.day).toIso8601String();
    final e =
        DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
    return db.query(
      'sales_history',
      where: 'billar_id = ? AND date >= ? AND date <= ? AND cancelled = 0',
      whereArgs: [_prefs.billarId, s, e],
      orderBy: 'date DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getSalesByMonth(
    int year,
    int month,
  ) async {
    final db = await _db.database;
    final start = DateTime(year, month, 1).toIso8601String();
    final end = DateTime(year, month + 1, 0, 23, 59, 59).toIso8601String();
    return db.query(
      'sales_history',
      where: 'billar_id = ? AND date >= ? AND date <= ? AND cancelled = 0',
      whereArgs: [_prefs.billarId, start, end],
      orderBy: 'date DESC',
    );
  }

  Future<Map<String, double>> getTodayStats() async {
    final sales = await getTodaySales();
    double totalVentas = 0;
    for (final s in sales) {
      totalVentas += (s['total'] as num).toDouble();
    }
    return {'total': totalVentas, 'count': sales.length.toDouble()};
  }

  Future<void> _updateTable(
    int tableId,
    String billarId,
    String actorId,
    Map<String, Object?> values,
  ) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      _requireTableScope(actorId, billarId);
      final updated = await txn.update(
        'billiard_tables',
        values,
        where: 'id = ? AND billar_id = ?',
        whereArgs: [tableId, billarId],
      );
      if (updated != 1) {
        throw StateError('La mesa no pertenece al billar actual o no existe.');
      }
      _requireTableScope(actorId, billarId);
    });
  }

  Future<void> saveTableOrder({
    required int tableId,
    required List<SaleItemEntity> items,
    required String tableName,
  }) async {
    final actorId = _captureActorId();
    final billarId = _prefs.billarId;
    final ordersJson = jsonEncode(
      items
          .map(
            (e) => {
              'productId': e.productId,
              'productName': e.productName,
              'price': e.price,
              'quantity': e.quantity,
            },
          )
          .toList(),
    );
    await _updateTable(tableId, billarId, actorId, {
      'orders': ordersJson,
      'is_occupied': items.isEmpty ? 0 : 1,
      if (items.isEmpty) 'start_time': null,
      'synced': 0,
    });
    // Ya no usamos temp_reservations para mesas; billiard_tables.orders es la fuente de verdad.
    await _pushTableToCloud(tableId, billarId, actorId);
  }

  /// Suma las cantidades reservadas (aún no cobradas) de cada producto en
  /// todas las mesas ocupadas (billar/comanda) y en el carrito de venta
  /// rápida activo, para no ofrecer existencias ya comprometidas.
  /// [excludeTableId] permite excluir la mesa actual si se quiere calcular
  /// solo lo reservado por "otras" mesas.
  /// [excludeSource] se reenvía a [StockReservationService] para omitir una
  /// fuente de reservas temporales (ej. 'quick_sale').
  Future<Map<int, double>> getReservedQuantities({
    int? excludeTableId,
    String? excludeSource,
  }) async {
    final actorId = _currentActorId();
    if (actorId == null || actorId.isEmpty) {
      throw StateError('Se requiere una sesión para consultar reservas.');
    }
    final billarId = _prefs.billarId;
    final db = await _db.database;
    String where = 'billar_id = ? AND is_occupied = 1 AND is_deleted = 0';
    final args = <dynamic>[billarId];
    if (excludeTableId != null) {
      where += ' AND id != ?';
      args.add(excludeTableId);
    }
    final rows = await db.query(
      'billiard_tables',
      where: where,
      whereArgs: args,
    );
    final Map<int, double> reserved = {};
    for (final row in rows) {
      final ordersJson = row['orders'] as String?;
      if (ordersJson == null || ordersJson.isEmpty) continue;
      try {
        final list = jsonDecode(ordersJson) as List;
        for (final item in list) {
          final pid = item['productId'];
          final qty = (item['quantity'] as num?)?.toDouble() ?? 0;
          if (pid is int) {
            reserved[pid] = (reserved[pid] ?? 0) + qty;
          }
        }
      } catch (_) {
        // Ignorar filas con JSON corrupto/legado.
      }
    }

    // Las mesas ya se consideran desde billiard_tables.orders.
    if (_prefs.billarId != billarId || _currentActorId() != actorId) {
      throw StateError(
        'La cuenta o el billar cambió durante la consulta de reservas.',
      );
    }
    final otherReservations = await _reservations.getReservedQuantities(
      excludeSources: {'table', if (excludeSource != null) excludeSource},
    );
    if (_prefs.billarId != billarId || _currentActorId() != actorId) {
      throw StateError(
        'La cuenta o el billar cambió durante la consulta de reservas.',
      );
    }
    for (final entry in otherReservations.entries) {
      reserved[entry.key] = (reserved[entry.key] ?? 0) + entry.value;
    }

    return reserved;
  }

  Future<void> occupyTable(int tableId) async {
    final actorId = _captureActorId();
    final billarId = _prefs.billarId;
    // Guardar en UTC para que Supabase (columna timestamptz) lo interprete
    // correctamente y el calculo de tiempo coincida entre dispositivos.
    await _updateTable(tableId, billarId, actorId, {
      'is_occupied': 1,
      'start_time': DateTime.now().toUtc().toIso8601String(),
      'synced': 0,
    });
    await _pushTableToCloud(tableId, billarId, actorId);
  }

  Future<void> freeTable(int tableId) async {
    final actorId = _captureActorId();
    final billarId = _prefs.billarId;
    final db = await _db.database;
    await db.transaction((txn) async {
      _requireTableScope(actorId, billarId);
      final updated = await txn.update(
        'billiard_tables',
        {'is_occupied': 0, 'start_time': null, 'orders': '[]', 'synced': 0},
        where: 'id = ? AND billar_id = ?',
        whereArgs: [tableId, billarId],
      );
      if (updated != 1) {
        throw StateError('La mesa no pertenece al billar actual o no existe.');
      }
      await txn.delete(
        'temp_reservations',
        where:
            'source = ? AND source_id = ? AND '
            'product_id IN (SELECT id FROM products WHERE billar_id = ?)',
        whereArgs: ['table', tableId, billarId],
      );
      _requireTableScope(actorId, billarId);
    });
    await _pushTableToCloud(tableId, billarId, actorId);
  }

  /// Sube el estado actual de una mesa (local) a Supabase para que otros
  /// dispositivos la vean en tiempo real. Es fire-and-forget: si no hay red,
  /// simplemente se ignora sin romper el flujo local.
  Future<void> _pushTableToCloud(
    int tableId,
    String billarId,
    String actorId,
  ) async {
    _requireTableScope(actorId, billarId);
    final db = await _db.database;
    final rows = await db.query(
      'billiard_tables',
      where: 'id = ? AND billar_id = ?',
      whereArgs: [tableId, billarId],
      limit: 1,
    );
    _requireTableScope(actorId, billarId);
    if (rows.isEmpty) return;
    try {
      await _sync.pushTableToCloud(rows.first);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SalesRepository] _pushTableToCloud error: $e');
      }
    }
  }

  Future<List<Map<String, dynamic>>> getTables({
    String tableType = 'Billar',
  }) async {
    final actorId = _captureActorId();
    final billarId = _prefs.billarId;
    final db = await _db.database;
    _requireTableScope(actorId, billarId);
    final localRows = await db.query(
      'billiard_tables',
      where: 'billar_id = ? AND is_deleted = 0',
      whereArgs: [billarId],
      orderBy: 'id ASC',
    );
    _requireTableScope(actorId, billarId);

    if (kDebugMode) {
      debugPrint(
        '[SalesRepository] getTables: billarId=$billarId, local=${localRows.length}',
      );
      for (final r in localRows) {
        debugPrint(
          '  - id=${r['id']} type=${r['table_type']} name=${r['name']}',
        );
      }
    }

    return localRows.where((row) {
      final type = row['table_type'] as String?;
      return tableType == 'Comanda'
          ? type?.trim() == 'Comanda'
          : _isBillarType(type);
    }).toList();
  }

  Future<Set<int>> getTableSyncConflictIds() async {
    final actorId = _captureActorId();
    final billarId = _prefs.billarId;
    final db = await _db.database;
    _requireTableScope(actorId, billarId);
    final ids = await TableSyncConflicts.tableIds(db, actorId, billarId);
    _requireTableScope(actorId, billarId);
    return ids;
  }

  Future<void> refreshTablesFromCloud() =>
      _sync.pullTablesFromCloud(forceApply: true);

  bool _isBillarType(String? type) {
    return const [
      'Billar',
      'Pool',
      'Carambola',
      'Snooker',
    ].contains(type?.trim() ?? 'Billar');
  }

  Future<void> ensureTablesExist(int count) async {
    final actorId = _captureActorId();
    final billarId = _prefs.billarId;
    await _sync.pullTablesFromCloud();
    _requireTableScope(actorId, billarId);
    final db = await _db.database;
    await db.transaction((txn) async {
      _requireTableScope(actorId, billarId);
      final existing = await txn.query(
        'billiard_tables',
        where: 'billar_id = ?',
        whereArgs: [billarId],
        limit: 1,
      );
      if (existing.isEmpty) {
        final rows = await txn.rawQuery(
          'SELECT COALESCE(MAX(id), 0) AS max_id FROM billiard_tables',
        );
        final maxId = (rows.single['max_id'] as num).toInt();
        for (int i = 1; i <= count; i++) {
          await txn.insert('billiard_tables', {
            'id': maxId + i,
            'billar_id': billarId,
            'name': 'Mesa $i',
            'table_type': 'Billar',
            'is_occupied': 0,
            'orders': '[]',
            'synced': 0,
            'is_deleted': 0,
          });
        }
      }
      _requireTableScope(actorId, billarId);
    });
  }
}
