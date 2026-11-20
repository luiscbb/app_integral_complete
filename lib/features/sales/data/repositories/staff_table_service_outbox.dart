import 'package:sqflite/sqflite.dart';

import '../../../../core/services/sync_session.dart';

class StaffTableServiceDraft {
  const StaffTableServiceDraft({
    required this.id,
    required this.tableId,
    required this.tableType,
    required this.openedAt,
    required this.state,
  });

  final String id;
  final int tableId;
  final String tableType;
  final DateTime openedAt;
  final String state;
}

class StaffTableConsumption {
  const StaffTableConsumption({
    required this.requestId,
    required this.serviceId,
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.price,
    required this.recordedAt,
    required this.confirmed,
    required this.late,
  });

  final String requestId;
  final String serviceId;
  final int productId;
  final String productName;
  final double quantity;
  final double price;
  final DateTime recordedAt;
  final bool confirmed;
  final bool late;
}

class StaffTableServiceOutbox {
  const StaffTableServiceOutbox(this.database, this.requireSession);

  final Database database;
  final void Function(SyncSession) requireSession;

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  StaffTableServiceDraft _readDraft(Map<String, Object?> row) {
    final id = row['service_id'];
    final tableId = row['table_id'];
    final type = row['table_type'];
    final openedAt = row['opened_at'];
    final state = row['state'];
    if (id is! String ||
        !_uuid.hasMatch(id) ||
        tableId is! int ||
        tableId <= 0 ||
        (type != 'Billar' && type != 'Comanda') ||
        openedAt is! String ||
        DateTime.tryParse(openedAt) == null ||
        !const {'pending', 'active', 'conflict', 'closed'}.contains(state)) {
      throw const FormatException('El servicio guardado no es válido.');
    }
    return StaffTableServiceDraft(
      id: id,
      tableId: tableId,
      tableType: type as String,
      openedAt: DateTime.parse(openedAt),
      state: state as String,
    );
  }

  StaffTableConsumption _readConsumption(Map<String, Object?> row) {
    final id = row['request_id'];
    final serviceId = row['service_id'];
    final productId = row['product_id'];
    final name = row['product_name'];
    final quantity = row['quantity'];
    final price = row['price'];
    final recorded = row['recorded_at'];
    final confirmed = row['confirmed'];
    final late = row['late'];
    if (id is! String ||
        !_uuid.hasMatch(id) ||
        serviceId is! String ||
        !_uuid.hasMatch(serviceId) ||
        productId is! int ||
        productId <= 0 ||
        name is! String ||
        name.trim().isEmpty ||
        name.runes.length > 255 ||
        quantity is! num ||
        !quantity.isFinite ||
        quantity <= 0 ||
        price is! num ||
        !price.isFinite ||
        price < 0 ||
        recorded is! String ||
        DateTime.tryParse(recorded) == null ||
        (confirmed != 0 && confirmed != 1) ||
        (late != 0 && late != 1) ||
        (late == 1 && confirmed != 1)) {
      throw const FormatException('El consumo guardado no es válido.');
    }
    return StaffTableConsumption(
      requestId: id,
      serviceId: serviceId,
      productId: productId,
      productName: name,
      quantity: quantity.toDouble(),
      price: price.toDouble(),
      recordedAt: DateTime.parse(recorded),
      confirmed: confirmed == 1,
      late: late == 1,
    );
  }

  Future<List<StaffTableServiceDraft>> drafts(SyncSession session) async {
    requireSession(session);
    final rows = await database.query(
      'staff_table_service_drafts',
      where: 'actor_id = ? AND billar_id = ? AND state <> ?',
      whereArgs: [session.actorId, session.billarId, 'closed'],
      orderBy: 'opened_at, service_id',
    );
    requireSession(session);
    return List.unmodifiable(rows.map(_readDraft));
  }

  Future<StaffTableServiceDraft> open({
    required SyncSession session,
    required String serviceId,
    required int tableId,
    required String tableType,
    required DateTime openedAt,
  }) async {
    if (!_uuid.hasMatch(serviceId) ||
        tableId <= 0 ||
        (tableType != 'Billar' && tableType != 'Comanda')) {
      throw ArgumentError('Los datos de apertura no son válidos.');
    }
    final timestamp = openedAt.toUtc().toIso8601String();
    return database.transaction((txn) async {
      requireSession(session);
      final existing = await txn.query(
        'staff_table_service_drafts',
        where: 'service_id = ?',
        whereArgs: [serviceId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final row = existing.single;
        if (row['actor_id'] != session.actorId ||
            row['billar_id'] != session.billarId ||
            row['table_id'] != tableId ||
            row['table_type'] != tableType ||
            row['opened_at'] != timestamp) {
          throw StateError('La apertura ya existe con otros datos.');
        }
        requireSession(session);
        return _readDraft(row);
      }
      final current = await txn.query(
        'staff_table_service_drafts',
        columns: ['service_id'],
        where:
            'actor_id = ? AND billar_id = ? AND table_id = ? '
            'AND table_type = ? AND state <> ?',
        whereArgs: [
          session.actorId,
          session.billarId,
          tableId,
          tableType,
          'closed',
        ],
        limit: 1,
      );
      if (current.isNotEmpty) {
        throw StateError('La mesa ya tiene un servicio local pendiente.');
      }
      final row = <String, Object>{
        'service_id': serviceId,
        'actor_id': session.actorId,
        'billar_id': session.billarId,
        'table_id': tableId,
        'table_type': tableType,
        'opened_at': timestamp,
        'state': 'pending',
      };
      await txn.insert('staff_table_service_drafts', row);
      requireSession(session);
      return _readDraft(row);
    });
  }

  Future<StaffTableServiceDraft> adoptVisibleActive({
    required SyncSession session,
    required String serviceId,
    required String serviceActorId,
    required int tableId,
    required String tableType,
    required DateTime openedAt,
    required List<Map<String, dynamic>> items,
  }) async {
    if (!_uuid.hasMatch(serviceId) ||
        serviceActorId != session.actorId ||
        tableId <= 0 ||
        (tableType != 'Billar' && tableType != 'Comanda')) {
      throw const FormatException('El servicio visible no es válido.');
    }
    final openedAtValue = openedAt.toUtc().toIso8601String();
    return database.transaction((txn) async {
      requireSession(session);
      final existing = await txn.query(
        'staff_table_service_drafts',
        where: 'service_id = ?',
        whereArgs: [serviceId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final row = existing.single;
        final savedOpenedAt =
            row['opened_at'] is String
                ? DateTime.tryParse(row['opened_at'] as String)
                : null;
        if (row['actor_id'] != session.actorId ||
            row['billar_id'] != session.billarId ||
            row['table_id'] != tableId ||
            row['table_type'] != tableType ||
            savedOpenedAt?.toUtc() != openedAt.toUtc() ||
            !const {'pending', 'active'}.contains(row['state'])) {
          throw StateError('El servicio visible no coincide con el guardado.');
        }
        if (row['state'] == 'pending') {
          await txn.update(
            'staff_table_service_drafts',
            {'state': 'active'},
            where: 'service_id = ? AND actor_id = ? AND billar_id = ?',
            whereArgs: [serviceId, session.actorId, session.billarId],
          );
        }
      } else {
        final current = await txn.query(
          'staff_table_service_drafts',
          columns: ['service_id'],
          where:
              'actor_id = ? AND billar_id = ? AND table_id = ? '
              'AND table_type = ? AND state <> ?',
          whereArgs: [
            session.actorId,
            session.billarId,
            tableId,
            tableType,
            'closed',
          ],
          limit: 1,
        );
        if (current.isNotEmpty) {
          throw StateError('La mesa tiene otro servicio local pendiente.');
        }
        await txn.insert('staff_table_service_drafts', {
          'service_id': serviceId,
          'actor_id': session.actorId,
          'billar_id': session.billarId,
          'table_id': tableId,
          'table_type': tableType,
          'opened_at': openedAtValue,
          'state': 'active',
        });
      }

      for (final item in items) {
        final requestId = item['request_id'];
        final productId = item['productId'];
        final productName = item['productName'];
        final quantity = item['quantity'];
        final price = item['price'];
        final recordedAt = item['recorded_at'];
        final parsedAt =
            recordedAt is String ? DateTime.tryParse(recordedAt) : null;
        if (requestId is! String ||
            !_uuid.hasMatch(requestId) ||
            productId is! int ||
            productId <= 0 ||
            productName is! String ||
            productName.trim().isEmpty ||
            productName.trim().runes.length > 255 ||
            quantity is! num ||
            !quantity.isFinite ||
            quantity <= 0 ||
            price is! num ||
            !price.isFinite ||
            price < 0 ||
            parsedAt == null) {
          throw const FormatException('El consumo visible no es válido.');
        }
        final normalizedName = productName.trim();
        final recordedAtValue = parsedAt.toUtc().toIso8601String();
        final savedItems = await txn.query(
          'staff_table_service_consumptions',
          where: 'request_id = ?',
          whereArgs: [requestId],
          limit: 1,
        );
        if (savedItems.isEmpty) {
          await txn.insert('staff_table_service_consumptions', {
            'request_id': requestId,
            'service_id': serviceId,
            'actor_id': session.actorId,
            'billar_id': session.billarId,
            'product_id': productId,
            'product_name': normalizedName,
            'quantity': quantity,
            'price': price,
            'recorded_at': recordedAtValue,
            'confirmed': 1,
            'late': 0,
          });
        } else {
          final itemRow = savedItems.single;
          final savedRecordedAt =
              itemRow['recorded_at'] is String
                  ? DateTime.tryParse(itemRow['recorded_at'] as String)
                  : null;
          if (itemRow['service_id'] != serviceId ||
              itemRow['actor_id'] != session.actorId ||
              itemRow['billar_id'] != session.billarId ||
              itemRow['product_id'] != productId ||
              itemRow['product_name'] != normalizedName ||
              itemRow['quantity'] != quantity ||
              itemRow['price'] != price ||
              savedRecordedAt?.toUtc() != parsedAt.toUtc() ||
              itemRow['late'] != 0) {
            throw StateError('El consumo visible no coincide con el guardado.');
          }
          if (itemRow['confirmed'] == 0) {
            await txn.update(
              'staff_table_service_consumptions',
              {'confirmed': 1},
              where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
              whereArgs: [requestId, session.actorId, session.billarId],
            );
          }
        }
      }
      requireSession(session);
      final saved = await txn.query(
        'staff_table_service_drafts',
        where: 'service_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [serviceId, session.actorId, session.billarId],
        limit: 1,
      );
      if (saved.length != 1) {
        throw StateError('El servicio local no se pudo recuperar.');
      }
      return _readDraft(saved.single);
    });
  }

  Future<List<StaffTableConsumption>> consumptions(
    SyncSession session,
    String serviceId,
  ) async {
    requireSession(session);
    final rows = await database.query(
      'staff_table_service_consumptions',
      where: 'actor_id = ? AND billar_id = ? AND service_id = ?',
      whereArgs: [session.actorId, session.billarId, serviceId],
      orderBy: 'sequence',
    );
    requireSession(session);
    return List.unmodifiable(rows.map(_readConsumption));
  }

  Future<StaffTableConsumption> addConsumption({
    required SyncSession session,
    required String requestId,
    required String serviceId,
    required int productId,
    required String productName,
    required double quantity,
    required double price,
    required DateTime recordedAt,
  }) async {
    if (!_uuid.hasMatch(requestId) ||
        !_uuid.hasMatch(serviceId) ||
        productId <= 0 ||
        productName.trim().isEmpty ||
        productName.trim().runes.length > 255 ||
        !quantity.isFinite ||
        quantity <= 0 ||
        !price.isFinite ||
        price < 0) {
      throw ArgumentError('Los datos del consumo no son válidos.');
    }
    final timestamp = recordedAt.toUtc().toIso8601String();
    final name = productName.trim();
    return database.transaction((txn) async {
      requireSession(session);
      final existing = await txn.query(
        'staff_table_service_consumptions',
        where: 'request_id = ?',
        whereArgs: [requestId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final row = existing.single;
        if (row['actor_id'] != session.actorId ||
            row['billar_id'] != session.billarId ||
            row['service_id'] != serviceId ||
            row['product_id'] != productId ||
            row['product_name'] != name ||
            row['quantity'] != quantity ||
            row['price'] != price ||
            row['recorded_at'] != timestamp) {
          throw StateError('El consumo ya existe con otros datos.');
        }
        requireSession(session);
        return _readConsumption(row);
      }
      final drafts = await txn.query(
        'staff_table_service_drafts',
        where: 'service_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [serviceId, session.actorId, session.billarId],
        limit: 1,
      );
      if (drafts.isEmpty ||
          !const {'pending', 'active'}.contains(drafts.single['state'])) {
        throw StateError(
          'El servicio no está disponible para agregar consumos.',
        );
      }
      final row = <String, Object>{
        'request_id': requestId,
        'service_id': serviceId,
        'actor_id': session.actorId,
        'billar_id': session.billarId,
        'product_id': productId,
        'product_name': name,
        'quantity': quantity,
        'price': price,
        'recorded_at': timestamp,
        'confirmed': 0,
        'late': 0,
      };
      await txn.insert('staff_table_service_consumptions', row);
      requireSession(session);
      return _readConsumption(row);
    });
  }

  Future<StaffTableServiceDraft> confirmOpen({
    required SyncSession session,
    required StaffTableServiceDraft draft,
    required Map<dynamic, dynamic> receipt,
  }) async {
    final state = receipt['state'];
    final openedAt = receipt['opened_at'];
    if (receipt['service_id'] != draft.id ||
        receipt['actor_id'] != session.actorId ||
        receipt['billar_id'] != session.billarId ||
        receipt['table_id'] != draft.tableId ||
        receipt['table_type'] != draft.tableType ||
        openedAt is! String ||
        DateTime.tryParse(openedAt)?.toUtc() != draft.openedAt.toUtc() ||
        (state != 'active' && state != 'conflict' && state != 'closed')) {
      throw const FormatException('La confirmación de apertura no es válida.');
    }
    return database.transaction((txn) async {
      requireSession(session);
      final rows = await txn.query(
        'staff_table_service_drafts',
        where: 'service_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [draft.id, session.actorId, session.billarId],
        limit: 1,
      );
      if (rows.length != 1) {
        throw StateError('El servicio local ya no está disponible.');
      }
      final saved = _readDraft(rows.single);
      if (saved.tableId != draft.tableId ||
          saved.tableType != draft.tableType ||
          saved.openedAt.toUtc() != draft.openedAt.toUtc() ||
          (saved.state != 'pending' && saved.state != state)) {
        throw StateError('El servicio local cambió durante la confirmación.');
      }
      var localState = state as String;
      if (state == 'closed') {
        final pending = await txn.query(
          'staff_table_service_consumptions',
          columns: ['request_id'],
          where:
              'service_id = ? AND actor_id = ? AND billar_id = ? AND confirmed = 0',
          whereArgs: [draft.id, session.actorId, session.billarId],
          limit: 1,
        );
        if (pending.isNotEmpty) localState = 'conflict';
      }
      await txn.update(
        'staff_table_service_drafts',
        {'state': localState},
        where: 'service_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [draft.id, session.actorId, session.billarId],
      );
      requireSession(session);
      return _readDraft({...rows.single, 'state': localState});
    });
  }

  Future<StaffTableServiceDraft> confirmConsumption({
    required SyncSession session,
    required StaffTableConsumption consumption,
    required Map<dynamic, dynamic> receipt,
  }) async {
    final recorded = receipt['recorded_at'];
    final remoteState = receipt['service_state'];
    final late = receipt['late'];
    if (receipt['request_id'] != consumption.requestId ||
        receipt['service_id'] != consumption.serviceId ||
        receipt['actor_id'] != session.actorId ||
        receipt['billar_id'] != session.billarId ||
        receipt['product_id'] != consumption.productId ||
        receipt['product_name'] != consumption.productName ||
        receipt['quantity'] != consumption.quantity ||
        receipt['price'] != consumption.price ||
        recorded is! String ||
        DateTime.tryParse(recorded)?.toUtc() !=
            consumption.recordedAt.toUtc() ||
        (remoteState != 'active' &&
            remoteState != 'conflict' &&
            remoteState != 'closed') ||
        late is! bool ||
        (late && remoteState != 'closed')) {
      throw const FormatException('La confirmación del consumo no es válida.');
    }
    return database.transaction((txn) async {
      requireSession(session);
      final rows = await txn.query(
        'staff_table_service_consumptions',
        where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [consumption.requestId, session.actorId, session.billarId],
        limit: 1,
      );
      final drafts = await txn.query(
        'staff_table_service_drafts',
        where: 'service_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [consumption.serviceId, session.actorId, session.billarId],
        limit: 1,
      );
      if (rows.length != 1 ||
          drafts.length != 1 ||
          (drafts.single['state'] != remoteState &&
              !(remoteState == 'closed' &&
                  const {
                    'active',
                    'conflict',
                  }.contains(drafts.single['state'])))) {
        throw StateError('El servicio o el consumo local cambió.');
      }
      final saved = _readConsumption(rows.single);
      if (saved.serviceId != consumption.serviceId ||
          saved.productId != consumption.productId ||
          saved.productName != consumption.productName ||
          saved.quantity != consumption.quantity ||
          saved.price != consumption.price ||
          saved.recordedAt.toUtc() != consumption.recordedAt.toUtc() ||
          (saved.confirmed && saved.late != late)) {
        throw StateError('El consumo local cambió durante la confirmación.');
      }
      await txn.update(
        'staff_table_service_consumptions',
        {'confirmed': 1, 'late': late ? 1 : 0},
        where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [consumption.requestId, session.actorId, session.billarId],
      );
      var localState = drafts.single['state'] as String;
      if (remoteState == 'closed') {
        final outstanding = await txn.query(
          'staff_table_service_consumptions',
          columns: ['request_id'],
          where:
              'service_id = ? AND actor_id = ? AND billar_id = ? AND (confirmed = 0 OR late = 1)',
          whereArgs: [consumption.serviceId, session.actorId, session.billarId],
          limit: 1,
        );
        localState = outstanding.isEmpty ? 'closed' : 'conflict';
        await txn.update(
          'staff_table_service_drafts',
          {'state': localState},
          where: 'service_id = ? AND actor_id = ? AND billar_id = ?',
          whereArgs: [consumption.serviceId, session.actorId, session.billarId],
        );
      }
      requireSession(session);
      return _readDraft({...drafts.single, 'state': localState});
    });
  }
}
