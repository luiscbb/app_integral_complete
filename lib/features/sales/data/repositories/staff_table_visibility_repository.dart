import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';

class StaffTableVisibilitySnapshot {
  const StaffTableVisibilitySnapshot({
    required this.tables,
    required this.fetchedAt,
  });

  final List<Map<String, dynamic>> tables;
  final DateTime fetchedAt;
}

class StaffTableVisibilityRepository {
  const StaffTableVisibilityRepository(
    this.client,
    this.requireSession, {
    this.database,
  });

  final SupabaseClient client;
  final void Function(SyncSession) requireSession;
  final Database? database;

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  Future<List<Map<String, dynamic>>> read({
    required SyncSession session,
    required String tableType,
  }) async {
    if (tableType != 'Billar' && tableType != 'Comanda') {
      throw ArgumentError('El tipo de servicio no es válido.');
    }
    requireSession(session);
    final response = await client
        .rpc(
          'staff_table_visible_tables',
          params: {
            'requested_billar_id': session.billarId,
            'requested_table_type': tableType,
          },
        )
        .setHeader('Authorization', 'Bearer ${session.token}')
        .timeout(const Duration(seconds: 8));
    requireSession(session);
    if (response is! Map ||
        response['billar_id'] != session.billarId ||
        response['table_type'] != tableType ||
        response['items'] is! List) {
      throw const FormatException('La respuesta de mesas no es válida.');
    }
    final tables = _validateItems(
      response['items'] as List,
      session: session,
      tableType: tableType,
    );
    await _cache(session, tableType, tables);
    return tables;
  }

  Future<StaffTableVisibilitySnapshot?> readCached({
    required SyncSession session,
    required String tableType,
    required bool canViewAll,
  }) async {
    if (tableType != 'Billar' && tableType != 'Comanda') {
      throw ArgumentError('El tipo de servicio no es válido.');
    }
    final db = database;
    if (db == null) return null;
    requireSession(session);
    final rows = await db.query(
      'staff_table_visibility_cache',
      where: 'actor_id = ? AND billar_id = ? AND table_type = ?',
      whereArgs: [session.actorId, session.billarId, tableType],
      limit: 1,
    );
    requireSession(session);
    if (rows.isEmpty) return null;
    if (rows.length != 1) {
      throw const FormatException('La caché de mesas no es válida.');
    }
    final payload = rows.single['payload'];
    final fetchedAt = rows.single['fetched_at'];
    if (payload is! String || fetchedAt is! String) {
      throw const FormatException('La caché de mesas no es válida.');
    }
    final decoded = jsonDecode(payload);
    if (decoded is! List) {
      throw const FormatException('La caché de mesas no es válida.');
    }
    final tables = _validateItems(
      decoded,
      session: session,
      tableType: tableType,
    );
    final visibleTables =
        canViewAll
            ? tables
            : tables
                .where(
                  (table) =>
                      table['service_actor_id'] == null ||
                      table['service_actor_id'] == session.actorId,
                )
                .toList(growable: false);
    final parsedAt = DateTime.tryParse(fetchedAt);
    if (parsedAt == null) {
      throw const FormatException('La fecha de caché no es válida.');
    }
    return StaffTableVisibilitySnapshot(
      tables: List.unmodifiable(visibleTables),
      fetchedAt: parsedAt.toUtc(),
    );
  }

  Future<void> _cache(
    SyncSession session,
    String tableType,
    List<Map<String, dynamic>> tables,
  ) async {
    final db = database;
    if (db == null) return;
    final fetchedAt = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      requireSession(session);
      await txn.insert('staff_table_visibility_cache', {
        'actor_id': session.actorId,
        'billar_id': session.billarId,
        'table_type': tableType,
        'payload': jsonEncode(tables),
        'fetched_at': fetchedAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      requireSession(session);
    });
  }

  List<Map<String, dynamic>> _validateItems(
    List rawItems, {
    required SyncSession session,
    required String tableType,
  }) {
    final ids = <int>{};
    final tables = <Map<String, dynamic>>[];
    for (final raw in rawItems) {
      if (raw is! Map) {
        throw const FormatException('La mesa recibida no es válida.');
      }
      final table = Map<String, dynamic>.from(raw);
      final id = table['id'];
      final name = table['name'];
      final actualType = table['table_type'];
      final occupied = table['is_occupied'];
      final deleted = table['is_deleted'];
      final orders = table['orders'];
      final startTime = table['start_time'];
      final serviceId = table['service_id'];
      final serviceActorId = table['service_actor_id'];
      final serviceState = table['service_state'];
      final serviceItems = table['service_items'];
      if (id is! int ||
          id <= 0 ||
          !ids.add(id) ||
          table['billar_id'] != session.billarId ||
          name is! String ||
          name.trim().isEmpty ||
          !_matchesType(tableType, actualType) ||
          occupied is! int ||
          (occupied != 0 && occupied != 1) ||
          deleted != 0 ||
          orders is! String ||
          !_validOrders(orders) ||
          (startTime != null &&
              (startTime is! String || DateTime.tryParse(startTime) == null)) ||
          serviceItems is! List) {
        throw const FormatException('La mesa recibida no es válida.');
      }
      if (serviceId == null) {
        if (serviceActorId != null ||
            serviceState != null ||
            serviceItems.isNotEmpty) {
          throw const FormatException(
            'La propiedad del servicio recibido no es válida.',
          );
        }
      } else if (serviceId is! String ||
          !_uuid.hasMatch(serviceId) ||
          serviceActorId is! String ||
          !_uuid.hasMatch(serviceActorId) ||
          serviceState != 'active' ||
          occupied != 1 ||
          startTime == null ||
          !_validServiceItems(serviceItems)) {
        throw const FormatException(
          'La propiedad del servicio recibido no es válida.',
        );
      }
      tables.add(Map.unmodifiable(table));
    }
    return List.unmodifiable(tables);
  }

  bool _matchesType(String requested, Object? actual) =>
      requested == 'Comanda'
          ? actual == 'Comanda'
          : const {'Billar', 'Pool', 'Carambola', 'Snooker'}.contains(actual);

  bool _validOrders(String encoded) {
    try {
      final value = jsonDecode(encoded);
      if (value is! List) return false;
      return value.every(
        (item) =>
            item is Map &&
            (item['productId'] == null ||
                (item['productId'] is int && item['productId'] > 0)) &&
            item['productName'] is String &&
            item['price'] is num &&
            (item['price'] as num).isFinite &&
            (item['price'] as num) >= 0 &&
            item['quantity'] is num &&
            (item['quantity'] as num).isFinite &&
            (item['quantity'] as num) > 0,
      );
    } on FormatException {
      return false;
    }
  }

  bool _validServiceItems(List items) => items.every(
    (item) =>
        item is Map &&
        item['request_id'] is String &&
        _uuid.hasMatch(item['request_id'] as String) &&
        item['productId'] is int &&
        (item['productId'] as int) > 0 &&
        item['productName'] is String &&
        (item['productName'] as String).trim().isNotEmpty &&
        item['price'] is num &&
        (item['price'] as num).isFinite &&
        (item['price'] as num) >= 0 &&
        item['quantity'] is num &&
        (item['quantity'] as num).isFinite &&
        (item['quantity'] as num) > 0 &&
        item['recorded_at'] is String &&
        DateTime.tryParse(item['recorded_at'] as String) != null,
  );
}
