import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/database/purchase_scope.dart';
import '../../../../core/services/app_services.dart';
import '../../../../core/services/sync_session.dart';
import '../../../../core/storage/account_storage.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/utils/uuid_v4.dart';
import '../../../reports/data/repositories/reports_repository.dart';

class SharedCashRepository extends ReportsRepository {
  SupabaseClient get _client => Supabase.instance.client;
  final _preferences = PreferencesService();

  SyncSession _capture() {
    if (!AccountStorage.instance.isActive) {
      throw StateError('La cuenta ya no está activa.');
    }
    return SyncSessionGuard(_client, _preferences).capture();
  }

  void _require(SyncSession session) =>
      SyncSessionGuard(_client, _preferences).require(session);

  Future<Object?> _rpc(
    SyncSession session,
    String name,
    Map<String, Object?> params,
  ) async {
    _require(session);
    final Object? result = await _client
        .rpc(name, params: params)
        .setHeader('Authorization', 'Bearer ${session.token}');
    _require(session);
    return result;
  }

  double _number(Object? value) {
    if (value is! num || !value.isFinite) {
      throw const FormatException('Un importe de caja no es válido.');
    }
    return value.toDouble();
  }

  Map<String, double> _summary(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('El resumen de caja no es válido.');
    }
    const required = {
      'sales',
      'purchases',
      'inflows',
      'outflows',
      'netCash',
      'totalSales',
      'totalPurchases',
      'totalOutflows',
      'netFlow',
      'cardSales',
      'transferSales',
      'creditPurchases',
    };
    if (!required.every(value.containsKey)) {
      throw const FormatException('El resumen de caja está incompleto.');
    }
    return {for (final entry in value.entries) entry.key: _number(entry.value)};
  }

  Map<String, dynamic> _scopedRow(Object? value, SyncSession session) {
    if (value is! Map<String, dynamic> ||
        value['billar_id'] != session.billarId ||
        value['id'] is! int ||
        value['id'] <= 0) {
      throw const FormatException(
        'El registro de caja no pertenece al negocio.',
      );
    }
    return value;
  }

  Map<String, dynamic> _session(Object? value, SyncSession session) {
    final row = _scopedRow(value, session);
    final opened = row['opened_at'];
    final closed = row['closed_at'];
    if (opened is! String ||
        DateTime.tryParse(opened) == null ||
        (closed != null &&
            (closed is! String || DateTime.tryParse(closed) == null)) ||
        row['opened_by'] is! String ||
        _number(row['opening_amount']) < 0 ||
        (closed != null &&
            (_number(row['closing_amount']) < 0 ||
                row['closed_by'] is! String))) {
      throw const FormatException('El turno compartido no es válido.');
    }
    if (closed != null) {
      _number(row['expected_amount']);
      _number(row['difference']);
      _summary(row['closing_summary']);
    }
    return {
      ...row,
      'created_by': row['opened_by'],
      'is_closed': closed == null ? 0 : 1,
      'closing_summary':
          closed == null ? null : _summary(row['closing_summary']),
    };
  }

  Future<Map<String, dynamic>> state(
    DateTime start,
    DateTime end, {
    int? beforeSession,
    int? beforeMovement,
  }) async {
    if (!end.isAfter(start) ||
        end.difference(start) > const Duration(days: 366)) {
      throw ArgumentError('Selecciona un rango de caja de hasta 366 días.');
    }
    final session = _capture();
    final result = await _rpc(session, 'cash_shared_state', {
      'requested_billar_id': session.billarId,
      'start_at': start.toUtc().toIso8601String(),
      'end_at': end.toUtc().toIso8601String(),
      'before_session_id': beforeSession,
      'before_movement_id': beforeMovement,
    });
    if (result is! Map<String, dynamic> ||
        result['billar_id'] != session.billarId ||
        result['sessions'] is! List ||
        result['movements'] is! List ||
        result['more_sessions'] is! bool ||
        result['more_movements'] is! bool) {
      throw const FormatException('La respuesta de caja no es válida.');
    }
    final open =
        result['session'] == null ? null : _session(result['session'], session);
    if (open != null && open['closed_at'] != null) {
      throw const FormatException('El turno recibido ya está cerrado.');
    }
    final summary =
        open == null ? <String, double>{} : _summary(result['summary']);
    final sessions = <Map<String, dynamic>>[];
    var sessionCursor = beforeSession;
    for (final row in result['sessions'] as List) {
      final parsed = _session(row, session);
      if ((sessionCursor != null && parsed['id'] >= sessionCursor) ||
          parsed['needs_reconciliation'] is! bool) {
        throw const FormatException('El historial de turnos no es válido.');
      }
      sessionCursor = parsed['id'] as int;
      sessions.add(parsed);
    }
    final movements = <Map<String, dynamic>>[];
    var movementCursor = beforeMovement;
    for (final value in result['movements'] as List) {
      final row = _scopedRow(value, session);
      final timestamp = row['created_at'];
      final date = timestamp is String ? DateTime.tryParse(timestamp) : null;
      if (date == null ||
          date.isBefore(start) ||
          !date.isBefore(end) ||
          (movementCursor != null && row['id'] >= movementCursor) ||
          !const {
            'contribution',
            'expense',
            'withdrawal',
            'partial',
          }.contains(row['kind']) ||
          !const {
            'Efectivo',
            'Tarjeta',
            'Transferencia',
          }.contains(row['payment_method']) ||
          row['description'] is! String ||
          row['created_by'] is! String ||
          _number(row['amount']) <= 0) {
        throw const FormatException('Un movimiento compartido no es válido.');
      }
      movementCursor = row['id'] as int;
      final label = switch (row['kind']) {
        'contribution' => 'APORTE MANUAL',
        'withdrawal' => 'RETIRO (NO ES GASTO)',
        'partial' => 'CORTE PARCIAL',
        _ => 'GASTO',
      };
      movements.add({...row, 'outflow_type': label});
    }
    if (sessions.length > 50 ||
        movements.length > 50 ||
        (result['more_sessions'] == true && sessions.length != 50) ||
        (result['more_movements'] == true && movements.length != 50)) {
      throw const FormatException('La página de caja no es válida.');
    }
    _require(session);
    final db = await DatabaseHelper.instance.database;
    await db.transaction((txn) async {
      _require(session);
      for (final movement in movements) {
        await txn.rawInsert(
          '''
          INSERT INTO cash_shared_movement_cache
            (cloud_id,billar_id,kind,amount,payment_method,description,created_at)
          VALUES (?,?,?,?,?,?,?)
          ON CONFLICT(cloud_id) DO UPDATE SET
            kind=excluded.kind,amount=excluded.amount,payment_method=excluded.payment_method,
            description=excluded.description,created_at=excluded.created_at
        ''',
          [
            movement['id'],
            session.billarId,
            movement['kind'],
            movement['amount'],
            movement['payment_method'],
            movement['description'],
            movement['created_at'],
          ],
        );
      }
      _require(session);
    });
    return {
      ...result,
      'session': open,
      'summary': summary,
      'sessions': sessions,
      'movements': movements,
    };
  }

  Future<bool> syncMovements(DateTime start, DateTime end) async {
    if (!await AppServices.connectivityService.isOnline) return false;
    int? cursor;
    while (true) {
      final result = await state(start, end, beforeMovement: cursor);
      if (result['more_movements'] != true) return true;
      final rows = result['movements'] as List<Map<String, dynamic>>;
      cursor = rows.last['id'] as int;
    }
  }

  Future<Map<String, Object?>?> pending() async {
    final session = _capture();
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'pending_cash_requests',
      where: 'actor_id = ? AND billar_id = ?',
      whereArgs: [session.actorId, session.billarId],
      limit: 1,
    );
    _require(session);
    return rows.firstOrNull;
  }

  Future<void> _ensureLocalSynced(SyncSession session) async {
    final db = await DatabaseHelper.instance.database;
    for (final table in ['sales_history', 'purchases', 'cash_outflows']) {
      final rows = await db.query(
        table,
        columns: ['id'],
        where:
            'synced = 0 AND ${table == 'purchases' ? purchaseBusinessScope() : 'billar_id = ?'}',
        whereArgs: [session.billarId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        throw StateError(
          'Hay operaciones locales sin sincronizar. Sincronízalas antes de abrir o cerrar caja.',
        );
      }
    }
    for (final table in ['pending_owner_transactions', 'pending_sales']) {
      final rows = await db.query(
        table,
        columns: [table == 'pending_sales' ? 'id' : 'local_id'],
        where:
            'actor_id = ? AND billar_id = ?${table == 'pending_sales' ? ' AND synced = 0' : ''}',
        whereArgs: [session.actorId, session.billarId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        throw StateError(
          'Hay solicitudes de venta/compra pendientes. Resuélvelas antes del turno.',
        );
      }
    }
    _require(session);
  }

  Future<Map<String, dynamic>> _send(
    SyncSession session,
    Map<String, Object?> request, {
    bool cancel = false,
  }) async {
    final db = await DatabaseHelper.instance.database;
    Object? result;
    try {
      result = await _rpc(session, 'cash_shared_apply', {
        'requested_billar_id': session.billarId,
        'requested_id': request['request_id'],
        'operation': cancel ? 'cancel' : request['operation'],
        'payload':
            cancel
                ? <String, Object?>{}
                : jsonDecode(request['payload'] as String),
      });
    } on PostgrestException catch (error) {
      if (const {'22023', '42501', '23514', '23505'}.contains(error.code)) {
        _require(session);
        await db.delete(
          'pending_cash_requests',
          where: 'actor_id = ? AND billar_id = ? AND request_id = ?',
          whereArgs: [session.actorId, session.billarId, request['request_id']],
        );
      }
      rethrow;
    }
    if (result is! Map<String, dynamic> ||
        result['billar_id'] != session.billarId ||
        (result['cancelled'] != true &&
            (result['id'] is! int || result['id'] <= 0))) {
      throw const FormatException(
        'No se pudo confirmar la operación. Revisa la solicitud pendiente antes de repetirla.',
      );
    }
    if (request['operation'] == 'close' && result['cancelled'] != true) {
      _summary(result['summary']);
    }
    _require(session);
    await db.delete(
      'pending_cash_requests',
      where: 'actor_id = ? AND billar_id = ? AND request_id = ?',
      whereArgs: [session.actorId, session.billarId, request['request_id']],
    );
    _require(session);
    return result;
  }

  Future<Map<String, dynamic>> _apply(
    String operation,
    Map<String, Object?> payload,
  ) async {
    final session = _capture();
    if (operation == 'open' || operation == 'close') {
      await _ensureLocalSynced(session);
    }
    final db = await DatabaseHelper.instance.database;
    final request = <String, Object?>{
      'actor_id': session.actorId,
      'billar_id': session.billarId,
      'request_id': newUuidV4(),
      'operation': operation,
      'payload': jsonEncode(payload),
    };
    await db.transaction((txn) async {
      _require(session);
      final previous = await txn.query(
        'pending_cash_requests',
        where: 'actor_id = ? AND billar_id = ?',
        whereArgs: [session.actorId, session.billarId],
        limit: 1,
      );
      if (previous.isNotEmpty) {
        throw StateError(
          'Hay una solicitud pendiente. Reinténtala o cancélala desde Caja antes de registrar otra.',
        );
      }
      await txn.insert('pending_cash_requests', request);
      _require(session);
    });
    return _send(session, request);
  }

  Future<void> resolvePending({required bool cancel}) async {
    final session = _capture();
    final request = await pending();
    if (request == null) throw StateError('No hay solicitudes pendientes.');
    if (!cancel && const {'open', 'close'}.contains(request['operation'])) {
      await _ensureLocalSynced(session);
    }
    await _send(session, request, cancel: cancel);
  }

  @override
  Future<int> openSession({
    required double openingAmount,
    String createdBy = '',
  }) async => (await _apply('open', {'amount': openingAmount}))['id'] as int;

  Future<int> addMovement({
    required int sessionId,
    required String kind,
    required double amount,
    required String description,
    String paymentMethod = 'Efectivo',
  }) async =>
      (await _apply('move', {
            'session_id': sessionId,
            'kind': kind,
            'amount': amount,
            'description': description,
            'payment_method': paymentMethod,
          }))['id']
          as int;

  @override
  Future<Map<String, dynamic>?> getOpenSession() async {
    final now = DateTime.now();
    return (await state(
          DateTime(now.year, now.month, now.day),
          DateTime(now.year, now.month, now.day + 1),
        ))['session']
        as Map<String, dynamic>?;
  }

  @override
  Future<Map<String, double>> getSessionCashFlowSummary(
    Map<String, dynamic> session,
  ) async {
    final now = DateTime.now();
    final result = await state(
      DateTime(now.year, now.month, now.day),
      DateTime(now.year, now.month, now.day + 1),
    );
    final current = result['session'] as Map<String, dynamic>?;
    if (current == null || current['id'] != session['id']) {
      throw StateError('El turno cambió. Actualiza caja.');
    }
    return result['summary'] as Map<String, double>;
  }

  @override
  Future<List<Map<String, dynamic>>> getCashOutflows(
    DateTime start,
    DateTime end,
  ) async {
    final result = await state(
      DateTime(start.year, start.month, start.day),
      DateTime(end.year, end.month, end.day + 1),
    );
    final rows = [...result['movements'] as List<Map<String, dynamic>>];
    var page = result;
    while (page['more_movements'] == true) {
      page = await state(
        DateTime(start.year, start.month, start.day),
        DateTime(end.year, end.month, end.day + 1),
        beforeMovement: rows.last['id'] as int,
      );
      rows.addAll(page['movements'] as List<Map<String, dynamic>>);
    }
    return rows;
  }

  @override
  Future<void> addPartialClosure({
    required double amount,
    String notes = '',
    String createdBy = '',
    int? sessionId,
  }) async {
    if (sessionId == null) {
      throw StateError('Actualiza el turno antes de retirar.');
    }
    await addMovement(
      sessionId: sessionId,
      kind: 'partial',
      amount: amount,
      description: notes.isEmpty ? 'Retiro por corte parcial' : notes,
    );
  }

  @override
  Future<Map<String, double>> closeSession({
    required double closingAmount,
    String closedBy = '',
    int? sessionId,
    double? nextOpeningAmount,
    String? nextCreatedBy,
  }) async {
    if (sessionId == null) {
      throw StateError('Actualiza el turno antes de cerrarlo.');
    }
    final result = await _apply('close', {
      'amount': closingAmount,
      'session_id': sessionId,
      if (nextOpeningAmount != null) 'next_opening': nextOpeningAmount,
    });
    return _summary(result['summary']);
  }
}
