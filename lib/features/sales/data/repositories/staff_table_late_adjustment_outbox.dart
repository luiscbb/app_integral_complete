import 'dart:convert';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import '../../../../core/utils/uuid_v4.dart';
import 'staff_table_late_adjustment_snapshot_repository.dart';

class PendingStaffTableLateAdjustment {
  const PendingStaffTableLateAdjustment({
    required this.requestId,
    required this.serviceId,
    required this.tableId,
    required this.payload,
    required this.receipt,
    required this.localSaleId,
  });

  final String requestId;
  final String serviceId;
  final int tableId;
  final Map<String, dynamic> payload;
  final Map<String, dynamic>? receipt;
  final int? localSaleId;
}

class StaffTableLateAdjustmentOutbox {
  const StaffTableLateAdjustmentOutbox(this.database, this.requireSession);

  final Database database;
  final void Function(SyncSession) requireSession;

  PendingStaffTableLateAdjustment _read(Map<String, Object?> row) {
    final payload = jsonDecode(row['payload'] as String);
    final receiptJson = row['receipt'] as String?;
    final receipt = receiptJson == null ? null : jsonDecode(receiptJson);
    if (payload is! Map<String, dynamic> ||
        (receipt != null && receipt is! Map<String, dynamic>)) {
      throw const FormatException(
        'El ajuste tardío pendiente guardado no es válido.',
      );
    }
    return PendingStaffTableLateAdjustment(
      requestId: row['request_id'] as String,
      serviceId: row['service_id'] as String,
      tableId: row['table_id'] as int,
      payload: payload,
      receipt: receipt as Map<String, dynamic>?,
      localSaleId: row['local_sale_id'] as int?,
    );
  }

  Future<PendingStaffTableLateAdjustment?> pendingForService({
    required SyncSession session,
    required String serviceId,
  }) async {
    requireSession(session);
    final rows = await database.query(
      'staff_table_late_adjustment_outbox',
      where:
          'actor_id = ? AND billar_id = ? AND service_id = ? AND local_sale_id IS NULL',
      whereArgs: [session.actorId, session.billarId, serviceId],
      limit: 1,
    );
    requireSession(session);
    return rows.isEmpty ? null : _read(rows.single);
  }

  Future<List<PendingStaffTableLateAdjustment>> pending(
    SyncSession session,
  ) async {
    requireSession(session);
    final rows = await database.query(
      'staff_table_late_adjustment_outbox',
      where: 'actor_id = ? AND billar_id = ? AND local_sale_id IS NULL',
      whereArgs: [session.actorId, session.billarId],
      orderBy: 'rowid',
    );
    requireSession(session);
    return List.unmodifiable(rows.map(_read));
  }

  Future<void> _ensureNoTableConflict(
    DatabaseExecutor executor, {
    required SyncSession session,
    required int tableId,
  }) async {
    final conflicts = await executor.query(
      'table_sync_conflicts',
      columns: ['id'],
      where: 'billar_id = ? AND table_id = ?',
      whereArgs: [session.billarId, tableId],
      limit: 1,
    );
    if (conflicts.isNotEmpty) {
      throw StateError(
        'La mesa tiene cambios pendientes de revisión y no se puede ajustar.',
      );
    }
  }

  Future<void> ensureNoTableConflict(SyncSession session, int tableId) async {
    requireSession(session);
    await _ensureNoTableConflict(database, session: session, tableId: tableId);
    requireSession(session);
  }

  Future<PendingStaffTableLateAdjustment> prepare({
    required SyncSession session,
    required StaffTableLateAdjustmentSnapshot snapshot,
    required String paymentMethod,
    required double paid,
  }) async {
    if (!const {
          'Efectivo',
          'Tarjeta',
          'Transferencia',
        }.contains(paymentMethod) ||
        !paid.isFinite ||
        paid < snapshot.total ||
        (snapshot.tableType != 'Billar' && snapshot.tableType != 'Comanda') ||
        snapshot.total <= 0 ||
        snapshot.revision <= 0 ||
        snapshot.serviceId.isEmpty ||
        snapshot.tableId <= 0 ||
        !snapshot.total.isFinite ||
        snapshot.items.isEmpty) {
      throw ArgumentError('El pago no cubre el total válido del ajuste.');
    }
    final payload = <String, Object>{
      'requested_billar_id': session.billarId,
      'requested_table_type': snapshot.tableType,
      'requested_service_id': snapshot.serviceId,
      'expected_revision': snapshot.revision,
      'expected_total': snapshot.total,
      'payment_method': paymentMethod,
      'paid': paid,
    };
    final encoded = jsonEncode(payload);
    return database.transaction((txn) async {
      requireSession(session);
      await _ensureNoTableConflict(
        txn,
        session: session,
        tableId: snapshot.tableId,
      );
      final existing = await txn.query(
        'staff_table_late_adjustment_outbox',
        where:
            'actor_id = ? AND billar_id = ? AND service_id = ? AND local_sale_id IS NULL',
        whereArgs: [session.actorId, session.billarId, snapshot.serviceId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final saved = _read(existing.single);
        if (jsonEncode(saved.payload) != encoded) {
          throw StateError(
            'El servicio ya tiene otro ajuste pendiente de recuperar.',
          );
        }
        requireSession(session);
        return saved;
      }
      final pendingRows = await txn.query(
        'staff_table_late_adjustment_outbox',
        columns: ['request_id'],
        where: 'actor_id = ? AND billar_id = ? AND local_sale_id IS NULL',
        whereArgs: [session.actorId, session.billarId],
        limit: 1,
      );
      if (pendingRows.isNotEmpty) {
        throw StateError(
          'Hay un ajuste incierto que debe recuperarse primero.',
        );
      }
      final row = <String, Object?>{
        'request_id': newUuidV4(),
        'actor_id': session.actorId,
        'billar_id': session.billarId,
        'service_id': snapshot.serviceId,
        'table_id': snapshot.tableId,
        'payload': encoded,
      };
      await txn.insert('staff_table_late_adjustment_outbox', row);
      requireSession(session);
      return _read(row);
    });
  }

  Future<void> discardRejected({
    required SyncSession session,
    required String requestId,
    required String code,
  }) async {
    if (!const {'PST02', '22023', '42501', '55000'}.contains(code)) {
      throw ArgumentError('La respuesta no confirma el rechazo del ajuste.');
    }
    requireSession(session);
    await database.delete(
      'staff_table_late_adjustment_outbox',
      where:
          'request_id = ? AND actor_id = ? AND billar_id = ? AND receipt IS NULL AND local_sale_id IS NULL',
      whereArgs: [requestId, session.actorId, session.billarId],
    );
    requireSession(session);
  }

  Future<PendingStaffTableLateAdjustment> saveReceipt({
    required SyncSession session,
    required PendingStaffTableLateAdjustment request,
    required Map<dynamic, dynamic> receipt,
  }) async {
    _validateReceipt(session, request, receipt);
    final encoded = jsonEncode(receipt);
    return database.transaction((txn) async {
      requireSession(session);
      final rows = await txn.query(
        'staff_table_late_adjustment_outbox',
        where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [request.requestId, session.actorId, session.billarId],
        limit: 1,
      );
      if (rows.length != 1 ||
          rows.single['payload'] != jsonEncode(request.payload) ||
          (rows.single['receipt'] != null &&
              rows.single['receipt'] != encoded)) {
        throw StateError('La solicitud o respuesta del ajuste cambió.');
      }
      await txn.update(
        'staff_table_late_adjustment_outbox',
        {'receipt': encoded},
        where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [request.requestId, session.actorId, session.billarId],
      );
      requireSession(session);
      return _read({...rows.single, 'receipt': encoded});
    });
  }

  void _validateReceipt(
    SyncSession session,
    PendingStaffTableLateAdjustment request,
    Map<dynamic, dynamic> receipt,
  ) {
    final saleId = receipt['sale_id'];
    final total = receipt['total'];
    final expectedTotal = request.payload['expected_total'];
    final paid = receipt['paid'];
    final items = receipt['items'];
    final movements = receipt['movements'];
    final stock = receipt['stock'];
    if (receipt['request_id'] != request.requestId ||
        receipt['billar_id'] != session.billarId ||
        receipt['service_id'] != request.serviceId ||
        receipt['table_id'] != request.tableId ||
        receipt['table_type'] != request.payload['requested_table_type'] ||
        saleId is! int ||
        saleId <= 0 ||
        total is! num ||
        !total.isFinite ||
        expectedTotal is! num ||
        !expectedTotal.isFinite ||
        (total.toDouble() - expectedTotal.toDouble()).abs() >
            math.max(0.000001, expectedTotal.toDouble().abs() * 0.0000000001) ||
        paid is! num ||
        !paid.isFinite ||
        paid < total ||
        paid != request.payload['paid'] ||
        receipt['payment_method'] != request.payload['payment_method'] ||
        receipt['sale_type'] is! String ||
        (receipt['sale_type'] as String).trim().isEmpty ||
        receipt['date'] is! String ||
        DateTime.tryParse(receipt['date'] as String) == null ||
        (receipt['table_type'] != 'Billar' &&
            receipt['table_type'] != 'Comanda') ||
        items is! List ||
        items.isEmpty ||
        movements is! List ||
        stock is! List) {
      throw const FormatException('El recibo del ajuste no es válido.');
    }
    var calculatedTotal = 0.0;
    for (final item in items) {
      if (item is! Map ||
          item['product_name'] is! String ||
          (item['product_name'] as String).trim().isEmpty ||
          item['quantity'] is! num ||
          !(item['quantity'] as num).isFinite ||
          (item['quantity'] as num) <= 0 ||
          item['price_at_sale'] is! num ||
          !(item['price_at_sale'] as num).isFinite ||
          (item['price_at_sale'] as num) < 0 ||
          item['cost_at_sale'] is! num ||
          !(item['cost_at_sale'] as num).isFinite ||
          (item['cost_at_sale'] as num) < 0) {
        throw const FormatException('Los detalles del ajuste no son válidos.');
      }
      final productId = item['product_id'];
      if (productId != null && (productId is! int || productId <= 0)) {
        throw const FormatException('El producto del ajuste no es válido.');
      }
      calculatedTotal +=
          (item['quantity'] as num).toDouble() *
          (item['price_at_sale'] as num).toDouble();
    }
    if (!calculatedTotal.isFinite ||
        (calculatedTotal - total.toDouble()).abs() >
            math.max(0.000001, calculatedTotal.abs() * 0.0000000001)) {
      throw const FormatException('El total del ajuste no coincide.');
    }
    final movementIds = <int>{};
    for (final movement in movements) {
      if (movement is! Map ||
          movement['cloud_id'] is! int ||
          (movement['cloud_id'] as int) <= 0 ||
          !movementIds.add(movement['cloud_id'] as int) ||
          movement['product_id'] is! int ||
          (movement['product_id'] as int) <= 0 ||
          movement['quantity'] is! num ||
          !(movement['quantity'] as num).isFinite ||
          (movement['quantity'] as num) >= 0 ||
          movement['unit_cost'] is! num ||
          !(movement['unit_cost'] as num).isFinite ||
          movement['unit_price'] is! num ||
          !(movement['unit_price'] as num).isFinite) {
        throw const FormatException(
          'Los movimientos del ajuste no son válidos.',
        );
      }
    }
    final stockIds = <int>{};
    for (final row in stock) {
      if (row is! Map ||
          row['product_id'] is! int ||
          (row['product_id'] as int) <= 0 ||
          !stockIds.add(row['product_id'] as int) ||
          row['stock'] is! num ||
          !(row['stock'] as num).isFinite ||
          row['stock_revision'] is! int ||
          (row['stock_revision'] as int) < 0 ||
          row['previous_revision'] is! int ||
          (row['previous_revision'] as int) < 0 ||
          (row['stock_revision'] as int) <= (row['previous_revision'] as int)) {
        throw const FormatException(
          'La fotografía del inventario del ajuste no es válida.',
        );
      }
    }
  }

  Future<PendingStaffTableLateAdjustment> applyReceipt({
    required SyncSession session,
    required PendingStaffTableLateAdjustment request,
  }) async {
    final receipt = request.receipt;
    if (receipt == null) {
      throw StateError('El ajuste todavía no tiene confirmación del servidor.');
    }
    _validateReceipt(session, request, receipt);
    return database.transaction((txn) async {
      requireSession(session);
      final rows = await txn.query(
        'staff_table_late_adjustment_outbox',
        where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [request.requestId, session.actorId, session.billarId],
        limit: 1,
      );
      if (rows.length != 1 || rows.single['receipt'] != jsonEncode(receipt)) {
        throw StateError('El recibo pendiente del ajuste cambió.');
      }
      final saved = _read(rows.single);
      if (saved.localSaleId != null) return saved;
      await _ensureNoTableConflict(
        txn,
        session: session,
        tableId: request.tableId,
      );
      final cloudId = '${receipt['sale_id']}';
      final existing = await txn.query(
        'sales_history',
        where: 'cloud_id = ? AND billar_id = ?',
        whereArgs: [cloudId, session.billarId],
        limit: 1,
      );
      int localSaleId;
      if (existing.isEmpty) {
        localSaleId = await txn.insert('sales_history', {
          'billar_id': session.billarId,
          'total': receipt['total'],
          'paid': receipt['paid'],
          'date': receipt['date'],
          'type': receipt['sale_type'],
          'source_module':
              receipt['table_type'] == 'Comanda'
                  ? 'dine_in'
                  : 'billiard_tables',
          'payment_method': receipt['payment_method'],
          'cancelled': 0,
          'synced': 1,
          'cloud_id': cloudId,
        });
        for (final raw in receipt['items'] as List) {
          final item = Map<String, dynamic>.from(raw as Map);
          await txn.insert('sale_details', {
            'sale_id': localSaleId,
            'product_id': item['product_id'],
            'product_name': item['product_name'],
            'quantity': item['quantity'],
            'price_at_sale': item['price_at_sale'],
            'cost_at_sale': item['cost_at_sale'],
            'cost_available': 1,
            'cancelled': 0,
          });
        }
      } else {
        if (existing.single['total'] != receipt['total'] ||
            existing.single['paid'] != receipt['paid'] ||
            existing.single['cancelled'] == 1) {
          throw StateError(
            'La venta local no coincide con el recibo del ajuste.',
          );
        }
        localSaleId = existing.single['id'] as int;
      }
      for (final raw in receipt['movements'] as List) {
        final movement = Map<String, dynamic>.from(raw as Map);
        final duplicate = await txn.query(
          'inventory_movements',
          where: 'cloud_id = ? AND billar_id = ?',
          whereArgs: ['${movement['cloud_id']}', session.billarId],
          limit: 1,
        );
        if (duplicate.isEmpty) {
          await txn.insert('inventory_movements', {
            'billar_id': session.billarId,
            'product_id': movement['product_id'],
            'movement_type': 'sale',
            'quantity': movement['quantity'],
            'unit_cost': movement['unit_cost'],
            'unit_price': movement['unit_price'],
            'reference_id': localSaleId,
            'reference_type': 'sales_history',
            'notes': movement['notes'],
            'synced': 1,
            'cloud_id': '${movement['cloud_id']}',
          });
        }
      }
      for (final raw in receipt['stock'] as List) {
        final stock = Map<String, dynamic>.from(raw as Map);
        final products = await txn.query(
          'products',
          columns: ['stock_revision', 'synced', 'stock_conflict'],
          where: 'id = ? AND billar_id = ?',
          whereArgs: [stock['product_id'], session.billarId],
          limit: 1,
        );
        if (products.length != 1) continue;
        if (products.single['synced'] == 1 &&
            products.single['stock_conflict'] == 0 &&
            products.single['stock_revision'] == stock['previous_revision']) {
          await txn.update(
            'products',
            {
              'stock': stock['stock'],
              'stock_revision': stock['stock_revision'],
              'synced': 1,
            },
            where: 'id = ? AND billar_id = ?',
            whereArgs: [stock['product_id'], session.billarId],
          );
        } else {
          await txn.update(
            'products',
            {'stock_conflict': 1},
            where: 'id = ? AND billar_id = ?',
            whereArgs: [stock['product_id'], session.billarId],
          );
        }
      }
      await txn.update(
        'staff_table_late_adjustment_outbox',
        {'local_sale_id': localSaleId},
        where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [request.requestId, session.actorId, session.billarId],
      );
      requireSession(session);
      return _read({...rows.single, 'local_sale_id': localSaleId});
    });
  }
}

class StaffTableLateAdjustmentSender {
  const StaffTableLateAdjustmentSender(this.client, this.outbox);

  final SupabaseClient client;
  final StaffTableLateAdjustmentOutbox outbox;

  Future<PendingStaffTableLateAdjustment> send({
    required SyncSession session,
    required PendingStaffTableLateAdjustment request,
  }) async {
    var pending = await outbox.pendingForService(
      session: session,
      serviceId: request.serviceId,
    );
    if (pending == null || pending.requestId != request.requestId) {
      throw StateError('El ajuste pendiente no está disponible.');
    }
    if (jsonEncode(pending.payload) != jsonEncode(request.payload)) {
      throw StateError('El contenido del ajuste pendiente cambió.');
    }
    if (pending.localSaleId != null) return pending;
    await outbox.ensureNoTableConflict(session, pending.tableId);
    if (pending.receipt == null) {
      outbox.requireSession(session);
      dynamic response;
      try {
        response = await client
            .rpc(
              'staff_table_adjust_late_consumptions',
              params: {
                'requested_request_id': pending.requestId,
                ...pending.payload,
              },
            )
            .setHeader('Authorization', 'Bearer ${session.token}');
      } on PostgrestException catch (error) {
        if (const {'PST02', '22023', '42501', '55000'}.contains(error.code)) {
          await outbox.discardRejected(
            session: session,
            requestId: pending.requestId,
            code: error.code!,
          );
        }
        rethrow;
      }
      outbox.requireSession(session);
      if (response is! Map) {
        throw const FormatException('La respuesta del ajuste no es válida.');
      }
      pending = await outbox.saveReceipt(
        session: session,
        request: pending,
        receipt: response,
      );
    }
    return outbox.applyReceipt(session: session, request: pending);
  }
}
