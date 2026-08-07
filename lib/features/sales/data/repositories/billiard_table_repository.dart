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

  Future<List<Map<String, dynamic>>> getAll({String? billarId}) async {
    final db = await _db.database;
    final where = billarId != null ? 'billar_id = ?' : null;
    final args = billarId != null ? [billarId] : null;
    final rows = await db.query(
      'billiard_tables',
      where: where,
      whereArgs: args,
      orderBy: 'id ASC',
    );
    return rows;
  }

  Future<Map<String, dynamic>?> getById(int id) async {
    final db = await _db.database;
    final rows = await db.query('billiard_tables', where: 'id = ?', whereArgs: [id], limit: 1);
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
    };
    await db.insert('billiard_tables', row, conflictAlgorithm: ConflictAlgorithm.replace);
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
    };
    if (payload.isEmpty) return;
    await db.update('billiard_tables', payload, where: 'id = ?', whereArgs: [id]);

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
    await db.update('billiard_tables', payload, where: 'id = ?', whereArgs: [id]);
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
      {'is_occupied': 0, 'start_time': null, 'orders': '[]'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(int id) async {
    final db = await _db.database;
    await db.delete('billiard_tables', where: 'id = ?', whereArgs: [id]);
    await _sync.deleteTableFromCloud(id);
  }

  Future<void> deleteAll({String? billarId}) async {
    final db = await _db.database;
    final where = billarId != null ? 'billar_id = ?' : null;
    final args = billarId != null ? [billarId] : null;
    await db.delete('billiard_tables', where: where, whereArgs: args);
    // Opcional: borrar todas las mesas de la nube para este billar
  }

  static String _normalizeType(String type) {
    final cleaned = type.trim();
    return _tableTypes.contains(cleaned) ? cleaned : 'Billar';
  }
}
