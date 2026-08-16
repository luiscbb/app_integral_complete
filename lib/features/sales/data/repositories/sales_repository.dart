import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../reports/data/repositories/reports_repository.dart';
import '../../domain/entities/sale_item_entity.dart';
import 'stock_reservation_service.dart';

class SalesRepository {
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  final _sync = SyncService();
  final _reservations = StockReservationService();
  final _reports = ReportsRepository();

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

  Future<List<Map<String, dynamic>>> getSalesByDate(DateTime date) async {
    final db = await _db.database;
    final start = DateTime(date.year, date.month, date.day).toIso8601String();
    final end = DateTime(date.year, date.month, date.day, 23, 59, 59).toIso8601String();
    return db.query('sales_history',
        where: 'date >= ? AND date <= ?',
        whereArgs: [start, end],
        orderBy: 'date DESC');
  }

  Future<List<Map<String, dynamic>>> getTodaySales() async {
    final db = await _db.database;
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day).toIso8601String();
    final end = DateTime(today.year, today.month, today.day, 23, 59, 59).toIso8601String();
    return db.query('sales_history',
        where: 'date >= ? AND date <= ?',
        whereArgs: [start, end],
        orderBy: 'date DESC');
  }

  Future<List<Map<String, dynamic>>> getSalesDetails(int saleId) async {
    final db = await _db.database;
    return db.query('sale_details', where: 'sale_id = ?', whereArgs: [saleId]);
  }

  Future<List<Map<String, dynamic>>> getSalesByDateRange(DateTime start, DateTime end) async {
    final db = await _db.database;
    final s = DateTime(start.year, start.month, start.day).toIso8601String();
    final e = DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
    return db.query('sales_history',
        where: 'date >= ? AND date <= ?',
        whereArgs: [s, e],
        orderBy: 'date DESC');
  }

  Future<List<Map<String, dynamic>>> getSalesByMonth(int year, int month) async {
    final db = await _db.database;
    final start = DateTime(year, month, 1).toIso8601String();
    final end = DateTime(year, month + 1, 0, 23, 59, 59).toIso8601String();
    return db.query('sales_history',
        where: 'date >= ? AND date <= ?',
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
    await db.update('billiard_tables',
        {'is_occupied': 1, 'start_time': DateTime.now().toIso8601String()},
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

  Future<List<Map<String, dynamic>>> getTables({bool forceApply = false}) async {
    final db = await _db.database;
    final billarId = _prefs.billarId;

    // Siempre intentar pull en primer plano para asegurar que estén al día
    // (especialmente tras reinstalación o cambio de dispositivo). forceApply
    // se usa cuando llega un cambio Realtime para que la nube sea la fuente de verdad.
    try {
      await _sync.pullTablesFromCloud(forceApply: forceApply);
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
