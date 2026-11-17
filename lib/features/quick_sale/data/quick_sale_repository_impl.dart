import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/services/sync_session.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/utils/uuid_v4.dart';
import '../domain/repositories/quick_sale_repository.dart';
import 'quick_sale_local_data_source.dart' as local;

class QuickSaleRepositoryImpl implements QuickSaleRepository {
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  SupabaseClient get _sup => Supabase.instance.client;
  SyncSessionGuard get _guard => SyncSessionGuard(_sup, _prefs);

  @override
  Future<void> saveQuickSale(String product, int quantity, double price) async {
    final session = _guard.capture();
    final db = await _db.database;
    final id = await db.transaction((txn) async {
      _guard.require(session);
      final id = await txn.insert('pending_sales', {
        'billar_id': session.billarId,
        'actor_id': session.actorId,
        'product': product,
        'quantity': quantity,
        'price': price,
        'created_at': DateTime.now().toIso8601String(),
        'synced': 0,
        'client_id': newUuidV4(),
      });
      _guard.require(session);
      return id;
    });
    unawaited(_syncSale(id, session));
    SyncService().schedulePendingSync();
  }

  Future<void> _syncSale(int localId, SyncSession session) async {
    try {
      final db = await _db.database;
      final sale = await db.transaction((txn) async {
        _guard.require(session);
        final rows = await txn.query(
          'pending_sales',
          where: 'id = ? AND synced = 0 AND actor_id = ? AND billar_id = ?',
          whereArgs: [localId, session.actorId, session.billarId],
          limit: 1,
        );
        if (rows.isEmpty) return null;
        final row = rows.single;
        var clientId = row['client_id'] as String?;
        if (clientId == null || clientId.isEmpty) {
          clientId = newUuidV4();
          await txn.update(
            'pending_sales',
            {'client_id': clientId},
            where: 'id = ? AND actor_id = ? AND billar_id = ?',
            whereArgs: [localId, session.actorId, session.billarId],
          );
        }
        _guard.require(session);
        return {...row, 'client_id': clientId};
      });
      if (sale == null) return;
      _guard.require(session);
      await _sup
          .from('pending_sales')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .upsert({
            'product': sale['product'],
            'quantity': sale['quantity'],
            'price': sale['price'],
            'billar_id': session.billarId,
            'created_at': sale['created_at'],
            'client_id': sale['client_id'],
          }, onConflict: 'client_id');
      _guard.require(session);
      await db.transaction((txn) async {
        _guard.require(session);
        await txn.update(
          'pending_sales',
          {'synced': 1},
          where: 'id = ? AND actor_id = ? AND billar_id = ? AND client_id = ?',
          whereArgs: [
            localId,
            session.actorId,
            session.billarId,
            sale['client_id'],
          ],
        );
        _guard.require(session);
      });
    } catch (error, stack) {
      debugPrint('[Supabase quick sale sync] ERROR: $error');
      if (kDebugMode) debugPrint('$stack');
    }
  }

  @override
  Future<void> syncPendingSales() async {
    try {
      final session = _guard.capture();
      final db = await _db.database;
      final pending = await db.query(
        'pending_sales',
        columns: ['id'],
        where: 'synced = 0 AND actor_id = ? AND billar_id = ?',
        whereArgs: [session.actorId, session.billarId],
      );
      for (final row in pending) {
        _guard.require(session);
        await _syncSale(row['id'] as int, session);
      }
    } on StateError catch (error) {
      debugPrint('[Sync] Ventas rápidas pendientes: $error');
    }
  }

  @override
  Future<int> pendingSyncCount() =>
      local.QuickSaleLocalDataSource().pendingCount();
}

class QuickSaleLocalDataSource extends local.QuickSaleLocalDataSource {}
