import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database/purchase_scope.dart';
import '../utils/uuid_v4.dart';
import 'sync_session.dart';

typedef OwnerTransactionRequest = ({
  String requestId,
  Map<String, dynamic> payload,
});

class OwnerTransactionOutbox {
  const OwnerTransactionOutbox(this.database, this.requireSession);

  final Database database;
  final void Function(SyncSession) requireSession;

  Future<Map<String, dynamic>> _snapshot(
    Transaction txn,
    SyncSession session,
    String kind,
    int localId,
  ) async {
    final sale = kind == 'sale';
    final table = sale ? 'sales_history' : 'purchases';
    final rows = await txn.query(
      table,
      where: 'id = ? AND ${sale ? 'billar_id = ?' : purchaseBusinessScope()}',
      whereArgs: [localId, session.billarId],
      limit: 1,
    );
    if (rows.length != 1) {
      throw StateError('El registro local no pertenece al billar actual.');
    }
    final row = rows.single;
    final cloudId = row['cloud_id'] as String?;
    final details = await txn.query(
      sale ? 'sale_details' : 'purchase_details',
      where: sale ? 'sale_id = ?' : 'purchase_id = ?',
      whereArgs: [localId],
      orderBy: 'id ASC',
    );
    final header = sale
        ? <String, dynamic>{
            'total': (row['total'] as num).toDouble(),
            'paid': (row['paid'] as num).toDouble(),
            'date': row['date'],
            'type': row['type'],
            'source_module': row['source_module'],
            'payment_method': row['payment_method'],
            'cancelled': row['cancelled'] == 1,
            'customer_key': row['customer_key'],
          }
        : <String, dynamic>{
            'provider_id': row['provider_id'],
            'total': (row['total'] as num).toDouble(),
            'date': row['date'],
            'reference': row['reference'] ?? '',
            'created_by': row['created_by'] ?? '',
            'cash_source': row['payment_condition'] == null
                ? row['cash_source'] ?? 'caja' : row['cash_source'],
            'cancelled': row['cancelled'] == 1,
            if (row['payment_condition'] != null)
              for (final field in [
                'payment_condition', 'payment_method', 'credit_days',
                'due_date', 'paid_amount', 'balance_due',
              ]) field: row[field],
          };
    final items = details.map((item) {
      if (sale) {
        return <String, dynamic>{
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'quantity': (item['quantity'] as num).toDouble(),
          'price_at_sale': (item['price_at_sale'] as num).toDouble(),
          'cost_at_sale': (item['cost_at_sale'] as num?)?.toDouble() ?? 0,
        };
      }
      return <String, dynamic>{
        'product_id': item['product_id'],
        'quantity': (item['quantity'] as num).toDouble(),
        'cost_per_unit': (item['cost_per_unit'] as num).toDouble(),
        'created_by': item['created_by'] ?? header['created_by'],
      };
    }).toList();
    return {
      'p_cloud_id': cloudId == null ? null : int.parse(cloudId),
      sale ? 'p_sale' : 'p_purchase': header,
      'p_details': items,
    };
  }

  Future<OwnerTransactionRequest> prepare({
    required SyncSession session,
    required String kind,
    required int localId,
  }) async {
    if (kind != 'sale' && kind != 'purchase') {
      throw ArgumentError.value(kind, 'kind');
    }
    return database.transaction((txn) async {
      requireSession(session);
      final rows = await txn.query(
        'pending_owner_transactions',
        where: 'kind = ? AND local_id = ?',
        whereArgs: [kind, localId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final row = rows.single;
        if (row['actor_id'] != session.actorId ||
            row['billar_id'] != session.billarId) {
          throw StateError('La operación pendiente pertenece a otra cuenta.');
        }
        final payload = jsonDecode(row['payload'] as String);
        if (payload is! Map<String, dynamic>) {
          throw StateError('La operación pendiente no es válida.');
        }
        await _snapshot(txn, session, kind, localId);
        requireSession(session);
        return (requestId: row['request_id'] as String, payload: payload);
      }
      final payload = await _snapshot(txn, session, kind, localId);
      final requestId = newUuidV4();
      await txn.insert('pending_owner_transactions', {
        'kind': kind,
        'local_id': localId,
        'actor_id': session.actorId,
        'billar_id': session.billarId,
        'request_id': requestId,
        'payload': jsonEncode(payload),
      });
      requireSession(session);
      return (requestId: requestId, payload: payload);
    });
  }

  Future<bool> acknowledge({
    required SyncSession session,
    required String kind,
    required int localId,
    required OwnerTransactionRequest request,
    required String cloudId,
  }) async => database.transaction((txn) async {
    requireSession(session);
    final queued = await txn.query(
      'pending_owner_transactions',
      where: 'kind = ? AND local_id = ? AND actor_id = ? AND billar_id = ? AND request_id = ?',
      whereArgs: [kind, localId, session.actorId, session.billarId, request.requestId],
      limit: 1,
    );
    if (queued.isEmpty || queued.single['payload'] != jsonEncode(request.payload)) {
      throw StateError('La operación pendiente cambió durante la sincronización.');
    }
    final current = await _snapshot(txn, session, kind, localId);
    final currentCloudId = current['p_cloud_id'];
    if (currentCloudId != request.payload['p_cloud_id'] &&
        currentCloudId?.toString() != cloudId) {
      throw StateError('El identificador remoto cambió durante la sincronización.');
    }
    final unchanged = jsonEncode(current) == jsonEncode(request.payload);
    final sale = kind == 'sale';
    final updated = await txn.update(
      sale ? 'sales_history' : 'purchases',
      {'cloud_id': cloudId, 'synced': unchanged ? 1 : 0},
      where: 'id = ? AND ${sale ? 'billar_id = ?' : purchaseBusinessScope()}',
      whereArgs: [localId, session.billarId],
    );
    if (updated != 1) {
      throw StateError('El registro local ya no está disponible.');
    }
    await txn.delete(
      'pending_owner_transactions',
      where: 'kind = ? AND local_id = ? AND request_id = ?',
      whereArgs: [kind, localId, request.requestId],
    );
    requireSession(session);
    return unchanged;
  });
}
