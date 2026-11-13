import 'dart:async';
import 'dart:convert';
import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_service.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class BilliardTableRepository {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final SyncService _sync = SyncService();

  static const _tableTypes = ['Billar', 'Comanda'];

  Future<List<Map<String, dynamic>>> getAll({
    String? billarId,
    bool includeDeleted = false,
  }) async {
    final db = await _db.database;
    final filters = <String>[];
    final args = <Object?>[];
    if (billarId != null) {
      filters.add('billar_id = ?');
      args.add(billarId);
    }
    if (!includeDeleted) filters.add('is_deleted = 0');
    final rows = await db.query(
      'billiard_tables',
      where: filters.isEmpty ? null : filters.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'id ASC',
    );
    return rows;
  }

  Future<int> getNextId() async {
    await _sync.pullTablesFromCloud();
    final db = await _db.database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(id), 0) + 1 AS next_id FROM billiard_tables WHERE billar_id = ?',
      [PreferencesService().billarId],
    );
    return (rows.first['next_id'] as int?) ?? 1;
  }

  Future<Map<String, dynamic>?> getById(int id) async {
    final db = await _db.database;
    final rows = await db.query(
      'billiard_tables',
      where: 'id = ?',
      whereArgs: [id],
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
    await db.insert(
      'billiard_tables',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
    final db = await _db.database;
    final payload = <String, Object?>{
      if (name != null) 'name': name,
      if (tableType != null) 'table_type': _normalizeType(tableType),
      if (isOccupied != null) 'is_occupied': isOccupied,
      if (startTime != null) 'start_time': startTime.toIso8601String(),
      if (orders != null) 'orders': jsonEncode(orders),
      'synced': 0,
    };
    if (payload.isEmpty) return;
    await db.update(
      'billiard_tables',
      payload,
      where: 'id = ?',
      whereArgs: [id],
    );

    // Sync en background para no bloquear UI
    getById(id).then((updated) {
      if (updated != null) _sync.pushTableToCloud(updated).ignore();
    }).ignore();
  }

  Future<void> updateWithoutSync({
    required int id,
    String? name,
    String? tableType,
  }) async {
    final db = await _db.database;
    final payload = <String, Object?>{
      if (name != null) 'name': name,
      if (tableType != null) 'table_type': _normalizeType(tableType),
    };
    if (payload.isEmpty) return;
    await db.update(
      'billiard_tables',
      payload,
      where: 'id = ?',
      whereArgs: [id],
    );
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
    final db = await _db.database;
    await db.update(
      'billiard_tables',
      {'is_occupied': 0, 'start_time': null, 'orders': '[]', 'synced': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
    final updated = await getById(id);
    if (updated != null) _sync.pushTableToCloud(updated).ignore();
  }

  Future<void> delete(int id) async {
    final db = await _db.database;
    final billarId = PreferencesService().billarId;
    await db.update(
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
    final deleted = await getById(id);
    if (deleted != null) {
      final synced = await _sync.pushTableToCloud(deleted);
      if (!synced) {
        _sync.schedulePendingSync();
      }
    }
  }

  Future<void> deleteAll({String? billarId}) async {
    final db = await _db.database;
    final targetBillarId = billarId ?? PreferencesService().billarId;
    await db.update(
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
    final rows = await getAll(billarId: targetBillarId, includeDeleted: true);
    for (final row in rows.where((row) => row['is_deleted'] == 1)) {
      await _sync.pushTableToCloud(row);
    }
  }

  static String _normalizeType(String type) {
    final cleaned = type.trim();
    return _tableTypes.contains(cleaned) ? cleaned : 'Billar';
  }
}
