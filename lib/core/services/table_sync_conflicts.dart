import 'dart:convert';

import 'package:sqflite/sqflite.dart';

class TableSyncConflicts {
  static Future<bool> contains(
    DatabaseExecutor db,
    String actorId,
    String billarId,
    int tableId,
  ) async {
    final rows = await db.query(
      'table_sync_conflicts',
      columns: ['id'],
      where: 'actor_id = ? AND billar_id = ? AND table_id = ?',
      whereArgs: [actorId, billarId, tableId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<Set<int>> tableIds(
    DatabaseExecutor db,
    String actorId,
    String billarId,
  ) async {
    final rows = await db.query(
      'table_sync_conflicts',
      columns: ['table_id'],
      distinct: true,
      where: 'actor_id = ? AND billar_id = ?',
      whereArgs: [actorId, billarId],
    );
    return rows.map((row) => row['table_id'] as int).toSet();
  }

  static Future<void> record(
    DatabaseExecutor db,
    String actorId,
    String billarId,
    int tableId,
    Map<String, dynamic> payload,
  ) async {
    await db.insert('table_sync_conflicts', {
      'actor_id': actorId,
      'billar_id': billarId,
      'table_id': tableId,
      'payload': jsonEncode(payload),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> recordRemoteDeletion(
    DatabaseExecutor db,
    String actorId,
    String billarId,
    int tableId,
    Map<String, Object?> local,
    Map<String, dynamic> remote,
  ) {
    return record(db, actorId, billarId, tableId, {
      'kind': 'remote_deleted',
      'local': local,
      'remote': remote,
    });
  }
}
