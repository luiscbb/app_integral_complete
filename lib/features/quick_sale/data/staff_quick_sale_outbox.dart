import 'dart:convert';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/sync_session.dart';
import '../../../core/utils/uuid_v4.dart';
import 'staff_sale_cache.dart';

Future<List<Map<String, Object?>>> quickSaleReservations(
  DatabaseExecutor db,
  String billarId,
) => db.rawQuery(
  '''
  SELECT r.id, r.source_id, r.source_key, r.product_id, r.quantity, r.created_at
  FROM temp_reservations r
  JOIN products p ON p.id = r.product_id
  WHERE r.source = ? AND p.billar_id = ?
  ORDER BY r.id
''',
  ['quick_sale', billarId],
);

class StaffQuickSaleItem {
  const StaffQuickSaleItem({
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.price,
  });

  final int productId;
  final String productName;
  final double quantity;
  final double price;

  Map<String, Object> toJson() => {
    'product_id': productId,
    'product_name': productName,
    'quantity': quantity,
    'price_at_sale': price,
  };
}

class PendingStaffQuickSale {
  const PendingStaffQuickSale({
    required this.requestId,
    required this.payload,
    required this.remoteSaleId,
    required this.reservationSnapshot,
  });

  final String requestId;
  final Map<String, dynamic> payload;
  final int? remoteSaleId;
  final String? reservationSnapshot;
}

class StaffQuickSaleOutbox {
  const StaffQuickSaleOutbox(this.database, this.requireSession) : cache = null;

  StaffQuickSaleOutbox.staffCache(StaffSaleCache staffCache)
    : database = staffCache.database,
      requireSession = staffCache.requireSession,
      cache = staffCache;

  final Database database;
  final void Function(SyncSession) requireSession;
  final StaffSaleCache? cache;

  Future<List<Map<String, Object?>>> reservations(
    DatabaseExecutor db,
    SyncSession session,
  ) =>
      cache?.reservations(db, session) ??
      quickSaleReservations(db, session.billarId);

  PendingStaffQuickSale _read(Map<String, Object?> row) {
    final payload = jsonDecode(row['payload'] as String);
    if (payload is! Map<String, dynamic>) {
      throw StateError('La solicitud de venta pendiente no es válida.');
    }

    return PendingStaffQuickSale(
      requestId: row['request_id'] as String,
      payload: payload,
      remoteSaleId: row['remote_sale_id'] as int?,
      reservationSnapshot: row['reservation_snapshot'] as String?,
    );
  }

  Future<PendingStaffQuickSale?> pending(SyncSession session) async {
    requireSession(session);
    final rows = await database.query(
      'pending_staff_sales',
      where: 'actor_id = ? AND billar_id = ?',
      whereArgs: [session.actorId, session.billarId],
      limit: 1,
    );
    requireSession(session);
    return rows.isEmpty ? null : _read(rows.single);
  }

  Future<PendingStaffQuickSale> prepare({
    required SyncSession session,
    required String saleDate,
    required String paymentMethod,
    required double total,
    required double paid,
    required List<StaffQuickSaleItem> items,
  }) async {
    if (session.actorId.trim().isEmpty ||
        session.billarId.trim().isEmpty ||
        saleDate.trim().isEmpty ||
        paymentMethod.trim().isEmpty ||
        !total.isFinite ||
        total < 0 ||
        !paid.isFinite ||
        paid < 0 ||
        items.isEmpty ||
        items.any(
          (item) =>
              item.productId <= 0 ||
              item.productName.trim().isEmpty ||
              !item.quantity.isFinite ||
              item.quantity <= 0 ||
              !item.price.isFinite ||
              item.price < 0,
        )) {
      throw ArgumentError('Los datos de la venta no son válidos.');
    }
    final calculatedTotal = items.fold<double>(
      0,
      (sum, item) => sum + item.quantity * item.price,
    );
    if (!calculatedTotal.isFinite ||
        (calculatedTotal - total).abs() >
            math.max(0.000001, calculatedTotal.abs() * 0.0000000001)) {
      throw ArgumentError('El total no coincide con los detalles de la venta.');
    }
    final payload = <String, Object?>{
      'p_source_module': 'quick_sale',
      'p_sale_type': 'Venta Rápida',
      'p_sale_date': saleDate,
      'p_payment_method': paymentMethod,
      'p_total': total,
      'p_paid': paid,
      'p_customer_key': null,
      'p_items': items.map((item) => item.toJson()).toList(),
    };
    final encoded = jsonEncode(payload);
    return database.transaction((txn) async {
      requireSession(session);
      final rows = await txn.query(
        'pending_staff_sales',
        where: 'actor_id = ? AND billar_id = ?',
        whereArgs: [session.actorId, session.billarId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        if (rows.single['payload'] != encoded) {
          throw StateError(
            'Hay una venta pendiente que debe recuperarse antes de cobrar otra.',
          );
        }
        requireSession(session);
        return _read(rows.single);
      }
      final requestId = newUuidV4();
      final reservations = await this.reservations(txn, session);
      final reserved = <int, double>{};
      for (final row in reservations) {
        final id = row['product_id'] as int;
        final quantity = (row['quantity'] as num).toDouble();
        if (!quantity.isFinite || quantity <= 0) {
          throw StateError('La reserva de venta rápida no es válida.');
        }
        reserved[id] = (reserved[id] ?? 0) + quantity;
      }
      final requested = <int, double>{};
      for (final item in items) {
        requested[item.productId] =
            (requested[item.productId] ?? 0) + item.quantity;
      }
      if (reserved.length != requested.length ||
          requested.entries.any(
            (entry) => reserved[entry.key] != entry.value,
          )) {
        throw StateError(
          'El carrito cambió; guarda la reserva antes de cobrar.',
        );
      }
      await txn.insert('pending_staff_sales', {
        'actor_id': session.actorId,
        'billar_id': session.billarId,
        'request_id': requestId,
        'payload': encoded,
        'reservation_snapshot': jsonEncode(reservations),
      });
      requireSession(session);
      return PendingStaffQuickSale(
        requestId: requestId,
        payload: Map<String, dynamic>.from(payload),
        remoteSaleId: null,
        reservationSnapshot: jsonEncode(reservations),
      );
    });
  }

  Future<void> acknowledge({
    required SyncSession session,
    required PendingStaffQuickSale request,
    required int remoteSaleId,
  }) async {
    if (remoteSaleId <= 0) {
      throw ArgumentError.value(remoteSaleId, 'remoteSaleId');
    }
    await database.transaction((txn) async {
      requireSession(session);
      final rows = await txn.query(
        'pending_staff_sales',
        where: 'actor_id = ? AND billar_id = ? AND request_id = ?',
        whereArgs: [session.actorId, session.billarId, request.requestId],
        limit: 1,
      );
      if (rows.length != 1 ||
          rows.single['payload'] != jsonEncode(request.payload) ||
          (rows.single['remote_sale_id'] != null &&
              rows.single['remote_sale_id'] != remoteSaleId)) {
        throw StateError('La venta pendiente cambió durante la operación.');
      }
      await txn.update(
        'pending_staff_sales',
        {'remote_sale_id': remoteSaleId},
        where: 'actor_id = ? AND billar_id = ? AND request_id = ?',
        whereArgs: [session.actorId, session.billarId, request.requestId],
      );
      requireSession(session);
    });
  }
}

class StaffQuickSaleSender {
  const StaffQuickSaleSender(this.client, this.outbox);

  final SupabaseClient client;
  final StaffQuickSaleOutbox outbox;

  Future<int> send({
    required SyncSession session,
    required PendingStaffQuickSale request,
  }) async {
    final queued = await outbox.pending(session);
    if (queued == null ||
        queued.requestId != request.requestId ||
        jsonEncode(queued.payload) != jsonEncode(request.payload)) {
      throw StateError('La venta pendiente cambió durante la operación.');
    }
    if (queued.remoteSaleId != null) return queued.remoteSaleId!;
    if (queued.reservationSnapshot == null) {
      throw StateError(
        'La reserva anterior requiere revisión antes de enviar la venta.',
      );
    }
    final reservations = await outbox.reservations(outbox.database, session);
    outbox.requireSession(session);
    if (jsonEncode(reservations) != queued.reservationSnapshot) {
      throw StateError(
        'La reserva del carrito cambió antes de enviar la venta.',
      );
    }
    outbox.requireSession(session);
    final result = await client
        .rpc(
          'record_staff_sale',
          params: {
            'p_request_id': queued.requestId,
            'p_billar_id': session.billarId,
            ...queued.payload,
          },
        )
        .setHeader('Authorization', 'Bearer ${session.token}');
    outbox.requireSession(session);
    if (result is! int || result <= 0) {
      throw StateError('La respuesta de la venta no es válida.');
    }
    await outbox.acknowledge(
      session: session,
      request: queued,
      remoteSaleId: result,
    );
    return result;
  }
}
