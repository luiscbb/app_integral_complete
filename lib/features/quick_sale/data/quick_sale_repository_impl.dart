import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/storage/preferences_service.dart';
import '../domain/entities/pending_sale.dart';
import '../domain/repositories/quick_sale_repository.dart';

class QuickSaleRepositoryImpl implements QuickSaleRepository {
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  SupabaseClient get _sup => Supabase.instance.client;

  @override
  Future<void> saveQuickSale(String product, int quantity, double price) async {
    final db = await _db.database;
    final clientId = _newClientId();
    final id = await db.insert('pending_sales', {
      'product': product,
      'quantity': quantity,
      'price': price,
      'created_at': DateTime.now().toIso8601String(),
      'synced': 0,
      'client_id': clientId,
    });
    unawaited(_syncSale(id, product, quantity, price, clientId));
    SyncService().schedulePendingSync();
  }

  String _newClientId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _syncSale(int localId, String product, int quantity, double price, String? clientId) async {
    try {
      final billarId = _prefs.billarId;
      debugPrint('[Sync] Subiendo quick sale: $product para billar: $billarId');

      var stableClientId = clientId;
      if (stableClientId == null || stableClientId.isEmpty) {
        stableClientId = _newClientId();
        final db = await _db.database;
        await db.update(
          'pending_sales',
          {'client_id': stableClientId},
          where: 'id = ?',
          whereArgs: [localId],
        );
      }

      await _sup.from('pending_sales').upsert({
        'product': product,
        'quantity': quantity,
        'price': price,
        'billar_id': billarId,
        'created_at': DateTime.now().toIso8601String(),
        'client_id': stableClientId,
      }, onConflict: 'client_id');
      final db = await _db.database;
      await db.update('pending_sales', {'synced': 1}, where: 'id = ?', whereArgs: [localId]);
      debugPrint('[Sync] Quick sale sincronizado: $product');
    } catch (e) {
      debugPrint('[Supabase quick sale sync] ERROR: $e');
    }
  }

  @override
  Future<void> syncPendingSales() async {
    final db = await _db.database;
    final pending = await db.query('pending_sales', where: 'synced = 0');
    for (final row in pending) {
      await _syncSale(
        row['id'] as int,
        row['product'] as String,
        row['quantity'] as int,
        (row['price'] as num).toDouble(),
        row['client_id'] as String?,
      );
    }
  }

  @override
  Future<int> pendingSyncCount() async {
    final db = await _db.database;
    final result = await db.rawQuery('SELECT COUNT(*) as c FROM pending_sales WHERE synced = 0');
    return (result.first['c'] as int?) ?? 0;
  }
}

class QuickSaleLocalDataSource {
  Future<List<PendingSale>> loadPendingSales() async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('pending_sales', where: 'synced = 0');
    return rows.map((r) => PendingSale.fromMap(r)).toList();
  }
}
