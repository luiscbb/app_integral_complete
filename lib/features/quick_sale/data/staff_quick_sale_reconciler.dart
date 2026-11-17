import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/sync_session.dart';
import 'staff_quick_sale_outbox.dart';

class StaffQuickSaleReconciler {
  const StaffQuickSaleReconciler(this.client, this.outbox);

  final SupabaseClient client;
  final StaffQuickSaleOutbox outbox;

  Future<int?> _completed(
    DatabaseExecutor db,
    SyncSession session,
    PendingStaffQuickSale request,
  ) async {
    final rows = await db.query(
      'reconciled_staff_sales',
      where: 'actor_id = ? AND billar_id = ? AND request_id = ?',
      whereArgs: [session.actorId, session.billarId, request.requestId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    if (rows.single['payload'] != jsonEncode(request.payload) ||
        (request.remoteSaleId != null &&
            rows.single['remote_sale_id'] != request.remoteSaleId)) {
      throw StateError('La solicitud conciliada no coincide con la venta.');
    }
    return rows.single['local_sale_id'] as int;
  }

  Future<int> reconcile({
    required SyncSession session,
    required PendingStaffQuickSale request,
  }) async {
    outbox.requireSession(session);
    final existing = await _completed(outbox.database, session, request);
    outbox.requireSession(session);
    if (existing != null) return existing;
    final pending = await outbox.pending(session);
    if (pending == null ||
        pending.requestId != request.requestId ||
        jsonEncode(pending.payload) != jsonEncode(request.payload) ||
        pending.remoteSaleId == null) {
      throw StateError('La venta aún no tiene confirmación remota.');
    }
    final response = await client
        .rpc(
          'get_staff_sale_reconciliation',
          params: {
            'p_request_id': request.requestId,
            'p_billar_id': session.billarId,
          },
        )
        .setHeader('Authorization', 'Bearer ${session.token}');
    outbox.requireSession(session);
    if (response is! Map<String, dynamic>) {
      throw StateError('El comprobante de venta no es válido.');
    }
    final receipt = _validateReceipt(response, session, pending);
    return outbox.database.transaction((txn) async {
      outbox.requireSession(session);
      final completed = await _completed(txn, session, request);
      if (completed != null) {
        outbox.requireSession(session);
        return completed;
      }
      final rows = await txn.query(
        'pending_staff_sales',
        where: 'actor_id = ? AND billar_id = ? AND request_id = ?',
        whereArgs: [session.actorId, session.billarId, request.requestId],
        limit: 1,
      );
      if (rows.length != 1 ||
          rows.single['payload'] != jsonEncode(pending.payload) ||
          rows.single['remote_sale_id'] != pending.remoteSaleId) {
        throw StateError('La venta pendiente cambió durante la conciliación.');
      }
      final snapshot = rows.single['reservation_snapshot'] as String?;
      if (snapshot == null ||
          jsonEncode(await outbox.reservations(txn, session)) != snapshot) {
        throw StateError(
          'La reserva del carrito cambió; debe revisarse antes de conciliar.',
        );
      }

      for (final stock in receipt.stock) {
        final cache = outbox.cache;
        if (cache != null) {
          await cache.reconcileStock(
            txn,
            session,
            productId: stock.id,
            stock: stock.stock,
            revision: stock.revision,
          );
          continue;
        }
        final products = await txn.query(
          'products',
          columns: [
            'billar_id',
            'stock',
            'stock_revision',
            'synced',
            'stock_conflict',
          ],
          where: 'id = ?',
          whereArgs: [stock.id],
          limit: 1,
        );
        if (products.length != 1 ||
            products.single['billar_id'] != session.billarId ||
            products.single['synced'] != 1 ||
            products.single['stock_conflict'] != 0) {
          throw StateError(
            'El inventario local requiere revisión antes de conciliar.',
          );
        }
        final current = products.single;
        final revision = current['stock_revision'] as int?;
        if (revision == stock.revision && current['stock'] != stock.stock) {
          throw StateError(
            'La revisión de inventario tiene valores diferentes.',
          );
        }
        if (revision == null || revision < stock.revision) {
          await txn.update(
            'products',
            {'stock': stock.stock, 'stock_revision': stock.revision},
            where: 'id = ? AND billar_id = ?',
            whereArgs: [stock.id, session.billarId],
          );
        }
      }

      final saleRows = await txn.query(
        'sales_history',
        where: 'cloud_id = ?',
        whereArgs: [pending.remoteSaleId.toString()],
      );
      if (saleRows.length > 1) {
        throw StateError('La venta remota está duplicada en el dispositivo.');
      }
      final int saleId;
      if (saleRows.isEmpty) {
        saleId = await txn.insert('sales_history', {
          'billar_id': session.billarId,
          'total': receipt.total,
          'paid': receipt.paid,
          'date': receipt.date,
          'type': 'Venta Rápida',
          'source_module': 'quick_sale',
          'payment_method': receipt.paymentMethod,
          'cancelled': receipt.cancelled ? 1 : 0,
          'synced': 1,
          'cloud_id': pending.remoteSaleId.toString(),
        });
      } else {
        final sale = saleRows.single;
        if (sale['billar_id'] != session.billarId ||
            sale['synced'] != 1 ||
            sale['type'] != 'Venta Rápida' ||
            sale['source_module'] != 'quick_sale' ||
            sale['total'] != receipt.total ||
            sale['paid'] != receipt.paid ||
            sale['date'] != receipt.date ||
            sale['payment_method'] != receipt.paymentMethod) {
          throw StateError('La venta local no coincide con el comprobante.');
        }
        saleId = sale['id'] as int;
        if (receipt.cancelled && sale['cancelled'] != 1) {
          await txn.update(
            'sales_history',
            {'cancelled': 1},
            where: 'id = ?',
            whereArgs: [saleId],
          );
        }
      }
      final cancelled =
          receipt.cancelled ||
          (saleRows.isNotEmpty && saleRows.single['cancelled'] == 1);
      final details = await txn.query(
        'sale_details',
        where: 'sale_id = ?',
        whereArgs: [saleId],
        orderBy: 'id',
      );
      if (details.isNotEmpty && details.length != receipt.items.length) {
        throw StateError('Los detalles locales no coinciden con la venta.');
      }
      for (var i = 0; i < receipt.items.length; i++) {
        final item = receipt.items[i];
        if (details.isEmpty) {
          await txn.insert('sale_details', {
            'sale_id': saleId,
            'product_id': item.id,
            'product_name': item.name,
            'quantity': item.quantity,
            'price_at_sale': item.price,
            if (item.cost != null) 'cost_at_sale': item.cost,
            'cost_available': item.cost == null ? 0 : 1,
            'cancelled': item.cancelled || cancelled ? 1 : 0,
          });
        } else {
          final detail = details[i];
          if (detail['product_id'] != item.id ||
              detail['product_name'] != item.name ||
              detail['quantity'] != item.quantity ||
              detail['price_at_sale'] != item.price ||
              (item.cost != null &&
                  detail['cost_available'] == 1 &&
                  detail['cost_at_sale'] != item.cost)) {
            throw StateError('Los detalles locales no coinciden con la venta.');
          }
          if ((item.cancelled || cancelled) && detail['cancelled'] != 1) {
            await txn.update(
              'sale_details',
              {'cancelled': 1},
              where: 'id = ?',
              whereArgs: [detail['id']],
            );
          }
          if (item.cost != null && detail['cost_available'] == 0) {
            await txn.update(
              'sale_details',
              {'cost_at_sale': item.cost, 'cost_available': 1},
              where: 'id = ?',
              whereArgs: [detail['id']],
            );
          }
        }
      }
      await txn.insert('reconciled_staff_sales', {
        'actor_id': session.actorId,
        'billar_id': session.billarId,
        'request_id': request.requestId,
        'payload': jsonEncode(pending.payload),
        'remote_sale_id': pending.remoteSaleId,
        'local_sale_id': saleId,
      });
      final cache = outbox.cache;
      if (cache != null) {
        await cache.clearCart(txn, session);
      } else {
        await txn.delete(
          'temp_reservations',
          where:
              'source = ? AND product_id IN '
              '(SELECT id FROM products WHERE billar_id = ?)',
          whereArgs: ['quick_sale', session.billarId],
        );
      }
      final deleted = await txn.delete(
        'pending_staff_sales',
        where: 'actor_id = ? AND billar_id = ? AND request_id = ?',
        whereArgs: [session.actorId, session.billarId, request.requestId],
      );
      if (deleted != 1) throw StateError('La venta pendiente ya no existe.');
      outbox.requireSession(session);
      return saleId;
    });
  }
}

typedef _Stock = ({int id, double stock, int revision});
typedef _Item =
    ({
      int id,
      String name,
      double quantity,
      double price,
      bool cancelled,
      double? cost,
    });
typedef _Receipt =
    ({
      String date,
      String paymentMethod,
      double total,
      double paid,
      bool cancelled,
      List<_Item> items,
      List<_Stock> stock,
    });

_Receipt _validateReceipt(
  Map<String, dynamic> response,
  SyncSession session,
  PendingStaffQuickSale request,
) {
  final payload = request.payload;
  final items = response['items'];
  final stock = response['stock'];
  final requestedItems = payload['p_items'];
  if (response['request_id'] != request.requestId ||
      response['billar_id'] != session.billarId ||
      response['sale_id'] != request.remoteSaleId ||
      response['date'] != payload['p_sale_date'] ||
      response['payment_method'] != payload['p_payment_method'] ||
      response['total'] != payload['p_total'] ||
      response['paid'] != payload['p_paid'] ||
      response['cancelled'] is! bool ||
      items is! List ||
      items.isEmpty ||
      requestedItems is! List ||
      requestedItems.length != items.length ||
      stock is! List ||
      stock.isEmpty) {
    throw StateError('El comprobante no corresponde a la venta pendiente.');
  }
  final parsedItems = <_Item>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final requested = requestedItems[i];
    if (item is! Map ||
        requested is! Map ||
        item['product_id'] is! int ||
        item['product_id'] != requested['product_id'] ||
        item['product_name'] is! String ||
        (item['product_name'] as String).trim().isEmpty ||
        item['quantity'] is! num ||
        item['quantity'] != requested['quantity'] ||
        item['price_at_sale'] is! num ||
        item['price_at_sale'] != requested['price_at_sale'] ||
        item['cancelled'] is! bool ||
        (item.containsKey('cost_at_sale') &&
            (item['cost_at_sale'] is! num ||
                !(item['cost_at_sale'] as num).isFinite ||
                (item['cost_at_sale'] as num) < 0))) {
      throw StateError('Los detalles del comprobante no son válidos.');
    }
    parsedItems.add((
      id: item['product_id'] as int,
      name: item['product_name'] as String,
      quantity: (item['quantity'] as num).toDouble(),
      price: (item['price_at_sale'] as num).toDouble(),
      cancelled: item['cancelled'] as bool,
      cost: (item['cost_at_sale'] as num?)?.toDouble(),
    ));
  }
  final ids = <int>{};
  final parsedStock = <_Stock>[];
  for (final entry in stock) {
    if (entry is! Map ||
        entry['product_id'] is! int ||
        (entry['product_id'] as int) <= 0 ||
        !ids.add(entry['product_id'] as int) ||
        entry['stock'] is! num ||
        !(entry['stock'] as num).isFinite ||
        entry['stock_revision'] is! int ||
        (entry['stock_revision'] as int) < 0) {
      throw StateError('El inventario del comprobante no es válido.');
    }
    parsedStock.add((
      id: entry['product_id'] as int,
      stock: (entry['stock'] as num).toDouble(),
      revision: entry['stock_revision'] as int,
    ));
  }
  return (
    date: response['date'] as String,
    paymentMethod: response['payment_method'] as String,
    total: (response['total'] as num).toDouble(),
    paid: (response['paid'] as num).toDouble(),
    cancelled: response['cancelled'] as bool,
    items: parsedItems,
    stock: parsedStock,
  );
}
