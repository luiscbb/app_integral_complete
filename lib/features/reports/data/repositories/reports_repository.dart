import 'dart:convert';

import '../../../../core/database/database_helper.dart';
import '../../../../core/storage/preferences_service.dart';

/// Repositorio para el módulo de Informes (Reports).
/// Maneja lectura local de ventas, compras, kardex, flujo de caja,
/// retiros/gastos y cortes de caja.
class ReportsRepository {
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();

  String get _billarId => _prefs.billarId;

  // ─────────────────────────────────────────────────────────────────
  // VENTAS
  // ─────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getSalesByDateRange(DateTime start, DateTime end) async {
    final db = await _db.database;
    final s = DateTime(start.year, start.month, start.day).toIso8601String();
    final e = DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
    return db.query(
      'sales_history',
      where: 'date >= ? AND date <= ?',
      whereArgs: [s, e],
      orderBy: 'date DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getSaleDetails(int saleId) async {
    final db = await _db.database;
    return db.query('sale_details', where: 'sale_id = ?', whereArgs: [saleId]);
  }

  Future<Map<String, double>> getSalesSummary(DateTime start, DateTime end) async {
    final sales = await getSalesByDateRange(start, end);
    double total = 0;
    for (final s in sales) {
      total += (s['total'] as num).toDouble();
    }
    return {'count': sales.length.toDouble(), 'total': total};
  }

  // ─────────────────────────────────────────────────────────────────
  // COMPRAS
  // ─────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getPurchasesByDateRange(DateTime start, DateTime end) async {
    final db = await _db.database;
    final s = DateTime(start.year, start.month, start.day).toIso8601String();
    final e = DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
    return db.query(
      'purchases',
      where: 'date >= ? AND date <= ?',
      whereArgs: [s, e],
      orderBy: 'date DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getPurchaseDetails(int purchaseId) async {
    final db = await _db.database;
    return db.query('purchase_details', where: 'purchase_id = ?', whereArgs: [purchaseId]);
  }

  Future<Map<String, double>> getPurchasesSummary(DateTime start, DateTime end) async {
    final purchases = await getPurchasesByDateRange(start, end);
    double total = 0;
    for (final p in purchases) {
      total += (p['total'] as num).toDouble();
    }
    return {'count': purchases.length.toDouble(), 'total': total};
  }

  // ─────────────────────────────────────────────────────────────────
  // KARDEX / MOVIMIENTOS DE INVENTARIO
  // ─────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getInventoryMovements(int productId, {int limit = 100}) async {
    final db = await _db.database;
    return db.query(
      'inventory_movements',
      where: 'product_id = ?',
      whereArgs: [productId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  Future<void> recordInventoryMovement({
    required int productId,
    required String movementType,
    required double quantity,
    double unitCost = 0,
    double unitPrice = 0,
    int? referenceId,
    String? referenceType,
    String notes = '',
  }) async {
    final db = await _db.database;
    await db.insert('inventory_movements', {
      'billar_id': _billarId,
      'product_id': productId,
      'movement_type': movementType,
      'quantity': quantity,
      'unit_cost': unitCost,
      'unit_price': unitPrice,
      'reference_id': referenceId,
      'reference_type': referenceType,
      'notes': notes,
      'synced': 0,
    });
  }

  // ─────────────────────────────────────────────────────────────────
  // FLUJO DE CAJA / RETIROS
  // ─────────────────────────────────────────────────────────────────

  Future<int> addCashOutflow({
    required String outflowType,
    required double amount,
    required String description,
    String paymentMethod = 'Efectivo',
    String createdBy = '',
  }) async {
    final db = await _db.database;
    return await db.insert('cash_outflows', {
      'billar_id': _billarId,
      'outflow_type': outflowType,
      'amount': amount,
      'description': description,
      'payment_method': paymentMethod,
      'created_by': createdBy,
      'synced': 0,
    });
  }

  Future<List<Map<String, dynamic>>> getCashOutflows(DateTime start, DateTime end) async {
    final db = await _db.database;
    final s = DateTime(start.year, start.month, start.day).toIso8601String();
    final e = DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
    return db.query(
      'cash_outflows',
      where: 'created_at >= ? AND created_at <= ?',
      whereArgs: [s, e],
      orderBy: 'created_at DESC',
    );
  }

  Future<Map<String, double>> getCashFlowSummary(DateTime start, DateTime end) async {
    final sales = await getSalesByDateRange(start, end);
    final purchases = await getPurchasesByDateRange(start, end);
    final outflows = await getCashOutflows(start, end);

    double totalSales = 0;
    for (final s in sales) totalSales += (s['total'] as num).toDouble();

    double totalPurchases = 0;
    for (final p in purchases) totalPurchases += (p['total'] as num).toDouble();

    double totalOutflows = 0;
    for (final o in outflows) totalOutflows += (o['amount'] as num).toDouble();

    return {
      'sales': totalSales,
      'purchases': totalPurchases,
      'outflows': totalOutflows,
      'netCash': totalSales - totalPurchases - totalOutflows,
    };
  }

  // ─────────────────────────────────────────────────────────────────
  // TURNOS / CORTES DE CAJA
  // ─────────────────────────────────────────────────────────────────

  Future<int> openSession({required double openingAmount, String createdBy = ''}) async {
    final db = await _db.database;
    // Cerrar cualquier sesión abierta previamente para evitar duplicados.
    await closeSession(closingAmount: openingAmount, closedBy: createdBy);
    return await db.insert('cashier_sessions', {
      'billar_id': _billarId,
      'opening_amount': openingAmount,
      'created_by': createdBy,
      'is_closed': 0,
      'synced': 0,
    });
  }

  Future<Map<String, dynamic>?> getOpenSession() async {
    final db = await _db.database;
    final rows = await db.query(
      'cashier_sessions',
      where: 'billar_id = ? AND is_closed = ?',
      whereArgs: [_billarId, 0],
      orderBy: 'opened_at DESC',
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<void> closeSession({required double closingAmount, String closedBy = ''}) async {
    final db = await _db.database;
    final session = await getOpenSession();
    if (session == null) return;

    final sessionId = session['id'] as int;
    final openedAt = DateTime.tryParse(session['opened_at'] as String) ?? DateTime.now();
    final summary = await getCashFlowSummary(openedAt, DateTime.now());
    final expected = summary['netCash'] ?? 0;
    final difference = closingAmount - expected;

    await db.update(
      'cashier_sessions',
      {
        'closed_at': DateTime.now().toIso8601String(),
        'closing_amount': closingAmount,
        'expected_amount': expected,
        'difference': difference,
        'is_closed': 1,
        'closed_by': closedBy,
        'synced': 0,
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> addPartialClosure({required double amount, String notes = ''}) async {
    final db = await _db.database;
    final session = await getOpenSession();
    if (session == null) return;

    final sessionId = session['id'] as int;
    final partials = jsonDecode(session['partial_closures'] as String? ?? '[]') as List;
    partials.add({
      'amount': amount,
      'notes': notes,
      'created_at': DateTime.now().toIso8601String(),
    });

    await db.update(
      'cashier_sessions',
      {
        'partial_closures': jsonEncode(partials),
        'synced': 0,
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }
}
