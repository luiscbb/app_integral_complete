import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/players/domain/entities/player_stats.dart';
import '../../features/inventory/data/repositories/product_repository.dart';
import '../../features/quick_sale/data/quick_sale_repository_impl.dart';
import '../database/database_helper.dart';
import 'inventory_movement_sync_service.dart';
import '../storage/preferences_service.dart';
import 'app_services.dart';

/// Servicio central de sincronización con Supabase.
/// Gestiona cola de reintentos, estados sync y merge bidireccional.
class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;

  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  SupabaseClient get _sup => Supabase.instance.client;

  Timer? _retryTimer;
  StreamSubscription<bool>? _connectivitySubscription;
  bool _isSyncing = false;
  bool _syncRequestedWhileRunning = false;

  SyncService._internal() {
    _connectivitySubscription = AppServices
        .connectivityService
        .connectionChanges
        .listen((online) {
          if (online) schedulePendingSync();
        });
  }

  /// Disparador para sincronizar ventas pendientes.
  void schedulePendingSync() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 3), _syncAllPending);
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 30), _syncAllPending);
  }

  /// Cancelar timer.
  void dispose() {
    _retryTimer?.cancel();
    _connectivitySubscription?.cancel();
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
    String? customerKey,
    String? existingCloudId,
    bool cancelled = false,
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
        // Anulación lógica (Etapa 3): la venta anulada se propaga a la nube.
        'cancelled': cancelled,
        if (customerKey != null) 'customer_key': customerKey,
      };

      if (cloudId != null) {
        await _sup.from('sales_history').update(saleMap).eq('id', cloudId);
      } else {
        final resp = await _sup
            .from('sales_history')
            .insert(saleMap)
            .select('id');
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
        if (item['cost_at_sale'] != null) {
          detail['cost_at_sale'] = item['cost_at_sale'];
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
    String createdBy = '',
    String cashSource = 'caja',
    bool cancelled = false,
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
        'created_by': createdBy,
        'cash_source': cashSource,
        'billar_id': billarId,
        'cancelled': cancelled,
      };

      if (cloudId != null) {
        await _sup.from('purchases').update(purchaseMap).eq('id', cloudId);
      } else {
        final resp = await _sup
            .from('purchases')
            .insert(purchaseMap)
            .select('id');
        cloudId = (resp as List).first['id'].toString();
      }

      if (existingCloudId != null) {
        await _sup
            .from('purchase_details')
            .delete()
            .eq('purchase_id', existingCloudId);
      }

      for (final item in items) {
        await _sup.from('purchase_details').insert({
          'purchase_id': cloudId,
          'product_id': item['product_id'],
          'quantity': item['quantity'],
          'cost_per_unit': item['cost_per_unit'],
          'created_by': item['created_by'] ?? createdBy,
        });
      }

      final db = await _db.database;
      await db.update(
        'purchases',
        {'synced': 1, 'cloud_id': cloudId},
        where: 'id = ?',
        whereArgs: [localPurchaseId],
      );

      debugPrint(
        '[SyncService] Compra $localPurchaseId sync OK cloudId=$cloudId',
      );
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
          final fileName =
              '${DateTime.now().millisecondsSinceEpoch}_${player.name.trim().replaceAll(' ', '_')}.jpg';
          await _sup.storage
              .from('player_avatars')
              .upload(
                fileName,
                file,
                fileOptions: const FileOptions(
                  contentType: 'image/jpeg',
                  upsert: true,
                ),
              );
          avatarUrl = _sup.storage
              .from('player_avatars')
              .getPublicUrl(fileName);
        }
      }

      final map = {
        'billar_id': billarId,
        'name': player.name,
        'nickname': player.nickname,
        'phone': player.phone,
        'avatar_url': avatarUrl,
        'handicap': player.handicap,
        'client_id': player.clientId,
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

      final response =
          player.cloudId == null
              ? await _sup
                  .from('players')
                  .upsert(map, onConflict: 'billar_id,client_id')
                  .select('id')
                  .single()
              : await _sup
                  .from('players')
                  .update(map)
                  .eq('id', player.cloudId!)
                  .select('id')
                  .maybeSingle();
      if (response == null) return null;
      final cloudId = response['id'].toString();

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

  Future<bool> pushProviderToCloud(
    Map<String, dynamic> map,
    int localId,
  ) async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return false;

      await _sup.from('providers').upsert({
        ...map,
        'id': localId,
        'billar_id': _prefs.billarId,
      });
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

      await _sup
          .from('provider_products')
          .delete()
          .eq('provider_id', providerId);
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

      final remoteProviders = await _sup
          .from('providers')
          .select()
          .eq('billar_id', _prefs.billarId);
      final remoteProducts = await _sup.from('provider_products').select();

      debugPrint(
        '[SyncService] pullProvidersFromCloud: ${remoteProviders.length} proveedores, ${remoteProducts.length} relaciones',
      );

      await db.transaction((txn) async {
        for (final p in remoteProviders) {
          final id = p['id'] as int;
          final existing = await txn.query(
            'providers',
            where: 'id = ?',
            whereArgs: [id],
            limit: 1,
          );
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
            await txn.update(
              'providers',
              map,
              where: 'id = ?',
              whereArgs: [id],
            );
          }
        }

        // Sincronizar relaciones (merge simple: borrar locales y reinsertar remotas)
        final localProviderIds =
            remoteProviders.map((p) => p['id'] as int).toSet();
        await txn.delete(
          'provider_products',
          where: 'provider_id IN (${localProviderIds.join(',')})',
        );
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
    if (_isSyncing) {
      _syncRequestedWhileRunning = true;
      return;
    }
    _isSyncing = true;

    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) {
        debugPrint('[SyncService] Sin red, auto-sync abortado');
        _scheduleRetry();
        return;
      }

      final db = await _db.database;
      final billarId = _prefs.billarId;

      await pullTablesFromCloud();

      // ── Ventas pendientes ──
      final pendingSales = await db.query(
        'sales_history',
        where: 'synced = ?',
        whereArgs: [0],
        orderBy: 'date ASC',
      );
      debugPrint('[SyncService] Ventas pendientes: ${pendingSales.length}');

      // Descargar ventas nuevas de la nube (incluye anulaciones hechas en
      // otro dispositivo) dentro del ciclo de auto-sync.
      await pullSalesFromCloud();

      // Descargar retiros/gastos hechos en otro dispositivo (afectan
      // utilidad y flujo de caja en ambos lados).
      await pullOutflowsFromCloud();

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
          cancelled: (sale['cancelled'] as int? ?? 0) == 1,
          customerKey: sale['customer_key']?.toString(),
        );

        if (cloudId == null) {
          debugPrint(
            '[SyncService] Falló sync venta $localId, se reintentará luego',
          );
        }
      }

      // ── Compras pendientes ──
      final pendingPurchases = await db.query(
        'purchases',
        where: 'synced = ?',
        whereArgs: [0],
        orderBy: 'date ASC',
      );
      debugPrint(
        '[SyncService] Compras pendientes: ${pendingPurchases.length}',
      );

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
          createdBy: (purchase['created_by'] as String?) ?? '',
          cashSource: (purchase['cash_source'] as String?) ?? 'caja',
          cancelled: (purchase['cancelled'] as int? ?? 0) == 1,
          items: details,
          existingCloudId: purchase['cloud_id'] as String?,
        );

        if (cloudId == null) {
          debugPrint(
            '[SyncService] Falló sync compra $localId, se reintentará luego',
          );
        }
      }

      // ── Jugadores pendientes ──
      final pendingPlayers = await db.query(
        'players',
        where: 'synced = ?',
        whereArgs: [0],
        orderBy: 'created_at ASC',
      );
      debugPrint(
        '[SyncService] Jugadores pendientes: ${pendingPlayers.length}',
      );

      for (final row in pendingPlayers) {
        final localId = row['id'] as int;
        final player = PlayerEntity.fromMap(row);
        final cloudId = await pushPlayerToCloud(player);
        if (cloudId != null) {
          await db.update(
            'players',
            {'synced': 1, 'cloud_id': cloudId},
            where: 'id = ?',
            whereArgs: [localId],
          );
          debugPrint('[SyncService] Jugador $localId sync OK cloudId=$cloudId');
        } else {
          debugPrint(
            '[SyncService] Falló sync jugador $localId, se reintentará luego',
          );
        }
      }

      // ── Retiros/Gastos pendientes ──
      final pendingOutflows = await db.query(
        'cash_outflows',
        where: 'synced = ?',
        whereArgs: [0],
        orderBy: 'created_at ASC',
      );
      debugPrint(
        '[SyncService] Retiros/gastos pendientes: ${pendingOutflows.length}',
      );

      for (final row in pendingOutflows) {
        final localId = row['id'] as int;
        final cloudId = await pushOutflowToCloud(
          localOutflowId: localId,
          billarId: (row['billar_id'] as String?) ?? billarId,
          outflowType: row['outflow_type'] as String,
          amount: (row['amount'] as num).toDouble(),
          description: (row['description'] as String?) ?? '',
          paymentMethod: (row['payment_method'] as String?) ?? 'Efectivo',
          createdBy: (row['created_by'] as String?) ?? '',
          createdAt: row['created_at'] as String,
          existingCloudId: row['cloud_id'] as String?,
        );
        if (cloudId != null) {
          await db.update(
            'cash_outflows',
            {'synced': 1, 'cloud_id': cloudId},
            where: 'id = ?',
            whereArgs: [localId],
          );
        } else {
          debugPrint(
            '[SyncService] Falló sync retiro $localId, se reintentará luego',
          );
        }
      }

      await ProductRepository().syncPendingProducts();
      await InventoryMovementSyncService.instance.sync();
      await QuickSaleRepositoryImpl().syncPendingSales();

      if (await _hasPendingUploads(db)) {
        debugPrint(
          '[SyncService] Quedan registros pendientes; se reintentará en 30 segundos',
        );
        _scheduleRetry();
      }
      debugPrint('[SyncService] Ciclo auto-sync completado');
    } finally {
      _isSyncing = false;
      if (_syncRequestedWhileRunning) {
        _syncRequestedWhileRunning = false;
        schedulePendingSync();
      }
    }
  }

  Future<bool> _hasPendingUploads(Database db) async {
    for (final table in [
      'sales_history',
      'purchases',
      'players',
      'cash_outflows',
      'products',
      'pending_product_deletions',
      'inventory_movements',
      'pending_sales',
      'billiard_tables',
    ]) {
      final result = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $table WHERE synced = 0',
      );
      if ((result.first['count'] as int? ?? 0) > 0) return true;
    }
    return false;
  }

  // ────────────────────────────────────────────────────────────────────
  // RETIROS / GASTOS DE CAJA
  // ────────────────────────────────────────────────────────────────────

  /// Sube un retiro/gasto local a Supabase. Devuelve el cloud_id o null.
  Future<String?> pushOutflowToCloud({
    required int localOutflowId,
    required String billarId,
    required String outflowType,
    required double amount,
    required String description,
    required String paymentMethod,
    required String createdBy,
    required String createdAt,
    String? existingCloudId,
  }) async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return null;

      debugPrint('[SyncService] pushOutflowToCloud localId=$localOutflowId');

      final payload = {
        'billar_id': billarId,
        'outflow_type': outflowType,
        'amount': amount,
        'description': description,
        'payment_method': paymentMethod,
        'created_by': createdBy,
        'created_at': createdAt,
      };

      dynamic response;
      if (existingCloudId != null) {
        response = await _sup
            .from('cash_outflows')
            .update(payload)
            .eq('id', existingCloudId)
            .select('id');
      } else {
        response = await _sup
            .from('cash_outflows')
            .insert(payload)
            .select('id');
      }

      final cloudId =
          response.isNotEmpty ? response.first['id'].toString() : null;
      debugPrint(
        '[SyncService] pushOutflowToCloud OK localId=$localOutflowId cloudId=$cloudId',
      );
      return cloudId;
    } catch (e) {
      debugPrint('[SyncService] pushOutflowToCloud ERROR: $e');
      return null;
    }
  }

  /// Descarga retiros/gastos desde Supabase y los fusiona con local
  /// (dedupe por cloud_id). Así un retiro hecho en un dispositivo se ve
  /// en la utilidad/flujo de caja del otro.
  Future<void> pullOutflowsFromCloud() async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return;

      final db = await _db.database;
      final billarId = _prefs.billarId;

      final localRows = await db.query('cash_outflows', columns: ['cloud_id']);
      final localCloudIds =
          localRows
              .map((r) => r['cloud_id']?.toString())
              .whereType<String>()
              .toSet();

      // Sin filtro de fecha, por la misma razón que ventas/compras: el reloj
      // de otro dispositivo puede ir atrás. Dedupe por cloud_id.
      final response = await _sup
          .from('cash_outflows')
          .select()
          .eq('billar_id', billarId)
          .order('created_at', ascending: false)
          .limit(200)
          .timeout(const Duration(seconds: 8));

      int nuevos = 0;
      for (final o in response) {
        final cid = o['id']?.toString();
        if (cid == null || localCloudIds.contains(cid)) continue;

        await db.insert('cash_outflows', {
          'billar_id': (o['billar_id'] as String?) ?? billarId,
          'outflow_type': o['outflow_type'] as String,
          'amount': (o['amount'] as num).toDouble(),
          'description': (o['description'] as String?) ?? '',
          'payment_method': (o['payment_method'] as String?) ?? 'Efectivo',
          'created_by': (o['created_by'] as String?) ?? '',
          'created_at': o['created_at'] as String,
          'synced': 1,
          'cloud_id': cid,
        });
        nuevos++;
      }
      if (nuevos > 0) {
        debugPrint('[SyncService] pullOutflowsFromCloud: $nuevos nuevos');
      }
    } catch (e, st) {
      debugPrint('[SyncService] pullOutflowsFromCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
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
      final localCloudIds =
          localRows
              .map((r) => r['cloud_id']?.toString())
              .whereType<String>()
              .toSet();

      // Sin filtro de fecha: el reloj de otro dispositivo puede ir atrás del
      // nuestro y el filtro .gte() se saltaba esas ventas. La deduplicación
      // por cloud_id ya evita re-insertar, así que bajar las últimas 200 es seguro.
      final response = await _sup
          .from('sales_history')
          .select('*, sale_details(*)')
          .eq('billar_id', billarId)
          .order('date', ascending: false)
          .limit(200);

      for (final sale in response) {
        final cid = sale['id']?.toString();
        if (cid == null) continue;

        // Si ya existe localmente, solo propagar el estado cancelled
        // (anulación hecha en otro dispositivo) y saltar la inserción.
        if (localCloudIds.contains(cid)) {
          final cloudCancelled =
              (sale['cancelled'] ?? false) == true || sale['cancelled'] == 1;
          if (cloudCancelled) {
            final local = await db.query(
              'sales_history',
              columns: ['id', 'cancelled'],
              where: 'cloud_id = ?',
              whereArgs: [cid],
            );
            if (local.isNotEmpty &&
                (local.first['cancelled'] as int? ?? 0) == 0) {
              await db.update(
                'sales_history',
                {'cancelled': 1},
                where: 'cloud_id = ?',
                whereArgs: [cid],
              );
              await db.update(
                'sale_details',
                {'cancelled': 1},
                where: 'sale_id = ?',
                whereArgs: [local.first['id']],
              );
              debugPrint(
                '[SyncService] Venta $cid marcada anulada desde la nube',
              );
            }
          }
          continue;
        }

        final localId = await db.insert('sales_history', {
          'billar_id': billarId,
          'total': (sale['total'] as num).toDouble(),
          'paid': (sale['paid'] as num?)?.toDouble() ?? 0,
          'date': sale['date'],
          'type': sale['type'],
          'payment_method': sale['payment_method'] ?? 'Efectivo',
          'customer_key': sale['customer_key']?.toString(),
          'cancelled':
              (sale['cancelled'] ?? false) == true || sale['cancelled'] == 1
                  ? 1
                  : 0,
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
            'cancelled':
                (d['cancelled'] ?? false) == true || d['cancelled'] == 1
                    ? 1
                    : 0,
            if (d['cost_at_sale'] != null)
              'cost_at_sale': (d['cost_at_sale'] as num).toDouble(),
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
      final localCloudIds =
          localRows
              .map((r) => r['cloud_id']?.toString())
              .whereType<String>()
              .toSet();

      // Sin filtro de fecha: el reloj de otro dispositivo puede ir atrás y el
      // filtro .gte() se saltaba esas compras. Deduplicación por cloud_id.
      final response = await _sup
          .from('purchases')
          .select('*, purchase_details(*)')
          .eq('billar_id', billarId)
          .order('date', ascending: false)
          .limit(200);

      for (final purchase in response) {
        final cid = purchase['id']?.toString();
        if (cid == null) continue;

        // Si ya existe localmente, solo propagar el estado cancelled
        // (anulación hecha en otro dispositivo) y saltar la inserción.
        if (localCloudIds.contains(cid)) {
          final cloudCancelled = (purchase['cancelled'] ?? false) == true;
          if (cloudCancelled) {
            final local = await db.query(
              'purchases',
              columns: ['id', 'cancelled'],
              where: 'cloud_id = ?',
              whereArgs: [cid],
            );
            if (local.isNotEmpty &&
                (local.first['cancelled'] as int? ?? 0) == 0) {
              await db.update(
                'purchases',
                {'cancelled': 1},
                where: 'cloud_id = ?',
                whereArgs: [cid],
              );
              await db.update(
                'purchase_details',
                {'cancelled': 1},
                where: 'purchase_id = ?',
                whereArgs: [local.first['id']],
              );
              debugPrint(
                '[SyncService] Compra $cid marcada anulada desde la nube',
              );
            }
          }
          continue;
        }

        final localId = await db.insert('purchases', {
          'provider_id': purchase['provider_id'],
          'total': (purchase['total'] as num).toDouble(),
          'date': purchase['date'],
          'reference': purchase['reference'] ?? '',
          'created_by': purchase['created_by'] ?? '',
          'cash_source': purchase['cash_source'] ?? 'caja',
          'cancelled': (purchase['cancelled'] ?? false) == true ? 1 : 0,
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
            'created_by': d['created_by'] ?? '',
            'cancelled': (d['cancelled'] ?? false) == true ? 1 : 0,
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
        'billar_id': table['billar_id'] ?? billarId,
        'name': table['name'] ?? 'Mesa $id',
        'table_type': table['table_type'] ?? 'Billar',
        'is_occupied': table['is_occupied'] ?? 0,
        'start_time': table['start_time'],
        'orders': table['orders'] ?? '[]',
        'is_deleted': table['is_deleted'] ?? 0,
      };

      await _sup.from('billiard_tables').upsert(map);
      final db = await _db.database;
      final currentRows = await db.query(
        'billiard_tables',
        where: 'id = ? AND billar_id = ?',
        whereArgs: [id, map['billar_id']],
        limit: 1,
      );
      if (currentRows.isNotEmpty &&
          currentRows.first['name'] == map['name'] &&
          currentRows.first['table_type'] == map['table_type'] &&
          currentRows.first['is_occupied'] == map['is_occupied'] &&
          currentRows.first['start_time'] == map['start_time'] &&
          currentRows.first['orders'] == map['orders'] &&
          currentRows.first['is_deleted'] == map['is_deleted']) {
        await db.update(
          'billiard_tables',
          {'synced': 1},
          where: 'id = ? AND billar_id = ?',
          whereArgs: [id, map['billar_id']],
        );
      }
      debugPrint('[SyncService] pushTableToCloud id=$id OK');
      return true;
    } catch (e, st) {
      debugPrint('[SyncService] pushTableToCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
      return false;
    }
  }

  /// Descarga mesas de Supabase y las fusiona con las locales.
  /// La eliminación se propaga como tombstone para que no reaparezca offline.
  /// Cuando [forceApply] es `true` (usado por Realtime), se sobreescribe también
  /// la mesa si está ocupada localmente, porque la nube es la fuente de verdad
  /// para propagar en tiempo real el estado entre dispositivos.
  Future<void> pullTablesFromCloud({bool forceApply = false}) async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return;

      final db = await _db.database;
      final billarId = _prefs.billarId;

      var response = await _sup
          .from('billiard_tables')
          .select()
          .eq('billar_id', billarId)
          .order('id', ascending: true);
      var tables = response as List<dynamic>;
      final remoteById = {
        for (final table in tables)
          (table['id'] as num).toInt(): table as Map<String, dynamic>,
      };
      final pendingTables = await db.query(
        'billiard_tables',
        where: 'billar_id = ? AND synced = ?',
        whereArgs: [billarId, 0],
        orderBy: 'id ASC',
      );
      for (final table in pendingTables) {
        final id = (table['id'] as num).toInt();
        final remote = remoteById[id];
        if (remote != null &&
            (remote['is_deleted'] as num?)?.toInt() == 1 &&
            (table['is_deleted'] as num?)?.toInt() != 1) {
          await db.update(
            'billiard_tables',
            {
              'is_deleted': 1,
              'is_occupied': 0,
              'start_time': null,
              'orders': '[]',
              'synced': 1,
            },
            where: 'id = ? AND billar_id = ?',
            whereArgs: [id, billarId],
          );
          continue;
        }
        await pushTableToCloud(table);
      }

      response = await _sup
          .from('billiard_tables')
          .select()
          .eq('billar_id', billarId)
          .order('id', ascending: true);
      tables = response as List<dynamic>;
      debugPrint('[SyncService] pullTablesFromCloud: ${tables.length} mesas');
      final cloudIds = <int>{};

      await db.transaction((txn) async {
        for (final t in tables) {
          final id = (t['id'] as num).toInt();
          cloudIds.add(id);
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
          final cloudDeleted = (t['is_deleted'] as num?)?.toInt() ?? 0;

          if (existing.isEmpty) {
            await txn.insert('billiard_tables', {
              'id': id,
              'billar_id': billarId,
              'name': cloudName,
              'table_type': cloudType,
              'is_occupied': cloudOccupied,
              'start_time': cloudStart,
              'orders': cloudOrders,
              'is_deleted': cloudDeleted,
              'synced': 1,
            });
          } else {
            final local = existing.first;
            if ((local['synced'] as int? ?? 1) == 0) continue;
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
                'is_deleted': cloudDeleted,
                'synced': 1,
              },
              where: 'id = ? AND billar_id = ?',
              whereArgs: [id, billarId],
            );
          }
        }

        final localRows = await txn.query(
          'billiard_tables',
          where: 'billar_id = ? AND synced = ?',
          whereArgs: [billarId, 1],
        );
        for (final local in localRows) {
          final id = (local['id'] as num).toInt();
          if (!cloudIds.contains(id)) {
            await txn.delete(
              'billiard_tables',
              where: 'id = ? AND billar_id = ? AND synced = ?',
              whereArgs: [id, billarId, 1],
            );
          }
        }
      });

      final activeTableCount =
          tables
              .where(
                (table) => ((table['is_deleted'] as num?)?.toInt() ?? 0) == 0,
              )
              .length;
      await _prefs.setTableCount(activeTableCount);
    } catch (e, st) {
      debugPrint('[SyncService] pullTablesFromCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
    }
  }
}
