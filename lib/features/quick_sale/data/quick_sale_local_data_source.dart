import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_session.dart';
import '../../../../core/storage/preferences_service.dart';
import '../domain/entities/pending_sale.dart';

class QuickSaleLocalDataSource {
  SyncSessionGuard get _guard =>
      SyncSessionGuard(Supabase.instance.client, PreferencesService());

  Future<void> savePendingSale(PendingSale sale) async {
    final session = _guard.capture();
    final db = await DatabaseHelper.instance.database;
    await db.transaction((txn) async {
      _guard.require(session);
      await txn.insert('pending_sales', {
        ...sale.toMap(),
        'actor_id': session.actorId,
        'billar_id': session.billarId,
      });
      _guard.require(session);
    });
  }

  Future<List<PendingSale>> loadPendingSales() async {
    final session = _guard.capture();
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'pending_sales',
      where: 'synced = 0 AND actor_id = ? AND billar_id = ?',
      whereArgs: [session.actorId, session.billarId],
    );
    _guard.require(session);
    return rows.map((r) => PendingSale.fromMap(r)).toList();
  }

  Future<void> markPendingSaleSynced(int id) async {
    final session = _guard.capture();
    final db = await DatabaseHelper.instance.database;
    await db.transaction((txn) async {
      _guard.require(session);
      final updated = await txn.update(
        'pending_sales',
        {'synced': 1},
        where: 'id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [id, session.actorId, session.billarId],
      );
      if (updated != 1) {
        throw StateError('La venta pendiente no pertenece a esta cuenta.');
      }
      _guard.require(session);
    });
  }

  Future<int> pendingCount() async {
    final session = _guard.capture();
    final db = await DatabaseHelper.instance.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as c FROM pending_sales '
      'WHERE synced = 0 AND actor_id = ? AND billar_id = ?',
      [session.actorId, session.billarId],
    );
    _guard.require(session);
    return result.first['c'] as int;
  }
}
