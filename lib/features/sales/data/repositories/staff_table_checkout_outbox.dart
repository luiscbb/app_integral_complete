import 'dart:convert';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import '../../../../core/utils/uuid_v4.dart';
import 'staff_table_checkout_snapshot_repository.dart';

class PendingStaffTableCheckout {
  const PendingStaffTableCheckout({
    required this.requestId,
    required this.serviceId,
    required this.serviceActorId,
    required this.tableId,
    required this.payload,
    required this.receipt,
    required this.localSaleId,
  });

  final String requestId;
  final String serviceId;
  final String serviceActorId;
  final int tableId;
  final Map<String, dynamic> payload;
  final Map<String, dynamic>? receipt;
  final int? localSaleId;
}

class StaffTableCheckoutOutbox {
  const StaffTableCheckoutOutbox(this.database, this.requireSession);

  final Database database;
  final void Function(SyncSession) requireSession;

  PendingStaffTableCheckout _read(Map<String, Object?> row) {
    final payload = jsonDecode(row['payload'] as String);
    final receiptJson = row['receipt'] as String?;
    final receipt = receiptJson == null ? null : jsonDecode(receiptJson);
    final serviceActorId =
        payload is Map<String, dynamic>
            ? payload['expected_service_actor_id'] ?? row['actor_id']
            : null;
    if (payload is! Map<String, dynamic> ||
        serviceActorId is! String ||
        serviceActorId.isEmpty ||
        (receipt != null && receipt is! Map<String, dynamic>)) {
      throw const FormatException('El cobro pendiente guardado no es válido.');
    }
    return PendingStaffTableCheckout(
      requestId: row['request_id'] as String,
      serviceId: row['service_id'] as String,
      serviceActorId: serviceActorId,
      tableId: row['table_id'] as int,
      payload: payload,
      receipt: receipt as Map<String, dynamic>?,
      localSaleId: row['local_sale_id'] as int?,
    );
  }

  Future<List<PendingStaffTableCheckout>> pending(SyncSession session) async {
    requireSession(session);
    final rows = await database.query(
      'staff_table_checkout_outbox',
      where: 'actor_id = ? AND billar_id = ? AND local_sale_id IS NULL',
      whereArgs: [session.actorId, session.billarId],
      orderBy: 'rowid',
    );
    requireSession(session);
    return List.unmodifiable(rows.map(_read));
  }

  Future<PendingStaffTableCheckout?> find(
    SyncSession session,
    String requestId,
  ) async {
    requireSession(session);
    final rows = await database.query(
      'staff_table_checkout_outbox',
      where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
      whereArgs: [requestId, session.actorId, session.billarId],
      limit: 1,
    );
    requireSession(session);
    return rows.isEmpty ? null : _read(rows.single);
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
        'La mesa tiene cambios pendientes de revisión y no se puede cobrar.',
      );
    }
  }

  Future<void> ensureNoTableConflict(SyncSession session, int tableId) async {
    requireSession(session);
    await _ensureNoTableConflict(database, session: session, tableId: tableId);
    requireSession(session);
  }

  Future<PendingStaffTableCheckout> prepare({
    required SyncSession session,
    required StaffTableCheckoutSnapshot snapshot,
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
        snapshot.total <= 0 ||
        snapshot.serviceId.isEmpty ||
        snapshot.actorId.isEmpty ||
        snapshot.tableId <= 0 ||
        !snapshot.timeCost.isFinite ||
        !snapshot.total.isFinite) {
      throw ArgumentError('El pago no cubre el total válido del servicio.');
    }
    final payload = <String, Object>{
      'requested_billar_id': session.billarId,
      'requested_table_type': snapshot.tableType,
      'requested_service_id': snapshot.serviceId,
      'expected_service_actor_id': snapshot.actorId,
      'expected_revision': snapshot.revision,
      'expected_time_cost': snapshot.timeCost,
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
        'staff_table_checkout_outbox',
        where: 'actor_id = ? AND billar_id = ? AND service_id = ?',
        whereArgs: [session.actorId, session.billarId, snapshot.serviceId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final saved = _read(existing.single);
        if (jsonEncode(saved.payload) != encoded) {
          throw StateError('El servicio ya tiene otro cobro pendiente.');
        }
        requireSession(session);
        return saved;
      }
      final pendingRows = await txn.query(
        'staff_table_checkout_outbox',
        columns: ['request_id'],
        where: 'actor_id = ? AND billar_id = ? AND local_sale_id IS NULL',
        whereArgs: [session.actorId, session.billarId],
        limit: 1,
      );
      if (pendingRows.isNotEmpty) {
        throw StateError('Hay un cobro incierto que debe recuperarse primero.');
      }
      if (snapshot.actorId == session.actorId) {
        final drafts = await txn.query(
          'staff_table_service_drafts',
          where:
              'service_id = ? AND actor_id = ? AND billar_id = ? AND state = ?',
          whereArgs: [
            snapshot.serviceId,
            session.actorId,
            session.billarId,
            'active',
          ],
          limit: 1,
        );
        if (drafts.length != 1 ||
            drafts.single['table_id'] != snapshot.tableId ||
            drafts.single['table_type'] != snapshot.tableType) {
          throw StateError(
            'El servicio local no coincide con la consulta de cobro.',
          );
        }
        final localItems = await txn.query(
          'staff_table_service_consumptions',
          where: 'service_id = ? AND actor_id = ? AND billar_id = ?',
          whereArgs: [snapshot.serviceId, session.actorId, session.billarId],
          orderBy: 'sequence',
        );
        final confirmed = localItems.where((row) => row['late'] != 1).toList();
        if (confirmed.length != snapshot.items.length ||
            confirmed.any((row) => row['confirmed'] != 1 || row['late'] == 1) ||
            snapshot.items.any(
              (item) =>
                  !confirmed.any(
                    (row) =>
                        row['request_id'] == item.requestId &&
                        row['product_id'] == item.productId &&
                        row['product_name'] == item.productName &&
                        (row['quantity'] as num).toDouble() == item.quantity &&
                        (row['price'] as num).toDouble() == item.price,
                  ),
            )) {
          throw StateError(
            'Sincroniza y revisa todos los consumos antes de cobrar.',
          );
        }
      }
      final requestId = newUuidV4();
      final row = <String, Object?>{
        'request_id': requestId,
        'actor_id': session.actorId,
        'billar_id': session.billarId,
        'service_id': snapshot.serviceId,
        'table_id': snapshot.tableId,
        'payload': encoded,
      };
      await txn.insert('staff_table_checkout_outbox', row);
      requireSession(session);
      return _read(row);
    });
  }

  Future<PendingStaffTableCheckout> saveReceipt({
    required SyncSession session,
    required PendingStaffTableCheckout request,
    required Map<dynamic, dynamic> receipt,
  }) async {
    _validateReceipt(session, request, receipt);
    final encoded = jsonEncode(receipt);
    return database.transaction((txn) async {
      requireSession(session);
      final rows = await txn.query(
        'staff_table_checkout_outbox',
        where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [request.requestId, session.actorId, session.billarId],
        limit: 1,
      );
      if (rows.length != 1 ||
          rows.single['payload'] != jsonEncode(request.payload) ||
          (rows.single['receipt'] != null &&
              rows.single['receipt'] != encoded)) {
        throw StateError('La solicitud o respuesta de cobro cambió.');
      }
      await txn.update(
        'staff_table_checkout_outbox',
        {'receipt': encoded},
        where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [request.requestId, session.actorId, session.billarId],
      );
      requireSession(session);
      return _read({...rows.single, 'receipt': encoded});
    });
  }

  Future<void> discardRejected({
    required SyncSession session,
    required String requestId,
    required String code,
  }) async {
    if (!const {'PST02', 'PST03', '22023', '42501', '55000'}.contains(code)) {
      throw ArgumentError('La respuesta no confirma el rechazo del cobro.');
    }
    requireSession(session);
    await database.delete(
      'staff_table_checkout_outbox',
      where:
          'request_id = ? AND actor_id = ? AND billar_id = ? AND receipt IS NULL AND local_sale_id IS NULL',
      whereArgs: [requestId, session.actorId, session.billarId],
    );
    requireSession(session);
  }

  void _validateReceipt(
    SyncSession session,
    PendingStaffTableCheckout request,
    Map<dynamic, dynamic> receipt,
  ) {
    final saleId = receipt['sale_id'];
    final total = receipt['total'];
    final expectedTotal = request.payload['expected_total'];
    final paid = receipt['paid'];
    final date = receipt['date'];
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
        date is! String ||
        DateTime.tryParse(date) == null ||
        (receipt['table_type'] != 'Billar' &&
            receipt['table_type'] != 'Comanda') ||
        items is! List ||
        movements is! List ||
        stock is! List ||
        items.isEmpty) {
      throw const FormatException('La respuesta del cobro no es válida.');
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
        throw const FormatException('Los detalles confirmados no son válidos.');
      }
      final productId = item['product_id'];
      if (productId != null && (productId is! int || productId <= 0)) {
        throw const FormatException('El producto confirmado no es válido.');
      }
      calculatedTotal +=
          (item['quantity'] as num).toDouble() *
          (item['price_at_sale'] as num).toDouble();
    }
    if (!calculatedTotal.isFinite ||
        (calculatedTotal - total.toDouble()).abs() >
            math.max(0.000001, calculatedTotal.abs() * 0.0000000001)) {
      throw const FormatException(
        'El total confirmado no coincide con los detalles.',
      );
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
          movement['unit_price'] is! num) {
        throw const FormatException(
          'Los movimientos confirmados no son válidos.',
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
          'La fotografía del inventario no es válida.',
        );
      }
    }
  }

  Future<PendingStaffTableCheckout> applyReceipt({
    required SyncSession session,
    required PendingStaffTableCheckout request,
  }) async {
    final receipt = request.receipt;
    if (receipt == null) {
      throw StateError('El cobro todavía no tiene confirmación del servidor.');
    }
    _validateReceipt(session, request, receipt);
    return database.transaction((txn) async {
      requireSession(session);
      final rows = await txn.query(
        'staff_table_checkout_outbox',
        where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [request.requestId, session.actorId, session.billarId],
        limit: 1,
      );
      if (rows.length != 1 || rows.single['receipt'] != jsonEncode(receipt)) {
        throw StateError('El recibo pendiente cambió durante la recuperación.');
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
            'La venta local no coincide con el recibo del servidor.',
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
      if (request.serviceActorId == session.actorId) {
        final draft = await txn.query(
          'staff_table_service_drafts',
          where: 'service_id = ? AND actor_id = ? AND billar_id = ?',
          whereArgs: [request.serviceId, session.actorId, session.billarId],
          limit: 1,
        );
        if (draft.length != 1 ||
            draft.single['state'] != 'active' ||
            draft.single['table_id'] != receipt['table_id'] ||
            draft.single['table_type'] != receipt['table_type']) {
          throw StateError(
            'El servicio local cambió antes de aplicar el recibo.',
          );
        }
        await txn.update(
          'staff_table_service_drafts',
          {'state': 'closed'},
          where: 'service_id = ? AND actor_id = ? AND billar_id = ?',
          whereArgs: [request.serviceId, session.actorId, session.billarId],
        );
        final pendingConsumptions = await txn.query(
          'staff_table_service_consumptions',
          columns: ['request_id'],
          where:
              'service_id = ? AND actor_id = ? AND billar_id = ? AND confirmed = 0',
          whereArgs: [request.serviceId, session.actorId, session.billarId],
          limit: 1,
        );
        if (pendingConsumptions.isNotEmpty) {
          throw StateError(
            'Quedaron consumos sin confirmar; revisa el servicio.',
          );
        }
      } else {
        final drafts = await txn.query(
          'staff_table_service_drafts',
          where: 'service_id = ? AND billar_id = ? AND actor_id = ?',
          whereArgs: [request.serviceId, session.billarId, session.actorId],
          limit: 1,
        );
        if (drafts.isNotEmpty) {
          throw StateError(
            'El servicio de otro personal tiene un borrador local inesperado.',
          );
        }
      }
      await txn.update(
        'staff_table_checkout_outbox',
        {'local_sale_id': localSaleId},
        where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [request.requestId, session.actorId, session.billarId],
      );
      requireSession(session);
      return _read({...rows.single, 'local_sale_id': localSaleId});
    });
  }
}

class StaffTableCheckoutSender {
  const StaffTableCheckoutSender(this.client, this.outbox);

  final SupabaseClient client;
  final StaffTableCheckoutOutbox outbox;

  Future<PendingStaffTableCheckout> send({
    required SyncSession session,
    required PendingStaffTableCheckout request,
  }) async {
    var pending = await outbox.find(session, request.requestId);
    if (pending == null) {
      throw StateError('El cobro pendiente no está disponible.');
    }
    if (jsonEncode(pending.payload) != jsonEncode(request.payload)) {
      throw StateError('El contenido del cobro pendiente cambió.');
    }
    if (pending.localSaleId != null) return pending;
    await outbox.ensureNoTableConflict(session, pending.tableId);
    if (pending.receipt == null) {
      outbox.requireSession(session);
      final remotePayload = Map<String, dynamic>.from(pending.payload)
        ..remove('expected_service_actor_id');
      dynamic response;
      try {
        response = await client
            .rpc(
              'staff_table_checkout',
              params: {
                'requested_request_id': pending.requestId,
                ...remotePayload,
              },
            )
            .setHeader('Authorization', 'Bearer ${session.token}');
      } on PostgrestException catch (error) {
        if (const {
          'PST02',
          'PST03',
          '22023',
          '42501',
          '55000',
        }.contains(error.code)) {
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
        throw const FormatException('La respuesta del cobro no es válida.');
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
