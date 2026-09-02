import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/storage/preferences_service.dart';

/// Repositorio para el módulo de Informes (Reports).
/// Maneja lectura local de ventas, compras, kardex, flujo de caja,
/// retiros/gastos y cortes de caja.
class ReportsRepository {
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();

  SupabaseClient get _supabase => Supabase.instance.client;

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

  /// Solo compras cuyo dinero salió de la Caja (cash_source = 'caja').
  /// Las pagadas por el cajero, transferencia o tarjeta NO afectan el
  /// efectivo esperado del corte de caja.
  Future<List<Map<String, dynamic>>> getPurchasesByDateRangeCashOnly(
    DateTime start,
    DateTime end,
  ) async {
    final db = await _db.database;
    final s = DateTime(start.year, start.month, start.day).toIso8601String();
    final e = DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
    return db.query(
      'purchases',
      where: "date >= ? AND date <= ? AND cash_source = 'caja'",
      whereArgs: [s, e],
      orderBy: 'date DESC',
    );
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
      // Importante: se fija created_at con el MISMO formato ISO (con 'T') que
      // usan ventas/compras, para que el filtro por rango de fechas de
      // getCashOutflows lo encuentre. Si se deja el default de SQLite
      // (datetime('now'), con espacio y UTC) la comparación lexicográfica
      // falla y el retiro no descuenta del flujo de caja.
      'created_at': DateTime.now().toIso8601String(),
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
    // Solo se resta del efectivo lo que realmente salió de la caja física.
    final purchases = await getPurchasesByDateRangeCashOnly(start, end);
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

  // ─────────────────────────────────────────────────────────────────
  // CONCEPTOS DE RETIRO/GASTO (catálogo, patrón de categorías)
  // ─────────────────────────────────────────────────────────────────

  /// Devuelve los conceptos del catálogo (con pull en background desde la nube).
  Future<List<String>> getConcepts() async {
    final db = await _db.database;
    _syncConceptsFromCloud().catchError((e) => debugPrint('[Concepts] Background sync error: $e'));
    final rows = await db.query('cash_outflow_concepts', orderBy: 'name ASC');
    return rows.map((m) => m['name'].toString()).toList();
  }

  /// Agrega un concepto (local + nube). Idempotente por (billar_id, name).
  Future<void> addConcept(String name) async {
    final clean = name.trim().toUpperCase();
    if (clean.isEmpty) return;
    final db = await _db.database;
    try {
      await db.insert('cash_outflow_concepts', {'name': clean, 'billar_id': _billarId});
    } catch (e) {
      debugPrint('[Concepts] addConcept aviso (posible duplicado): $e');
    }
    try {
      await _supabase
          .from('cash_outflow_concepts')
          .upsert({'name': clean, 'billar_id': _billarId}, onConflict: 'billar_id,name');
      debugPrint('[Supabase] Concepto sincronizado: $clean');
    } catch (e) {
      debugPrint('[Supabase] addConcept ERROR: $e');
    }
  }

  /// Renombra un concepto (actualiza local + nube, y borra el nombre antiguo).
  Future<void> renameConcept(String oldName, String newName) async {
    final oldClean = oldName.trim().toUpperCase();
    final newClean = newName.trim().toUpperCase();
    if (oldClean.isEmpty || newClean.isEmpty || oldClean == newClean) return;
    final db = await _db.database;
    try {
      await db.update(
        'cash_outflow_concepts',
        {'name': newClean},
        where: 'name = ? AND billar_id = ?',
        whereArgs: [oldClean, _billarId],
      );
    } catch (e) {
      debugPrint('[Concepts] renameConcept local aviso: $e');
    }
    try {
      await _supabase
          .from('cash_outflow_concepts')
          .upsert({'name': newClean, 'billar_id': _billarId}, onConflict: 'billar_id,name');
      await _supabase
          .from('cash_outflow_concepts')
          .delete()
          .eq('billar_id', _billarId)
          .eq('name', oldClean);
      debugPrint('[Supabase] Concepto renombrado: $oldClean -> $newClean');
    } catch (e) {
      debugPrint('[Supabase] renameConcept ERROR: $e');
    }
  }

  /// Elimina un concepto (local + nube).
  Future<void> deleteConcept(String name) async {
    final clean = name.trim().toUpperCase();
    if (clean.isEmpty) return;
    final db = await _db.database;
    try {
      await db.delete(
        'cash_outflow_concepts',
        where: 'name = ? AND billar_id = ?',
        whereArgs: [clean, _billarId],
      );
    } catch (e) {
      debugPrint('[Concepts] deleteConcept local aviso: $e');
    }
    try {
      await _supabase
          .from('cash_outflow_concepts')
          .delete()
          .eq('billar_id', _billarId)
          .eq('name', clean);
      debugPrint('[Supabase] Concepto eliminado: $clean');
    } catch (e) {
      debugPrint('[Supabase] deleteConcept ERROR: $e');
    }
  }

  /// Descarga los conceptos de la nube hacia la base local (idempotente).
  Future<void> _syncConceptsFromCloud() async {
    try {
      final response = await _supabase
          .from('cash_outflow_concepts')
          .select()
          .eq('billar_id', _billarId)
          .timeout(const Duration(seconds: 8));
      final db = await _db.database;
      for (final item in (response as List)) {
        final name = item['name']?.toString();
        if (name == null || name.isEmpty) continue;
        try {
          await db.insert('cash_outflow_concepts', {'name': name, 'billar_id': _billarId});
        } catch (_) {
          // Ya existe localmente (UNIQUE), se ignora.
        }
      }
    } catch (e) {
      debugPrint('[Supabase] _syncConceptsFromCloud ERROR: $e');
    }
  }
}
