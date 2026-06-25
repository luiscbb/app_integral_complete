import 'dart:convert';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../domain/entities/sale_item_entity.dart';

class SalesRepository {
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  final _sync = SyncService();

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
  }

  Future<void> occupyTable(int tableId) async {
    final db = await _db.database;
    await db.update('billiard_tables',
        {'is_occupied': 1, 'start_time': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [tableId]);
  }

  Future<void> freeTable(int tableId) async {
    final db = await _db.database;
    await db.update('billiard_tables',
        {'is_occupied': 0, 'start_time': null, 'orders': '[]'},
        where: 'id = ?', whereArgs: [tableId]);
  }

  Future<List<Map<String, dynamic>>> getTables() async {
    final db = await _db.database;
    return db.query('billiard_tables', orderBy: 'id ASC');
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
