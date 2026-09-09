import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../inventory/data/repositories/product_repository.dart';
import '../../../inventory/domain/entities/product_entity.dart';
import '../../../reports/data/repositories/reports_repository.dart';
import '../../domain/entities/sale_item_entity.dart';
import 'stock_reservation_service.dart';

class SalesRepository {
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  final _sync = SyncService();
  final _reservations = StockReservationService();
  final _reports = ReportsRepository();
  final _productRepo = ProductRepository();

  Future<int> saveSale({
    required List<SaleItemEntity> items,
    required double total,
    required double paid,
    required String paymentMethod,
    required String saleType,
  }) async {
    final db = await _db.database;
    final now = DateTime.now().toIso8601String();

    final saleId = await db.transaction((txn) async {
      final id = await txn.insert('sales_history', {
        'billar_id': _prefs.billarId,
        'total': total,
        'paid': paid,
        'date': now,
        'type': saleType,
        'payment_method': paymentMethod,
        'synced': 0,
      });
      for (final item in items) {
        await txn.insert('sale_details', {
          'sale_id': id,
          'product_id': item.productId,
          'product_name': item.productName,
          'quantity': item.quantity,
          'price_at_sale': item.price,
        });
      }
      return id;
    });

    // Limpiar reserva de venta rápida solo si la venta fue de tipo rápido.
    // Las ventas de mesa no deben afectar el carrito pendiente de Venta Rápida.
    if (saleType == 'Venta Rápida') {
      await _reservations.clearQuickSaleReservation();
    }

    // Registrar movimientos de inventario (kardex) para productos vendidos.
    for (final item in items) {
      if (item.productId != null && !item.productName.startsWith('Tiempo de juego')) {
        await _reports.recordInventoryMovement(
          productId: item.productId!,
          movementType: 'sale',
          quantity: -item.quantity,
          unitPrice: item.price,
          referenceId: saleId,
          referenceType: 'sales_history',
          notes: 'Venta $saleType',
        );
      }
    }

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
    final db = await _db.database;
    final sales = await db.query('sales_history', where: 'id = ?', whereArgs: [saleId]);
    if (sales.isEmpty) return false;
    final sale = sales.first;
    if ((sale['cancelled'] as int? ?? 0) == 1) return true; // ya anulada

    final details = await db.query('sale_details', where: 'sale_id = ?', whereArgs: [saleId]);
    final saleType = sale['type']?.toString() ?? '';

    // Devolver stock de cada producto vendido (el tiempo de mesa no tiene stock).
    for (final d in details) {
      final productId = d['product_id'] as int?;
      final name = d['product_name']?.toString() ?? '';
      final qty = (d['quantity'] as num?)?.toDouble() ?? 0;
      if (productId == null || qty <= 0 || name.startsWith('Tiempo de juego')) continue;

      final prodRows = await db.query('products', where: 'id = ?', whereArgs: [productId]);
      if (prodRows.isEmpty) continue;
      final product = ProductEntity.fromMap(prodRows.first);
      await _productRepo.increaseStock(product, qty);

      await _reports.recordInventoryMovement(
        productId: productId,
        movementType: 'cancel',
        quantity: qty,
        unitPrice: (d['price_at_sale'] as num?)?.toDouble() ?? 0,
        referenceId: saleId,
        referenceType: 'sales_history',
        notes: notes.isEmpty ? 'Anulación de venta $saleType' : notes,
      );
    }

    // Marcar venta y detalles como anulados (local).
    await db.update('sales_history', {'cancelled': 1, 'synced': 0}, where: 'id = ?', whereArgs: [saleId]);
    await db.update('sale_details', {'cancelled': 1}, where: 'sale_id = ?', whereArgs: [saleId]);

    // Propagar anulación a la nube (update por cloud_id; si falla, el sync
    // pendiente la subirá más tarde porque synced quedó en 0).
    final cloudId = sale['cloud_id']?.toString();
    if (cloudId != null) {
      try {
        await _sync.pushSaleToCloud(
          localSaleId: saleId,
          billarId: _prefs.billarId,
          total: (sale['total'] as num).toDouble(),
          paid: (sale['paid'] as num?)?.toDouble() ?? 0,
          date: sale['date'].toString(),
          type: saleType,
          paymentMethod: sale['payment_method']?.toString() ?? 'Efectivo',
          items: details,
          existingCloudId: cloudId,
          cancelled: true,
        );
      } catch (e) {
        debugPrint('[SalesRepository] cancelSale push ERROR: $e');
      }
    } else {
      _sync.schedulePendingSync();
    }

    return true;
  }

  Future<List<Map<String, dynamic>>> getSalesByDate(DateTime date) async {
    final db = await _db.database;
    // Descargar ventas de la nube en background (mismo patrón que el
    // historial de compras). Sin esto, un dispositivo nuevo/vacío no ve
    // las ventas hechas desde el otro dispositivo.
    unawaited(_sync.pullSalesFromCloud());
    final start = DateTime(date.year, date.month, date.day).toIso8601String();
    final end = DateTime(date.year, date.month, date.day, 23, 59, 59).toIso8601String();
    return db.query('sales_history',
        where: 'date >= ? AND date <= ? AND cancelled = 0',
        whereArgs: [start, end],
        orderBy: 'date DESC');
  }

  Future<List<Map<String, dynamic>>> getTodaySales() async {
    final db = await _db.database;
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day).toIso8601String();
    final end = DateTime(today.year, today.month, today.day, 23, 59, 59).toIso8601String();
    return db.query('sales_history',
        where: 'date >= ? AND date <= ? AND cancelled = 0',
        whereArgs: [start, end],
        orderBy: 'date DESC');
  }

  Future<List<Map<String, dynamic>>> getSalesDetails(int saleId) async {
    final db = await _db.database;
    return db.query('sale_details', where: 'sale_id = ?', whereArgs: [saleId]);
  }

  Future<List<Map<String, dynamic>>> getSalesByDateRange(DateTime start, DateTime end) async {
    final db = await _db.database;
    unawaited(_sync.pullSalesFromCloud());
    final s = DateTime(start.year, start.month, start.day).toIso8601String();
    final e = DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
    return db.query('sales_history',
        where: 'date >= ? AND date <= ? AND cancelled = 0',
        whereArgs: [s, e],
        orderBy: 'date DESC');
  }

  Future<List<Map<String, dynamic>>> getSalesByMonth(int year, int month) async {
    final db = await _db.database;
    final start = DateTime(year, month, 1).toIso8601String();
    final end = DateTime(year, month + 1, 0, 23, 59, 59).toIso8601String();
    return db.query('sales_history',
        where: 'date >= ? AND date <= ? AND cancelled = 0',
        whereArgs: [start, end],
        orderBy: 'date DESC');
  }

  Future<Map<String, double>> getTodayStats() async {
    final sales = await getTodaySales();
    double totalVentas = 0;
    for (final s in sales) {
      totalVentas += (s['total'] as num).toDouble();
    }
    return {
      'total': totalVentas,
      'count': sales.length.toDouble(),
    };
  }

  Future<void> saveTableOrder({
    required int tableId,
    required List<SaleItemEntity> items,
    required String tableName,
  }) async {
    final db = await _db.database;
    final ordersJson = jsonEncode(items.map((e) => {
      'productId': e.productId,
      'productName': e.productName,
      'price': e.price,
      'quantity': e.quantity,
    }).toList());
    await db.update('billiard_tables',
        {'orders': ordersJson, 'is_occupied': items.isEmpty ? 0 : 1},
        where: 'id = ?', whereArgs: [tableId]);
    // Ya no usamos temp_reservations para mesas; billiard_tables.orders es la fuente de verdad.
    await _pushTableToCloud(tableId);
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
    final db = await _db.database;
    final billarId = _prefs.billarId;
    String where = 'billar_id = ? AND is_occupied = 1';
    final args = <dynamic>[billarId];
    if (excludeTableId != null) {
      where += ' AND id != ?';
      args.add(excludeTableId);
    }
    final rows = await db.query('billiard_tables', where: where, whereArgs: args);
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

    // Agregar reservas temporales del carrito de venta rápida solamente.
    // Las mesas ya se consideran desde billiard_tables.orders.
    final quickReservations = await _reservations.getReservedQuantities(
      excludeSource: excludeSource ?? 'table',
    );
    for (final entry in quickReservations.entries) {
      reserved[entry.key] = (reserved[entry.key] ?? 0) + entry.value;
    }

    return reserved;
  }

  Future<void> occupyTable(int tableId) async {
    final db = await _db.database;
    // Guardar en UTC para que Supabase (columna timestamptz) lo interprete
    // correctamente y el calculo de tiempo coincida entre dispositivos.
    await db.update('billiard_tables',
        {'is_occupied': 1, 'start_time': DateTime.now().toUtc().toIso8601String()},
        where: 'id = ?', whereArgs: [tableId]);
    await _pushTableToCloud(tableId);
  }

  Future<void> freeTable(int tableId) async {
    final db = await _db.database;
    await db.update('billiard_tables',
        {'is_occupied': 0, 'start_time': null, 'orders': '[]'},
        where: 'id = ?', whereArgs: [tableId]);
    await _reservations.clearTableReservation(tableId);
    await _pushTableToCloud(tableId);
  }

  /// Sube el estado actual de una mesa (local) a Supabase para que otros
  /// dispositivos la vean en tiempo real. Es fire-and-forget: si no hay red,
  /// simplemente se ignora sin romper el flujo local.
  Future<void> _pushTableToCloud(int tableId) async {
    try {
      final db = await _db.database;
      final billarId = _prefs.billarId;
      final rows = await db.query(
        'billiard_tables',
        where: 'id = ? AND billar_id = ?',
        whereArgs: [tableId, billarId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      await _sync.pushTableToCloud(rows.first);
    } catch (e) {
      if (kDebugMode) debugPrint('[SalesRepository] _pushTableToCloud error: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getTables() async {
    final db = await _db.database;
    final billarId = _prefs.billarId;

    // Siempre intentar pull en primer plano con la nube como fuente de verdad.
    // El listado de mesas es solo vista (no edita), asi que refleja el estado
    // real aunque la copia local tenga mesas "ocupadas" de una sesion anterior.
    try {
      await _sync.pullTablesFromCloud(forceApply: true);
    } catch (e) {
      if (kDebugMode) debugPrint('[SalesRepository] pullTablesFromCloud error: $e');
    }

    var localRows = await db.query(
      'billiard_tables',
      where: 'billar_id = ?',
      whereArgs: [billarId],
      orderBy: 'id ASC',
    );

    if (kDebugMode) {
      debugPrint('[SalesRepository] getTables: billarId=$billarId, local=${localRows.length}');
      for (final r in localRows) {
        debugPrint('  - id=${r['id']} type=${r['table_type']} name=${r['name']}');
      }
    }

    return localRows.where((r) => _isBillarType(r['table_type'] as String?)).toList();
  }

  bool _isBillarType(String? type) {
    return const ['Billar', 'Pool', 'Carambola', 'Snooker'].contains(type?.trim() ?? 'Billar');
  }

  Future<void> ensureTablesExist(int count) async {
    final db = await _db.database;
    final existing = await db.query('billiard_tables');
    final existingIds = existing.map((e) => e['id'] as int).toSet();

    for (int i = 1; i <= count; i++) {
      if (!existingIds.contains(i)) {
        await db.insert('billiard_tables', {
          'id': i,
          'billar_id': _prefs.billarId,
          'name': 'Mesa $i',
          'table_type': 'Billar',
          'is_occupied': 0,
          'orders': '[]',
        });
      }
    }

    for (final row in existing) {
      final id = row['id'] as int;
      if (id > count && row['is_occupied'] == 0) {
        final orders = row['orders']?.toString() ?? '[]';
        if (orders == '[]' || orders.isEmpty) {
          await db.delete('billiard_tables', where: 'id = ?', whereArgs: [id]);
        }
      }
    }
  }
}
