import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/players/domain/entities/player_stats.dart';
import '../database/database_helper.dart';
import '../storage/preferences_service.dart';
import 'app_services.dart';

/// Servicio central de sincronización con Supabase.
/// Gestiona cola de reintentos, estados sync y merge bidireccional.
class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  SupabaseClient get _sup => Supabase.instance.client;

  Timer? _retryTimer;
  bool _isSyncing = false;

  /// Disparador para sincronizar ventas pendientes.
  void schedulePendingSync() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 3), _syncAllPending);
  }

  /// Cancelar timer.
  void dispose() {
    _retryTimer?.cancel();
  }

  // ────────────────────────────────────────────────────────────────────
  // VENTAS
  // ────────────────────────────────────────────────────────────────────

  /// Marca una venta local como pendiente de subida.
  Future<void> markSalePending(int localSaleId) async {
    final db = await _db.database;
    await db.update(
      'sales_history',
      {'synced': 0, 'cloud_id': null},
      where: 'id = ?',
      whereArgs: [localSaleId],
    );
    schedulePendingSync();
  }

  /// Sube una venta (cabecera + detalles) a Supabase.
  /// Devuelve el cloud_id en exito, o null si falla.
  Future<String?> pushSaleToCloud({
    required int localSaleId,
    required String billarId,
    required double total,
    required double paid,
    required String date,
    required String type,
    required String paymentMethod,
    required List<Map<String, dynamic>> items,
    String? existingCloudId,
  }) async {
    try {
      debugPrint('[SyncService] pushSaleToCloud localId=$localSaleId');

      // Verificar conectividad
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) {
        debugPrint('[SyncService] Sin red, se pospone sync');
        return null;
      }

      String? cloudId = existingCloudId;

      // Upsert cabecera
      final saleMap = {
        'billar_id': billarId,
        'total': total,
        'paid': paid,
        'date': date,
        'type': type,
        'payment_method': paymentMethod,
      };

      if (cloudId != null) {
        await _sup.from('sales_history').update(saleMap).eq('id', cloudId);
      } else {
        final resp = await _sup.from('sales_history').insert(saleMap).select('id');
        cloudId = (resp as List).first['id'].toString();
      }

      // Sincronizar detalles: eliminar previos y reinsertar
      if (existingCloudId != null) {
        await _sup.from('sale_details').delete().eq('sale_id', existingCloudId);
      }

      for (final item in items) {
        final detail = {
          'sale_id': cloudId,
          'product_name': item['product_name'],
          'quantity': item['quantity'],
          'price_at_sale': item['price_at_sale'],
        };
        if (item['product_id'] != null) {
          detail['product_id'] = item['product_id'];
        }
        await _sup.from('sale_details').insert(detail);
      }

      // Marcar local como sync
      final db = await _db.database;
      await db.update(
        'sales_history',
        {'synced': 1, 'cloud_id': cloudId},
        where: 'id = ?',
        whereArgs: [localSaleId],
      );

      debugPrint('[SyncService] Venta $localSaleId sync OK cloudId=$cloudId');
      return cloudId;
    } catch (e, st) {
      debugPrint('[SyncService] pushSaleToCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
      return null;
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // COMPRAS
  // ────────────────────────────────────────────────────────────────────

  /// Marca una compra local como pendiente de subida.
  Future<void> markPurchasePending(int localPurchaseId) async {
    final db = await _db.database;
    await db.update(
      'purchases',
      {'synced': 0, 'cloud_id': null},
      where: 'id = ?',
      whereArgs: [localPurchaseId],
    );
    schedulePendingSync();
  }

  /// Sube una compra (cabecera + detalles) a Supabase.
  Future<String?> pushPurchaseToCloud({
    required int localPurchaseId,
    required String billarId,
    required int? providerId,
    required double total,
    required String date,
    required String reference,
    required List<Map<String, dynamic>> items,
    String? existingCloudId,
  }) async {
    try {
      debugPrint('[SyncService] pushPurchaseToCloud localId=$localPurchaseId');

      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) {
        debugPrint('[SyncService] Sin red, se pospone sync');
        return null;
      }

      String? cloudId = existingCloudId;
      final purchaseMap = {
        'provider_id': providerId,
        'total': total,
        'date': date,
        'reference': reference,
        'billar_id': billarId,
      };

      if (cloudId != null) {
        await _sup.from('purchases').update(purchaseMap).eq('id', cloudId);
      } else {
        final resp = await _sup.from('purchases').insert(purchaseMap).select('id');
        cloudId = (resp as List).first['id'].toString();
      }

      if (existingCloudId != null) {
        await _sup.from('purchase_details').delete().eq('purchase_id', existingCloudId);
      }

      for (final item in items) {
        await _sup.from('purchase_details').insert({
          'purchase_id': cloudId,
          'product_id': item['product_id'],
          'quantity': item['quantity'],
          'cost_per_unit': item['cost_per_unit'],
        });
      }

      final db = await _db.database;
      await db.update(
        'purchases',
        {'synced': 1, 'cloud_id': cloudId},
        where: 'id = ?',
        whereArgs: [localPurchaseId],
      );

      debugPrint('[SyncService] Compra $localPurchaseId sync OK cloudId=$cloudId');
      return cloudId;
    } catch (e, st) {
      debugPrint('[SyncService] pushPurchaseToCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
      return null;
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // JUGADORES
  // ────────────────────────────────────────────────────────────────────

  Future<String?> pushPlayerToCloud(PlayerEntity player) async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return null;

      final billarId = _prefs.billarId;
      String? avatarUrl = player.avatar;

      if (player.avatar.isNotEmpty && !player.avatar.startsWith('http')) {
        final file = File(player.avatar);
        if (await file.exists()) {
          final fileName = '${DateTime.now().millisecondsSinceEpoch}_${player.name.trim().replaceAll(' ', '_')}.jpg';
          await _sup.storage.from('player_avatars').upload(
            fileName,
            file,
            fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
          );
          avatarUrl = _sup.storage.from('player_avatars').getPublicUrl(fileName);
        }
      }

      final map = {
        'billar_id': billarId,
        'name': player.name,
        'nickname': player.nickname,
        'avatar_url': avatarUrl,
        'handicap': player.level,
        'wins': player.stats.wins,
        'losses': player.stats.losses,
        'draws': player.stats.draws,
        'total_matches': player.stats.totalMatches,
        'total_seconds': player.totalSeconds,
        'break_and_run': player.stats.breakAndRun,
        'golden_breaks': player.stats.goldenBreaks,
        'high_run': player.stats.highRun,
        'current_streak': player.stats.currentStreak,
        'best_streak': player.stats.bestStreak,
      };

      final resp = await _sup.from('players').insert(map).select('id');
      final cloudId = (resp as List).first['id'].toString();

      debugPrint('[SyncService] Player pushed OK cloudId=$cloudId');
      return cloudId;
    } catch (e, st) {
      debugPrint('[SyncService] pushPlayerToCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
      return null;
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // PROVEEDORES
  // ────────────────────────────────────────────────────────────────────

  Future<bool> pushProviderToCloud(Map<String, dynamic> map, int localId) async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return false;

      await _sup.from('providers').upsert({...map, 'id': localId, 'billar_id': _prefs.billarId});
      return true;
    } catch (e) {
      debugPrint('[SyncService] pushProvider ERROR: $e');
      return false;
    }
  }

  Future<bool> pushProviderProductsToCloud(int providerId) async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return false;

      final db = await _db.database;
      final rows = await db.query(
        'provider_products',
        columns: ['product_id'],
        where: 'provider_id = ?',
        whereArgs: [providerId],
      );
      final productIds = rows.map((r) => r['product_id'] as int).toList();

      await _sup.from('provider_products').delete().eq('provider_id', providerId);
      for (final productId in productIds) {
        await _sup.from('provider_products').insert({
          'provider_id': providerId,
          'product_id': productId,
        });
      }
      return true;
    } catch (e) {
      debugPrint('[SyncService] pushProviderProducts ERROR: $e');
      return false;
    }
  }

  Future<bool> deleteProviderFromCloud(int localId) async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return false;

      await _sup.from('provider_products').delete().eq('provider_id', localId);
      await _sup.from('providers').delete().eq('id', localId);
      return true;
    } catch (e) {
      debugPrint('[SyncService] deleteProvider ERROR: $e');
      return false;
    }
  }

  Future<void> pullProvidersFromCloud() async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return;

      final db = await _db.database;

      final remoteProviders = await _sup.from('providers').select().eq('billar_id', _prefs.billarId);
      final remoteProducts = await _sup.from('provider_products').select();

      debugPrint('[SyncService] pullProvidersFromCloud: ${remoteProviders.length} proveedores, ${remoteProducts.length} relaciones');

      await db.transaction((txn) async {
        for (final p in remoteProviders) {
          final id = p['id'] as int;
          final existing = await txn.query('providers', where: 'id = ?', whereArgs: [id], limit: 1);
          final map = {
            'name': p['name'] ?? '',
            'phone': p['phone'] ?? '',
            'email': p['email'] ?? '',
            'address': p['address'] ?? '',
            'contact_name': p['contact_name'] ?? '',
            'notes': p['notes'] ?? '',
            'category': p['category'] ?? 'General',
            'visit_days': p['visit_days'] ?? '',
          };
          if (existing.isEmpty) {
            await txn.insert('providers', {'id': id, ...map});
          } else {
            await txn.update('providers', map, where: 'id = ?', whereArgs: [id]);
          }
        }

        // Sincronizar relaciones (merge simple: borrar locales y reinsertar remotas)
        final localProviderIds = remoteProviders.map((p) => p['id'] as int).toSet();
        await txn.delete('provider_products', where: 'provider_id IN (${localProviderIds.join(',')})');
        for (final rp in remoteProducts) {
          final pid = rp['provider_id'] as int?;
          final prid = rp['product_id'] as int?;
          if (pid == null || prid == null) continue;
          await txn.insert('provider_products', {
            'provider_id': pid,
            'product_id': prid,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      });
    } catch (e, st) {
      debugPrint('[SyncService] pullProvidersFromCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // AUTO-SYNC PENDIENTES
  // ────────────────────────────────────────────────────────────────────

  /// Sincroniza manualmente los datos pendientes. Público para permitir
  /// su uso antes de cerrar sesión u otras acciones explícitas.
  Future<void> syncAllPending() async => _syncAllPending();

  Future<void> _syncAllPending() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) {
        debugPrint('[SyncService] Sin red, auto-sync abortado');
        return;
      }

      final db = await _db.database;
      final billarId = _prefs.billarId;

      // ── Ventas pendientes ──
      final pendingSales = await db.query(
        'sales_history',
        where: 'synced = ?',
        whereArgs: [0],
        orderBy: 'date ASC',
      );
      debugPrint('[SyncService] Ventas pendientes: ${pendingSales.length}');

      for (final sale in pendingSales) {
        final localId = sale['id'] as int;
        final details = await db.query(
          'sale_details',
          where: 'sale_id = ?',
          whereArgs: [localId],
        );

        final cloudId = await pushSaleToCloud(
          localSaleId: localId,
          billarId: billarId,
          total: (sale['total'] as num).toDouble(),
          paid: (sale['paid'] as num).toDouble(),
          date: sale['date'] as String,
          type: sale['type'] as String,
          paymentMethod: sale['payment_method'] as String,
          items: details,
          existingCloudId: sale['cloud_id'] as String?,
        );

        if (cloudId == null) {
          debugPrint('[SyncService] Falló sync venta $localId, se reintentará luego');
        }
      }

      // ── Compras pendientes ──
      final pendingPurchases = await db.query(
        'purchases',
        where: 'synced = ?',
        whereArgs: [0],
        orderBy: 'date ASC',
      );
      debugPrint('[SyncService] Compras pendientes: ${pendingPurchases.length}');

      for (final purchase in pendingPurchases) {
        final localId = purchase['id'] as int;
        final details = await db.query(
          'purchase_details',
          where: 'purchase_id = ?',
          whereArgs: [localId],
        );

        final cloudId = await pushPurchaseToCloud(
          localPurchaseId: localId,
          billarId: billarId,
          providerId: purchase['provider_id'] as int?,
          total: (purchase['total'] as num).toDouble(),
          date: purchase['date'] as String,
          reference: purchase['reference'] as String,
          items: details,
          existingCloudId: purchase['cloud_id'] as String?,
        );

        if (cloudId == null) {
          debugPrint('[SyncService] Falló sync compra $localId, se reintentará luego');
        }
      }

      // ── Jugadores pendientes ──
      final pendingPlayers = await db.query(
        'players',
        where: 'synced = ?',
        whereArgs: [0],
        orderBy: 'created_at ASC',
      );
      debugPrint('[SyncService] Jugadores pendientes: ${pendingPlayers.length}');

      for (final row in pendingPlayers) {
        final localId = row['id'] as int;
        final player = PlayerEntity.fromMap(row);
        final cloudId = await pushPlayerToCloud(player);
        if (cloudId != null) {
          await db.update('players', {'synced': 1, 'cloud_id': cloudId}, where: 'id = ?', whereArgs: [localId]);
          debugPrint('[SyncService] Jugador $localId sync OK cloudId=$cloudId');
        } else {
          debugPrint('[SyncService] Falló sync jugador $localId, se reintentará luego');
        }
      }

      debugPrint('[SyncService] Ciclo auto-sync completado');
    } finally {
      _isSyncing = false;
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // DESCARGA DESDE NUBE (para desktop / nuevos dispositivos)
  // ────────────────────────────────────────────────────────────────────

  /// Descarga ventas desde Supabase para el billar actual y las fusiona con local.
  /// Solo descarga lo que no existe localmente (por cloud_id).
  Future<void> pullSalesFromCloud() async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return;

      final db = await _db.database;
      final billarId = _prefs.billarId;

      // Obtener cloud_ids locales para evitar duplicados
      final localRows = await db.query('sales_history', columns: ['cloud_id']);
      final localCloudIds = localRows
          .map((r) => r['cloud_id']?.toString())
          .whereType<String>()
          .toSet();

      // Última fecha sync
      final lastRow = await db.rawQuery(
        "SELECT MAX(date) as last FROM sales_history WHERE synced = 1"
      );
      final lastDate = lastRow.first['last'] as String?;

      var query = _sup
          .from('sales_history')
          .select('*, sale_details(*)')
          .eq('billar_id', billarId)
          .gte('date', lastDate ?? '1970-01-01T00:00:00Z')
          .order('date', ascending: false)
          .limit(200);

      final response = await query;

      for (final sale in response) {
        final cid = sale['id']?.toString();
        if (cid == null || localCloudIds.contains(cid)) continue;

        final localId = await db.insert('sales_history', {
          'billar_id': billarId,
          'total': (sale['total'] as num).toDouble(),
          'paid': (sale['paid'] as num?)?.toDouble() ?? 0,
          'date': sale['date'],
          'type': sale['type'],
          'payment_method': sale['payment_method'] ?? 'Efectivo',
          'synced': 1,
          'cloud_id': cid,
        });

        final details = sale['sale_details'] as List? ?? [];
        for (final d in details) {
          await db.insert('sale_details', {
            'sale_id': localId,
            'product_id': d['product_id'],
            'product_name': d['product_name'],
            'quantity': (d['quantity'] as num).toDouble(),
            'price_at_sale': (d['price_at_sale'] as num).toDouble(),
          });
        }
      }

      debugPrint('[SyncService] pullSalesFromCloud completado');
    } catch (e, st) {
      debugPrint('[SyncService] pullSalesFromCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
    }
  }

  /// Descarga compras desde Supabase para el billar actual.
  Future<void> pullPurchasesFromCloud() async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return;

      final db = await _db.database;
      final billarId = _prefs.billarId;

      final localRows = await db.query('purchases', columns: ['cloud_id']);
      final localCloudIds = localRows
          .map((r) => r['cloud_id']?.toString())
          .whereType<String>()
          .toSet();

      final lastRow = await db.rawQuery(
        "SELECT MAX(date) as last FROM purchases WHERE synced = 1"
      );
      final lastDate = lastRow.first['last'] as String?;

      var query = _sup
          .from('purchases')
          .select('*, purchase_details(*)')
          .eq('billar_id', billarId)
          .gte('date', lastDate ?? '1970-01-01T00:00:00Z')
          .order('date', ascending: false)
          .limit(200);

      final response = await query;

      for (final purchase in response) {
        final cid = purchase['id']?.toString();
        if (cid == null || localCloudIds.contains(cid)) continue;

        final localId = await db.insert('purchases', {
          'provider_id': purchase['provider_id'],
          'total': (purchase['total'] as num).toDouble(),
          'date': purchase['date'],
          'reference': purchase['reference'] ?? '',
          'synced': 1,
          'cloud_id': cid,
        });

        final details = purchase['purchase_details'] as List? ?? [];
        for (final d in details) {
          await db.insert('purchase_details', {
            'purchase_id': localId,
            'product_id': d['product_id'],
            'quantity': (d['quantity'] as num).toDouble(),
            'cost_per_unit': (d['cost_per_unit'] as num).toDouble(),
          });
        }
      }

      debugPrint('[SyncService] pullPurchasesFromCloud completado');
    } catch (e, st) {
      debugPrint('[SyncService] pullPurchasesFromCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // MESAS DE BILLAR
  // ────────────────────────────────────────────────────────────────────

  /// Sube o actualiza una mesa en Supabase.
  Future<bool> pushTableToCloud(Map<String, dynamic> table) async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return false;

      final billarId = _prefs.billarId;
      final id = table['id'] as int;
      final map = {
        'id': id,
        'billar_id': billarId,
        'name': table['name'] ?? 'Mesa $id',
        'table_type': table['table_type'] ?? 'Pool',
        'is_occupied': table['is_occupied'] ?? 0,
        'start_time': table['start_time'],
        'orders': table['orders'] ?? '[]',
      };

      await _sup.from('billiard_tables').upsert(map);
      debugPrint('[SyncService] pushTableToCloud id=$id OK');
      return true;
    } catch (e, st) {
      debugPrint('[SyncService] pushTableToCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
      return false;
    }
  }

  /// Borra una mesa de Supabase.
  Future<bool> deleteTableFromCloud(int id) async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return false;

      await _sup.from('billiard_tables').delete().eq('billar_id', _prefs.billarId).eq('id', id);
      return true;
    } catch (e) {
      debugPrint('[SyncService] deleteTableFromCloud ERROR: $e');
      return false;
    }
  }

  /// Descarga mesas de Supabase y las fusiona con las locales.
  /// Solo actualiza/inserta; nunca borra mesas ocupadas ni locales no sincronizadas.
  /// Cuando [forceApply] es `true` (usado por Realtime), se sobreescribe también
  /// la mesa si está ocupada localmente, porque la nube es la fuente de verdad
  /// para propagar en tiempo real el estado entre dispositivos.
  Future<void> pullTablesFromCloud({bool forceApply = false}) async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return;

      final db = await _db.database;
      final billarId = _prefs.billarId;

      final response = await _sup
          .from('billiard_tables')
          .select()
          .eq('billar_id', billarId)
          .order('id', ascending: true);

      final tables = response as List<dynamic>;
      debugPrint('[SyncService] pullTablesFromCloud: ${tables.length} mesas');

      if (tables.isEmpty) return;

      await db.transaction((txn) async {
        for (final t in tables) {
          final id = t['id'] as int;
          final existing = await txn.query(
            'billiard_tables',
            where: 'id = ? AND billar_id = ?',
            whereArgs: [id, billarId],
            limit: 1,
          );

          final cloudName = t['name']?.toString() ?? 'Mesa $id';
          final cloudType = t['table_type']?.toString() ?? 'Pool';
          final cloudOccupied = (t['is_occupied'] as num?)?.toInt() ?? 0;
          final cloudStart = t['start_time']?.toString();
          final cloudOrders = t['orders']?.toString() ?? '[]';

          if (existing.isEmpty) {
            await txn.insert('billiard_tables', {
              'id': id,
              'billar_id': billarId,
              'name': cloudName,
              'table_type': cloudType,
              'is_occupied': cloudOccupied,
              'start_time': cloudStart,
              'orders': cloudOrders,
            });
          } else {
            final local = existing.first;
            final localOccupied = (local['is_occupied'] as num?)?.toInt() ?? 0;
            // Por defecto no sobreescribir mesa ocupada localmente para evitar
            // perder ordenes/tiempo. Con forceApply (Realtime) la nube manda.
            if (!forceApply && localOccupied == 1) continue;
            await txn.update(
              'billiard_tables',
              {
                'name': cloudName,
                'table_type': cloudType,
                'is_occupied': cloudOccupied,
                'start_time': cloudStart,
                'orders': cloudOrders,
              },
              where: 'id = ? AND billar_id = ?',
              whereArgs: [id, billarId],
            );
          }
        }
      });

      // Ajustar tableCount a la cantidad maxima de ids descargados
      final maxId = tables.isEmpty
          ? 0
          : tables.map((t) => (t['id'] as num).toInt()).reduce((a, b) => a > b ? a : b);
      if (maxId > 0) {
        await _prefs.setTableCount(maxId);
      }
    } catch (e, st) {
      debugPrint('[SyncService] pullTablesFromCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
    }
  }
}
