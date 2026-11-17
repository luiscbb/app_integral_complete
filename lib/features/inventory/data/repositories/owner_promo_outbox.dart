import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../../../core/services/sync_session.dart';
import '../../../../core/utils/uuid_v4.dart';

typedef OwnerPromoRequest = ({String requestId, Map<String, dynamic> payload});

class OwnerPromoOutbox {
  const OwnerPromoOutbox(this.database, this.requireSession);

  final Database database;
  final void Function(SyncSession) requireSession;

  Future<void> validateOwner(SyncSession session, int productId) async {
    requireSession(session);
    final rows = await database.query(
      'pending_owner_promos',
      columns: ['actor_id', 'billar_id'],
      where: 'product_id = ?',
      whereArgs: [productId],
      limit: 1,
    );
    requireSession(session);
    if (rows.isNotEmpty &&
        (rows.single['actor_id'] != session.actorId ||
            rows.single['billar_id'] != session.billarId)) {
      throw StateError('La promoción pendiente pertenece a otra cuenta.');
    }
  }

  Future<void> registerNew(
    Transaction txn,
    SyncSession session,
    int productId,
  ) async {
    requireSession(session);
    await txn.insert('pending_owner_promos', {
      'product_id': productId,
      'actor_id': session.actorId,
      'billar_id': session.billarId,
      'is_new': 1,
    });
    requireSession(session);
  }

  Future<Map<String, dynamic>> _snapshot(
    Transaction txn,
    SyncSession session,
    int productId,
    bool isNew, {
    bool validateForSubmission = true,
  }) async {
    final products = await txn.query(
      'products',
      where: 'id = ? AND billar_id = ? AND is_promo = 1',
      whereArgs: [productId, session.billarId],
      limit: 1,
    );
    if (products.length != 1) {
      throw StateError('La promoción no pertenece al billar actual.');
    }
    final product = products.single;
    final revision = product['stock_revision'] as int?;
    if ((isNew && revision != null) || (!isNew && revision == null)) {
      throw StateError('No se conoce la revisión remota de la promoción.');
    }
    final image = product['image_path'] as String?;
    if (validateForSubmission &&
        image != null &&
        image.isNotEmpty &&
        !image.startsWith('http://') &&
        !image.startsWith('https://')) {
      throw StateError('La imagen de la promoción aún no se ha subido.');
    }
    final components = await txn.rawQuery(
      '''
      SELECT i.child_id, i.quantity, p.billar_id, p.is_promo, p.parent_id, p.is_active
      FROM promo_items i LEFT JOIN products p ON p.id = i.child_id
      WHERE i.parent_id = ? ORDER BY i.child_id
    ''',
      [productId],
    );
    if (validateForSubmission && components.isEmpty) {
      throw StateError('La promoción no tiene componentes.');
    }
    final seen = <int>{};
    final items = <Map<String, int>>[];
    for (final component in components) {
      final id = component['child_id'] as int;
      final quantity = component['quantity'] as int;
      if (validateForSubmission &&
          (id <= 0 ||
              quantity <= 0 ||
              !seen.add(id) ||
              component['billar_id'] != session.billarId ||
              component['is_promo'] != 0 ||
              component['parent_id'] != null ||
              (product['is_active'] == 1 && component['is_active'] != 1))) {
        throw StateError('Los componentes de la promoción no son válidos.');
      }
      items.add({'product_id': id, 'quantity': quantity});
    }
    return {
      'p_product_id': productId,
      'p_expected_revision': revision,
      'p_product': {
        'name': product['name'],
        'barcode': product['barcode'],
        'description': product['description'],
        'price': product['price'],
        'cost': product['cost'],
        'image_path': image,
        'category': product['category'],
        'presentation': product['presentation'],
        'is_active': product['is_active'] == 1,
      },
      'p_components': items,
    };
  }

  Future<OwnerPromoRequest> prepare({
    required SyncSession session,
    required int productId,
  }) async => database.transaction((txn) async {
    requireSession(session);
    var rows = await txn.query(
      'pending_owner_promos',
      where: 'product_id = ?',
      whereArgs: [productId],
      limit: 1,
    );
    if (rows.isEmpty) {
      await _snapshot(txn, session, productId, false);
      await txn.insert('pending_owner_promos', {
        'product_id': productId,
        'actor_id': session.actorId,
        'billar_id': session.billarId,
        'is_new': 0,
      });
      rows = await txn.query(
        'pending_owner_promos',
        where: 'product_id = ?',
        whereArgs: [productId],
      );
    }
    final row = rows.single;
    if (row['actor_id'] != session.actorId ||
        row['billar_id'] != session.billarId) {
      throw StateError('La promoción pendiente pertenece a otra cuenta.');
    }
    final saved = row['payload'] as String?;
    if (saved != null) {
      final payload = jsonDecode(saved);
      if (payload is! Map<String, dynamic>) {
        throw StateError('La solicitud de promoción no es válida.');
      }
      requireSession(session);
      return (requestId: row['request_id'] as String, payload: payload);
    }
    final payload = await _snapshot(
      txn,
      session,
      productId,
      row['is_new'] == 1,
    );
    final requestId = newUuidV4();
    await txn.update(
      'pending_owner_promos',
      {'request_id': requestId, 'payload': jsonEncode(payload)},
      where: 'product_id = ? AND actor_id = ? AND billar_id = ?',
      whereArgs: [productId, session.actorId, session.billarId],
    );
    requireSession(session);
    return (requestId: requestId, payload: payload);
  });

  Future<bool> acknowledge({
    required SyncSession session,
    required int productId,
    required OwnerPromoRequest request,
    required int revision,
  }) async => database.transaction((txn) async {
    requireSession(session);
    final rows = await txn.query(
      'pending_owner_promos',
      where:
          'product_id = ? AND actor_id = ? AND billar_id = ? AND request_id = ?',
      whereArgs: [
        productId,
        session.actorId,
        session.billarId,
        request.requestId,
      ],
      limit: 1,
    );
    if (rows.length != 1 ||
        rows.single['payload'] != jsonEncode(request.payload)) {
      throw StateError('La solicitud pendiente de promoción cambió.');
    }
    final expected = request.payload['p_expected_revision'];
    if ((expected == null && revision != 0) ||
        (expected is int && revision != expected + 1) ||
        (expected != null && expected is! int)) {
      throw StateError('La revisión recibida de la promoción no es válida.');
    }
    final current = await _snapshot(
      txn,
      session,
      productId,
      rows.single['is_new'] == 1,
      validateForSubmission: false,
    );
    final unchanged = jsonEncode(current) == jsonEncode(request.payload);
    final updated = await txn.update(
      'products',
      {'stock_revision': revision, 'synced': unchanged ? 1 : 0},
      where: 'id = ? AND billar_id = ? AND is_promo = 1',
      whereArgs: [productId, session.billarId],
    );
    if (updated != 1) throw StateError('La promoción local ya no existe.');
    if (unchanged) {
      await txn.delete(
        'pending_owner_promos',
        where: 'product_id = ?',
        whereArgs: [productId],
      );
    } else {
      await txn.update(
        'pending_owner_promos',
        {'is_new': 0, 'request_id': null, 'payload': null},
        where: 'product_id = ?',
        whereArgs: [productId],
      );
    }
    requireSession(session);
    return unchanged;
  });
}
