import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/database/purchase_scope.dart';
import '../../../../core/services/inventory_movement_sync_service.dart';
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

  Future<List<Map<String, dynamic>>> getSalesByDateRange(
    DateTime start,
    DateTime end,
  ) async {
    final db = await _db.database;
    final s = DateTime(start.year, start.month, start.day).toIso8601String();
    final e =
        DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
    return db.query(
      'sales_history',
      where: 'billar_id = ? AND date >= ? AND date <= ? AND cancelled = 0',
      whereArgs: [_billarId, s, e],
      orderBy: 'date DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getSaleDetails(int saleId) async {
    final db = await _db.database;
    return db.query(
      'sale_details',
      where:
          'sale_id = ? AND EXISTS '
          '(SELECT 1 FROM sales_history s WHERE s.id = sale_details.sale_id AND s.billar_id = ?)',
      whereArgs: [saleId, _billarId],
    );
  }

  Future<Map<String, double>> getSalesSummary(
    DateTime start,
    DateTime end,
  ) async {
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

  Future<List<Map<String, dynamic>>> getPurchasesByDateRange(
    DateTime start,
    DateTime end,
  ) async {
    final db = await _db.database;
    final s = DateTime(start.year, start.month, start.day).toIso8601String();
    final e =
        DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
    return db.query(
      'purchases',
      where:
          '${purchaseBusinessScope()} AND date >= ? AND date <= ? AND cancelled = 0',
      whereArgs: [_billarId, s, e],
      orderBy: 'date DESC',
    );
  }

  Future<List<Map<String, dynamic>>> getPurchaseDetails(int purchaseId) async {
    final db = await _db.database;
    return db.query(
      'purchase_details',
      where:
          'purchase_id = ? AND EXISTS '
          '(SELECT 1 FROM purchases p WHERE p.id = purchase_details.purchase_id '
          'AND ${purchaseBusinessScope('p')})',
      whereArgs: [purchaseId, _billarId],
    );
  }

  Future<Map<String, double>> getPurchasesSummary(
    DateTime start,
    DateTime end,
  ) async {
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
    final e =
        DateTime(end.year, end.month, end.day, 23, 59, 59).toIso8601String();
    return db.query(
      'purchases',
      where:
          "${purchaseBusinessScope()} AND date >= ? AND date <= ? "
          "AND cash_source = 'caja' AND cancelled = 0",
      whereArgs: [_billarId, s, e],
      orderBy: 'date DESC',
    );
  }

  // ─────────────────────────────────────────────────────────────────
  // KARDEX / MOVIMIENTOS DE INVENTARIO
  // ─────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getInventoryMovements(
    int productId, {
    int limit = 100,
  }) async {
    await InventoryMovementSyncService.instance.sync();
    final db = await _db.database;
    return db.query(
      'inventory_movements',
      where: 'product_id = ? AND billar_id = ?',
      whereArgs: [productId, _billarId],
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
    if (!amount.isFinite || amount <= 0) {
      throw ArgumentError('El movimiento debe tener un monto mayor a cero.');
    }
    _cashMethod(paymentMethod);
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

  Future<List<Map<String, dynamic>>> getCashOutflows(
    DateTime start,
    DateTime end,
  ) async {
    final billarId = _billarId;
    final db = await _db.database;
    final rows = await _cashRows(
      db,
      billarId,
      'cash_outflows',
      'created_at',
      DateTime(start.year, start.month, start.day),
      DateTime(end.year, end.month, end.day + 1),
    );
    rows.sort(
      (a, b) => _cashTimestamp(
        b['created_at'],
      ).compareTo(_cashTimestamp(a['created_at'])),
    );
    return rows;
  }

  Future<Map<String, double>> getCashFlowSummary(
    DateTime start,
    DateTime end,
  ) async {
    final billarId = _billarId;
    final db = await _db.database;
    return db.transaction(
      (txn) => _cashSummary(
        txn,
        billarId,
        DateTime(start.year, start.month, start.day),
        DateTime(end.year, end.month, end.day + 1),
      ),
    );
  }

  DateTime _cashTimestamp(Object? value) {
    if (value is! String) {
      throw const FormatException(
        'Un movimiento de caja no tiene fecha válida.',
      );
    }
    // SQLite's legacy datetime('now') is UTC; unzoned ISO values are local.
    final text =
        value.contains(' ') &&
                !RegExp(
                  r'(Z|[+-]\d{2}:\d{2})$',
                  caseSensitive: false,
                ).hasMatch(value)
            ? '${value.replaceFirst(' ', 'T')}Z'
            : value;
    final parsed = DateTime.tryParse(text);
    if (parsed == null) {
      throw const FormatException(
        'Un movimiento de caja no tiene fecha válida.',
      );
    }
    return parsed.toLocal();
  }

  double _cashAmount(Object? value) {
    if (value is! num || !value.isFinite || value < 0) {
      throw const FormatException('Un importe de caja no es válido.');
    }
    return value.toDouble();
  }

  String _cashMethod(Object? value) {
    final method = value is String ? value.trim().toLowerCase() : '';
    if (!['efectivo', 'tarjeta', 'transferencia'].contains(method)) {
      throw const FormatException(
        'La forma de pago del movimiento no es válida.',
      );
    }
    return method;
  }

  Future<List<Map<String, Object?>>> _cashRows(
    DatabaseExecutor db,
    String billarId,
    String table,
    String dateColumn,
    DateTime start,
    DateTime end, {
    bool excludeCancelled = false,
  }) async {
    final lower = start.subtract(const Duration(days: 1));
    final upper = end.add(const Duration(days: 1));
    final rows = await db.query(
      table,
      where:
          'billar_id = ? AND substr($dateColumn, 1, 10) >= ? '
          'AND substr($dateColumn, 1, 10) <= ?'
          '${excludeCancelled ? ' AND cancelled = 0' : ''}',
      whereArgs: [
        billarId,
        lower.toIso8601String().substring(0, 10),
        upper.toIso8601String().substring(0, 10),
      ],
    );
    return rows.where((row) {
      final date = _cashTimestamp(row[dateColumn]);
      return !date.isBefore(start) && date.isBefore(end);
    }).toList();
  }

  Future<Map<String, double>> _cashSummary(
    DatabaseExecutor db,
    String billarId,
    DateTime start,
    DateTime end, {
    bool includeShared = true,
  }) async {
    final sales = await _cashRows(
      db,
      billarId,
      'sales_history',
      'date',
      start,
      end,
      excludeCancelled: true,
    );
    final purchases = await _cashRows(
      db,
      billarId,
      'purchases',
      'date',
      start,
      end,
      excludeCancelled: true,
    );
    final outflows = await _cashRows(
      db,
      billarId,
      'cash_outflows',
      'created_at',
      start,
      end,
    );
    double cashSales = 0, cashPurchases = 0, cashOutflows = 0;
    double totalSales = 0, totalPurchases = 0, totalOutflows = 0;
    double cardSales = 0, transferSales = 0, creditPurchases = 0;
    double inflows = 0;
    if (includeShared) {
      final shared = await _cashRows(
        db,
        billarId,
        'cash_shared_movement_cache',
        'created_at',
        start,
        end,
      );
      for (final movement in shared) {
        final amount = _cashAmount(movement['amount']);
        if (movement['kind'] == 'contribution') {
          inflows += amount;
        } else {
          totalOutflows += amount;
          if (_cashMethod(movement['payment_method']) == 'efectivo') {
            cashOutflows += amount;
          }
        }
      }
    }
    for (final sale in sales) {
      final total = _cashAmount(sale['total']);
      final paid = _cashAmount(sale['paid'] ?? total);
      final collected = paid > total ? total : paid;
      final method = _cashMethod(sale['payment_method']);
      totalSales += collected;
      if (method == 'efectivo') cashSales += collected;
      if (method == 'tarjeta') cardSales += collected;
      if (method == 'transferencia') transferSales += collected;
    }
    for (final purchase in purchases) {
      final total = _cashAmount(purchase['total']);
      if (purchase['payment_condition'] == 'credito') {
        creditPurchases += total;
        continue;
      }
      final paid = _cashAmount(purchase['paid_amount'] ?? total);
      final amount = paid > total ? total : paid;
      final source = purchase['cash_source'];
      final method = _cashMethod(
        purchase['payment_method'] ??
            (source == 'caja' || source == 'cajero' ? 'efectivo' : source),
      );
      totalPurchases += amount;
      if (method == 'efectivo' && source == 'caja') cashPurchases += amount;
    }
    for (final outflow in outflows) {
      final amount = _cashAmount(outflow['amount']);
      final method = _cashMethod(outflow['payment_method'] ?? 'Efectivo');
      totalOutflows += amount;
      if (method == 'efectivo') cashOutflows += amount;
    }
    final partials = await _cashPartials(db, billarId);
    for (final partial in partials) {
      // New partials reference an outflow already counted above.
      if (partial['outflow_id'] != null) continue;
      final date = _cashTimestamp(partial['created_at']);
      if (!date.isBefore(start) && date.isBefore(end)) {
        final amount = _cashAmount(partial['amount']);
        totalOutflows += amount;
        cashOutflows += amount;
      }
    }
    return {
      'sales': cashSales,
      'purchases': cashPurchases,
      'outflows': cashOutflows,
      'inflows': inflows,
      'netCash': cashSales + inflows - cashPurchases - cashOutflows,
      'totalSales': totalSales,
      'totalPurchases': totalPurchases,
      'totalOutflows': totalOutflows,
      'netFlow': totalSales + inflows - totalPurchases - totalOutflows,
      'cardSales': cardSales,
      'transferSales': transferSales,
      'creditPurchases': creditPurchases,
    };
  }

  Future<List<Map<String, dynamic>>> _cashPartials(
    DatabaseExecutor db,
    String billarId,
  ) async {
    final sessions = await db.query(
      'cashier_sessions',
      columns: ['partial_closures'],
      where:
          'billar_id = ? AND partial_closures IS NOT NULL AND partial_closures != ?',
      whereArgs: [billarId, '[]'],
    );
    final entries = <Map<String, dynamic>>[];
    for (final session in sessions) {
      final partials = jsonDecode(session['partial_closures'] as String);
      if (partials is! List) {
        throw const FormatException(
          'Los retiros parciales del turno no son válidos.',
        );
      }
      for (final partial in partials) {
        if (partial is! Map<String, dynamic>) {
          throw const FormatException('Un retiro parcial no es válido.');
        }
        entries.add(partial);
      }
    }
    return entries;
  }

  Future<Map<String, double>> getSessionCashFlowSummary(
    Map<String, dynamic> session,
  ) async {
    final billarId = _billarId;
    if (session['billar_id'] != billarId) {
      throw StateError('El turno no pertenece al billar actual.');
    }
    final start = _cashTimestamp(session['opened_at']);
    final end =
        session['closed_at'] == null
            ? DateTime.now()
            : _cashTimestamp(session['closed_at']);
    final db = await _db.database;
    return db.transaction(
      (txn) => _cashSummary(txn, billarId, start, end, includeShared: false),
    );
  }

  // ─────────────────────────────────────────────────────────────────
  // UTILIDAD (Etapa 4)
  // ─────────────────────────────────────────────────────────────────

  /// Informe de utilidad del rango:
  ///   Ventas − Costo de lo vendido − Retiros/Gastos = UTILIDAD NETA.
  /// - El costo de lo vendido usa `cost_at_sale` (costo histórico guardado al
  ///   momento de vender). Si faltan costos, la utilidad no está disponible.
  /// - Las compras NO se restan (son inventario/activo), solo se listan fuera.
  /// - [expensesByConcept] agrupa los retiros/gastos por concepto.
  Future<Map<String, dynamic>> getProfitSummary(
    DateTime start,
    DateTime end,
  ) async {
    final sales = await getSalesByDateRange(start, end);
    final outflows = await getCashOutflows(start, end);

    final db = await _db.database;
    double totalSales = 0;
    double totalCost = 0;
    var costsAvailable = true;
    for (final s in sales) {
      totalSales += (s['total'] as num).toDouble();
      final rows = await db.query(
        'sale_details',
        columns: ['quantity', 'cost_at_sale', 'cost_available', 'cancelled'],
        where: 'sale_id = ?',
        whereArgs: [s['id']],
      );
      if (rows.isEmpty) costsAvailable = false;
      for (final d in rows) {
        if (d['cancelled'] == 1) continue;
        if (d['cost_available'] != 1) costsAvailable = false;
        final qty = (d['quantity'] as num?)?.toDouble() ?? 0;
        final cost = (d['cost_at_sale'] as num?)?.toDouble() ?? 0;
        totalCost += qty * cost;
      }
    }

    double totalOutflows = 0;
    final partialOutflowIds =
        (await _cashPartials(
          db,
          _billarId,
        )).map((partial) => partial['outflow_id']).whereType<int>().toSet();
    final Map<String, double> expensesByConcept = {};
    for (final o in outflows) {
      if (partialOutflowIds.contains(o['id'])) continue;
      final amount = (o['amount'] as num).toDouble();
      totalOutflows += amount;
      // El concepto vive en outflow_type (catálogo de conceptos).
      final concept =
          (o['outflow_type']?.toString() ?? 'SIN CONCEPTO')
              .trim()
              .toUpperCase();
      expensesByConcept[concept] = (expensesByConcept[concept] ?? 0) + amount;
    }
    final shared = await _cashRows(
      db,
      _billarId,
      'cash_shared_movement_cache',
      'created_at',
      DateTime(start.year, start.month, start.day),
      DateTime(end.year, end.month, end.day + 1),
    );
    for (final movement in shared.where((row) => row['kind'] == 'expense')) {
      final amount = _cashAmount(movement['amount']);
      totalOutflows += amount;
      const concept = 'GASTOS DE CAJA COMPARTIDA';
      expensesByConcept[concept] = (expensesByConcept[concept] ?? 0) + amount;
    }

    return {
      'sales': totalSales,
      'costOfGoodsSold': costsAvailable ? totalCost : null,
      'expenses': totalOutflows,
      'profit': costsAvailable ? totalSales - totalCost - totalOutflows : null,
      'costsAvailable': costsAvailable,
      'salesCount': sales.length.toDouble(),
      'expensesByConcept': expensesByConcept,
    };
  }

  // ─────────────────────────────────────────────────────────────────
  // TURNOS / CORTES DE CAJA
  // ─────────────────────────────────────────────────────────────────

  Future<int> openSession({
    required double openingAmount,
    String createdBy = '',
  }) async {
    _cashAmount(openingAmount);
    final billarId = _billarId;
    final db = await _db.database;
    return db.transaction((txn) async {
      final open = await txn.query(
        'cashier_sessions',
        where: 'billar_id = ? AND is_closed = 0',
        whereArgs: [billarId],
        limit: 1,
      );
      if (open.isNotEmpty) {
        throw StateError(
          'Ya hay un turno abierto. Ciérralo explícitamente antes de abrir otro.',
        );
      }
      return txn.insert('cashier_sessions', {
        'billar_id': billarId,
        'opened_at': DateTime.now().toIso8601String(),
        'opening_amount': openingAmount,
        'created_by': createdBy,
        'is_closed': 0,
        'synced': 0,
      });
    });
  }

  Future<Map<String, dynamic>?> getOpenSession() async {
    final db = await _db.database;
    final rows = await db.query(
      'cashier_sessions',
      where: 'billar_id = ? AND is_closed = ?',
      whereArgs: [_billarId, 0],
      orderBy: 'opened_at DESC',
      limit: 2,
    );
    if (rows.length > 1) {
      throw StateError(
        'Hay más de un turno abierto. Solicita revisión antes de operar caja.',
      );
    }
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<Map<String, double>> closeSession({
    required double closingAmount,
    String closedBy = '',
    int? sessionId,
    double? nextOpeningAmount,
    String? nextCreatedBy,
  }) async {
    _cashAmount(closingAmount);
    if (nextOpeningAmount != null) _cashAmount(nextOpeningAmount);
    final billarId = _billarId;
    final db = await _db.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'cashier_sessions',
        where: 'billar_id = ? AND is_closed = 0',
        whereArgs: [billarId],
      );
      if (rows.length != 1 ||
          (sessionId != null && rows.single['id'] != sessionId)) {
        throw StateError(
          'El turno cambió o no hay un único turno abierto. Actualiza caja.',
        );
      }
      final session = rows.single;
      final now = DateTime.now();
      final summary = await _cashSummary(
        txn,
        billarId,
        _cashTimestamp(session['opened_at']),
        now,
        includeShared: false,
      );
      final opening = _cashAmount(session['opening_amount']);
      final expected = opening + summary['netCash']!;
      final difference = closingAmount - expected;
      await txn.update(
        'cashier_sessions',
        {
          'closed_at': now.toIso8601String(),
          'closing_amount': closingAmount,
          'expected_amount': expected,
          'difference': difference,
          'is_closed': 1,
          'closed_by': closedBy,
          'synced': 0,
        },
        where: 'id = ? AND billar_id = ?',
        whereArgs: [session['id'], billarId],
      );
      if (nextOpeningAmount != null) {
        await txn.insert('cashier_sessions', {
          'billar_id': billarId,
          'opened_at': now.toIso8601String(),
          'opening_amount': nextOpeningAmount,
          'created_by': nextCreatedBy ?? closedBy,
          'is_closed': 0,
          'synced': 0,
        });
      }
      return {
        ...summary,
        'openingAmount': opening,
        'expected': expected,
        'difference': difference,
      };
    });
  }

  Future<void> addPartialClosure({
    required double amount,
    String notes = '',
    String createdBy = '',
    int? sessionId,
  }) async {
    if (!amount.isFinite || amount <= 0) {
      throw ArgumentError('El retiro parcial debe ser mayor a cero.');
    }
    final billarId = _billarId;
    final db = await _db.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'cashier_sessions',
        where: 'billar_id = ? AND is_closed = 0',
        whereArgs: [billarId],
      );
      if (rows.length != 1 ||
          (sessionId != null && rows.single['id'] != sessionId)) {
        throw StateError(
          'El turno cambió o no hay un único turno abierto. Actualiza caja.',
        );
      }
      final session = rows.single;
      final partials = jsonDecode(
        session['partial_closures'] as String? ?? '[]',
      );
      if (partials is! List) {
        throw const FormatException(
          'Los retiros parciales del turno no son válidos.',
        );
      }
      final now = DateTime.now().toIso8601String();
      final outflowId = await txn.insert('cash_outflows', {
        'billar_id': billarId,
        'outflow_type': 'CORTE PARCIAL',
        'amount': amount,
        'description': notes,
        'payment_method': 'Efectivo',
        'created_by': createdBy,
        'created_at': now,
        'synced': 0,
      });
      partials.add({
        'amount': amount,
        'notes': notes,
        'created_at': now,
        'outflow_id': outflowId,
      });
      await txn.update(
        'cashier_sessions',
        {'partial_closures': jsonEncode(partials), 'synced': 0},
        where: 'id = ? AND billar_id = ?',
        whereArgs: [session['id'], billarId],
      );
    });
  }

  // ─────────────────────────────────────────────────────────────────
  // CONCEPTOS DE RETIRO/GASTO (catálogo, patrón de categorías)
  // ─────────────────────────────────────────────────────────────────

  /// Devuelve los conceptos del catálogo (con pull en background desde la nube).
  Future<List<String>> getConcepts() async {
    final db = await _db.database;
    _syncConceptsFromCloud().catchError(
      (e) => debugPrint('[Concepts] Background sync error: $e'),
    );
    final rows = await db.query('cash_outflow_concepts', orderBy: 'name ASC');
    return rows.map((m) => m['name'].toString()).toList();
  }

  /// Agrega un concepto (local + nube). Idempotente por (billar_id, name).
  Future<void> addConcept(String name) async {
    final clean = name.trim().toUpperCase();
    if (clean.isEmpty) return;
    final db = await _db.database;
    try {
      await db.insert('cash_outflow_concepts', {
        'name': clean,
        'billar_id': _billarId,
      });
    } catch (e) {
      debugPrint('[Concepts] addConcept aviso (posible duplicado): $e');
    }
    try {
      await _supabase.from('cash_outflow_concepts').upsert({
        'name': clean,
        'billar_id': _billarId,
      }, onConflict: 'billar_id,name');
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
      await _supabase.from('cash_outflow_concepts').upsert({
        'name': newClean,
        'billar_id': _billarId,
      }, onConflict: 'billar_id,name');
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
          await db.insert('cash_outflow_concepts', {
            'name': name,
            'billar_id': _billarId,
          });
        } catch (_) {
          // Ya existe localmente (UNIQUE), se ignora.
        }
      }
    } catch (e) {
      debugPrint('[Supabase] _syncConceptsFromCloud ERROR: $e');
    }
  }
}
