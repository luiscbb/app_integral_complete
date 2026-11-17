import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/database_helper.dart';
import '../storage/preferences_service.dart';
import 'app_services.dart';
import 'sync_session.dart';

class InventoryMovementSyncService {
  InventoryMovementSyncService._();

  static final InventoryMovementSyncService instance =
      InventoryMovementSyncService._();
  static final Random _random = Random.secure();

  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  SupabaseClient get _supabase => Supabase.instance.client;

  bool _syncing = false;

  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final session = SyncSessionGuard(_supabase, _prefs).capture();
      if (!await AppServices.connectivityService.isOnline) return;
      SyncSessionGuard(_supabase, _prefs).require(session);
      await _pushPending(session);
      SyncSessionGuard(_supabase, _prefs).require(session);
      await _pullRemote(session);
    } catch (e, st) {
      debugPrint('[InventoryMovementSync] ERROR: $e');
      debugPrint('$st');
    } finally {
      _syncing = false;
    }
  }

  Future<void> _pushPending(SyncSession session) async {
    final db = await _db.database;
    final guard = SyncSessionGuard(_supabase, _prefs);
    final billarId = session.billarId;
    final pending = await db.query(
      'inventory_movements',
      where: 'synced = ? AND billar_id = ?',
      whereArgs: [0, billarId],
      orderBy: 'created_at ASC, id ASC',
    );

    for (final movement in pending) {
      guard.require(session);
      final localId = movement['id'] as int;
      var clientId = movement['client_id'] as String?;
      if (clientId == null || clientId.isEmpty) {
        clientId = _newClientId();
        await db.update(
          'inventory_movements',
          {'client_id': clientId},
          where: 'id = ?',
          whereArgs: [localId],
        );
      }

      try {
        guard.require(session);
        final result = await _supabase
            .from('inventory_movements')
            .setHeader('Authorization', 'Bearer ${session.token}')
            .upsert({
              'client_id': clientId,
              'billar_id': billarId,
              'product_id': movement['product_id'],
              'movement_type': movement['movement_type'],
              'quantity': movement['quantity'],
              'unit_cost': movement['unit_cost'],
              'unit_price': movement['unit_price'],
              'reference_id': movement['reference_id'],
              'reference_type': movement['reference_type'],
              'notes': movement['notes'] ?? '',
              'created_at': movement['created_at'],
            }, onConflict: 'client_id')
            .select('id')
            .single()
            .timeout(const Duration(seconds: 10));

        guard.require(session);
        await db.transaction((txn) async {
          guard.require(session);
          await txn.update(
            'inventory_movements',
            {'synced': 1, 'cloud_id': result['id'].toString()},
            where: 'id = ? AND billar_id = ?',
            whereArgs: [localId, billarId],
          );
          guard.require(session);
        });
        debugPrint(
          '[InventoryMovementSync] Push local=$localId cloud=${result['id']}',
        );
      } catch (e) {
        guard.require(session);
        debugPrint(
          '[InventoryMovementSync] Push falló local=$localId; queda pendiente: $e',
        );
      }
    }
  }

  Future<void> _pullRemote(SyncSession session) async {
    final db = await _db.database;
    final guard = SyncSessionGuard(_supabase, _prefs);
    const pageSize = 500;
    var offset = 0;

    while (true) {
      guard.require(session);
      final rows = await _supabase
          .from('inventory_movements')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .select()
          .eq('billar_id', session.billarId)
          .order('created_at')
          .range(offset, offset + pageSize - 1)
          .timeout(const Duration(seconds: 10));
      guard.require(session);

      final remoteRows = List<Map<String, dynamic>>.from(rows);
      await db.transaction((txn) async {
        for (final remote in remoteRows) {
          guard.require(session);
          if (remote['billar_id'] != session.billarId || remote['id'] == null) {
            throw StateError(
              'El movimiento recibido no pertenece al billar actual.',
            );
          }
          final cloudId = remote['id'].toString();
          final clientId = remote['client_id']?.toString();
          final byCloudId = await txn.query(
            'inventory_movements',
            columns: ['id', 'synced'],
            where: 'cloud_id = ? AND billar_id = ?',
            whereArgs: [cloudId, session.billarId],
            limit: 1,
          );
          final existing =
              byCloudId.isNotEmpty
                  ? byCloudId
                  : clientId == null
                  ? <Map<String, Object?>>[]
                  : await txn.query(
                    'inventory_movements',
                    columns: ['id', 'synced'],
                    where: 'client_id = ? AND billar_id = ?',
                    whereArgs: [clientId, session.billarId],
                    limit: 1,
                  );

          final values = {
            'billar_id': remote['billar_id'],
            'product_id': remote['product_id'],
            'movement_type': remote['movement_type'],
            'quantity': remote['quantity'],
            'unit_cost': remote['unit_cost'],
            'unit_price': remote['unit_price'],
            'reference_id': remote['reference_id'],
            'reference_type': remote['reference_type'],
            'notes': remote['notes'] ?? '',
            'created_at': remote['created_at'],
            'synced': 1,
            'cloud_id': cloudId,
            'client_id': clientId,
          };

          if (existing.isEmpty) {
            await txn.insert('inventory_movements', values);
          } else {
            final localId = existing.first['id'] as int;
            if ((existing.first['synced'] as int? ?? 1) == 0) {
              await txn.update(
                'inventory_movements',
                {'cloud_id': cloudId, 'client_id': clientId, 'synced': 1},
                where: 'id = ?',
                whereArgs: [localId],
              );
            } else {
              await txn.update(
                'inventory_movements',
                values,
                where: 'id = ?',
                whereArgs: [localId],
              );
            }
          }
        }
        guard.require(session);
      });

      if (remoteRows.length < pageSize) break;
      offset += pageSize;
    }
  }

  String _newClientId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
