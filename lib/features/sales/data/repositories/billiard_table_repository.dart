import 'dart:async';
import 'dart:convert';
import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_service.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class BilliardTableRepository {
  BilliardTableRepository({String? Function()? currentActorId})
    : _currentActorId =
          currentActorId ??
          (() => Supabase.instance.client.auth.currentUser?.id);

  final String? Function() _currentActorId;
  final DatabaseHelper _db = DatabaseHelper.instance;
  final SyncService _sync = SyncService();

  static const _tableTypes = ['Billar', 'Comanda'];

  void _requireBillar(String billarId) {
    if (PreferencesService().billarId != billarId) {
      throw StateError('El billar cambió durante la operación de mesas.');
    }
  }

  String _deletionActor() {
    final actorId = _currentActorId();
    if (actorId == null || actorId.isEmpty) {
      throw StateError('Se requiere una sesión para eliminar mesas.');
    }
    return actorId;
  }

  void _requireDeletionScope(String actorId, String billarId, int generation) {
    if (_currentActorId() != actorId ||
        PreferencesService().billarId != billarId ||
        PreferencesService().scopeGeneration != generation) {
      throw StateError('La cuenta o el billar cambió al eliminar la mesa.');
    }
  }

  Future<void> _updateTable(
    int id,
    String billarId,
    Map<String, Object?> payload,
  ) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      _requireBillar(billarId);
      final count = await txn.update(
        'billiard_tables',
        payload,
        where: 'id = ? AND billar_id = ?',
        whereArgs: [id, billarId],
      );
      if (count != 1) {
        throw StateError('La mesa no pertenece al billar actual o no existe.');
      }
      _requireBillar(billarId);
    });
  }

  Future<List<Map<String, dynamic>>> getAll({
    String? billarId,
    bool includeDeleted = false,
  }) async {
    final currentBillarId = PreferencesService().billarId;
    if (billarId != null && billarId != currentBillarId) {
      throw StateError('El billar solicitado no es el actual.');
    }
    final db = await _db.database;
    final filters = <String>['billar_id = ?'];
    final args = <Object?>[currentBillarId];
    if (!includeDeleted) filters.add('is_deleted = 0');
    final rows = await db.query(
      'billiard_tables',
      where: filters.join(' AND '),
      whereArgs: args,
      orderBy: 'id ASC',
    );
    _requireBillar(currentBillarId);
    return rows;
  }

  Future<int> getNextId() async {
    final billarId = PreferencesService().billarId;
    await _sync.pullTablesFromCloud();
    _requireBillar(billarId);
    final db = await _db.database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(id), 0) + 1 AS next_id FROM billiard_tables',
    );
    _requireBillar(billarId);
    return (rows.first['next_id'] as int?) ?? 1;
  }

  Future<Map<String, dynamic>?> getById(int id) async {
    final billarId = PreferencesService().billarId;
    final result = await _getByIdForBillar(id, billarId);
    _requireBillar(billarId);
    return result;
  }

  Future<Map<String, dynamic>?> _getByIdForBillar(
    int id,
    String billarId,
  ) async {
    final db = await _db.database;
    final rows = await db.query(
      'billiard_tables',
      where: 'id = ? AND billar_id = ?',
      whereArgs: [id, billarId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> insert({
    required int id,
    required String billarId,
    required String name,
    required String tableType,
  }) async {
    if (billarId != PreferencesService().billarId) {
      throw StateError('El billar solicitado no es el actual.');
    }
    final db = await _db.database;
    final row = {
      'id': id,
      'billar_id': billarId,
      'name': name,
      'table_type': _normalizeType(tableType),
      'is_occupied': 0,
      'orders': '[]',
      'synced': 0,
      'is_deleted': 0,
    };
    await db.transaction((txn) async {
      if (billarId != PreferencesService().billarId) {
        throw StateError('El billar cambió durante la creación de la mesa.');
      }
      final existing = await txn.query(
        'billiard_tables',
        columns: ['id'],
        where: 'id = ? AND billar_id = ?',
        whereArgs: [id, billarId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw StateError('El identificador de mesa ya existe en este billar.');
      }
      await txn.insert('billiard_tables', row);
      if (billarId != PreferencesService().billarId) {
        throw StateError('El billar cambió durante la creación de la mesa.');
      }
    });
    // Sync en background para no bloquear UI
    _sync.pushTableToCloud(row).ignore();
  }

  Future<void> update({
    required int id,
    String? name,
    String? tableType,
    int? isOccupied,
    DateTime? startTime,
    List<Map<String, dynamic>>? orders,
  }) async {
    final billarId = PreferencesService().billarId;
    final payload = <String, Object?>{
      if (name != null) 'name': name,
      if (tableType != null) 'table_type': _normalizeType(tableType),
      if (isOccupied != null) 'is_occupied': isOccupied,
      if (startTime != null) 'start_time': startTime.toIso8601String(),
      if (orders != null) 'orders': jsonEncode(orders),
      'synced': 0,
    };
    if (payload.isEmpty) return;
    await _updateTable(id, billarId, payload);

    // Sync en background para no bloquear UI
    _getByIdForBillar(id, billarId).then((updated) {
      if (updated != null) _sync.pushTableToCloud(updated).ignore();
    }).ignore();
  }

  Future<void> updateWithoutSync({
    required int id,
    String? name,
    String? tableType,
  }) async {
    final billarId = PreferencesService().billarId;
    final payload = <String, Object?>{
      if (name != null) 'name': name,
      if (tableType != null) 'table_type': _normalizeType(tableType),
    };
    if (payload.isEmpty) return;
    await _updateTable(id, billarId, payload);
  }

  Future<void> updateName(int id, String name) async {
    await update(id: id, name: name);
  }

  Future<void> updateTableType(int id, String tableType) async {
    await update(id: id, tableType: tableType);
  }

  Future<void> syncAllToCloud() async {
    final prefs = PreferencesService();
    final rows = await getAll(billarId: prefs.billarId);
    for (final row in rows) {
      _sync.pushTableToCloud(row).ignore();
    }
  }

  Future<void> occupy(int id, DateTime startTime) async {
    await update(id: id, isOccupied: 1, startTime: startTime);
  }

  Future<void> free(int id) async {
    final billarId = PreferencesService().billarId;
    await _updateTable(id, billarId, {
      'is_occupied': 0,
      'start_time': null,
      'orders': '[]',
      'synced': 0,
    });
    final updated = await _getByIdForBillar(id, billarId);
    if (updated != null) _sync.pushTableToCloud(updated).ignore();
  }

  Future<void> _requireDeletable(
    DatabaseExecutor db,
    Map<String, Object?> table,
    String billarId,
  ) async {
    final conflicts = await db.query(
      'table_sync_conflicts',
      columns: ['id'],
      where: 'billar_id = ? AND table_id = ?',
      whereArgs: [billarId, table['id']],
      limit: 1,
    );
    if (conflicts.isNotEmpty) {
      throw StateError('La mesa tiene un conflicto pendiente de revisión.');
    }
    if (table['is_occupied'] == 1 || table['start_time'] != null) {
      throw StateError('No se puede eliminar una mesa con servicio activo.');
    }
    final orders = table['orders'];
    if (orders == null || orders == '') return;
    if (orders is! String) {
      throw StateError('No se pueden verificar los consumos de la mesa.');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(orders);
    } on FormatException {
      throw StateError('No se pueden verificar los consumos de la mesa.');
    }
    if (decoded is! List) {
      throw StateError('No se pueden verificar los consumos de la mesa.');
    }
    if (decoded.isNotEmpty) {
      throw StateError(
        'No se puede eliminar una mesa con consumos pendientes.',
      );
    }
  }

  Future<void> delete(int id) async {
    final billarId = PreferencesService().billarId;
    final generation = PreferencesService().scopeGeneration;
    final actorId = _deletionActor();
    final db = await _db.database;
    await db.transaction((txn) async {
      _requireDeletionScope(actorId, billarId, generation);
      final rows = await txn.query(
        'billiard_tables',
        where: 'id = ? AND billar_id = ?',
        whereArgs: [id, billarId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('La mesa no pertenece al billar actual o no existe.');
      }
      await _requireDeletable(txn, rows.single, billarId);
      await txn.update(
        'billiard_tables',
        {
          'is_deleted': 1,
          'is_occupied': 0,
          'start_time': null,
          'orders': '[]',
          'synced': 0,
        },
        where: 'id = ? AND billar_id = ?',
        whereArgs: [id, billarId],
      );
      _requireDeletionScope(actorId, billarId, generation);
    });
    _requireDeletionScope(actorId, billarId, generation);
    final deleted = await _getByIdForBillar(id, billarId);
    _requireDeletionScope(actorId, billarId, generation);
    if (deleted != null) {
      final synced = await _sync.pushTableToCloud(deleted);
      if (!synced) {
        _sync.schedulePendingSync();
      }
    }
  }

  Future<void> deleteAll({String? billarId}) async {
    final currentBillarId = PreferencesService().billarId;
    if (billarId != null && billarId != currentBillarId) {
      throw StateError('El billar solicitado no es el actual.');
    }
    final generation = PreferencesService().scopeGeneration;
    final actorId = _deletionActor();
    final db = await _db.database;
    final targetBillarId = currentBillarId;
    await db.transaction((txn) async {
      _requireDeletionScope(actorId, targetBillarId, generation);
      final tables = await txn.query(
        'billiard_tables',
        where: 'billar_id = ?',
        whereArgs: [targetBillarId],
      );
      for (final table in tables) {
        await _requireDeletable(txn, table, targetBillarId);
      }
      await txn.update(
        'billiard_tables',
        {
          'is_deleted': 1,
          'is_occupied': 0,
          'start_time': null,
          'orders': '[]',
          'synced': 0,
        },
        where: 'billar_id = ?',
        whereArgs: [targetBillarId],
      );
      _requireDeletionScope(actorId, targetBillarId, generation);
    });
    _requireDeletionScope(actorId, targetBillarId, generation);
    final rows = await getAll(billarId: targetBillarId, includeDeleted: true);
    for (final row in rows.where((row) => row['is_deleted'] == 1)) {
      _requireDeletionScope(actorId, targetBillarId, generation);
      await _sync.pushTableToCloud(row);
    }
  }

  static String _normalizeType(String type) {
    final cleaned = type.trim();
    return _tableTypes.contains(cleaned) ? cleaned : 'Billar';
  }
}
