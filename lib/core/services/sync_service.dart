import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/players/domain/entities/player_stats.dart';
import '../../features/purchases/domain/entities/provider_entity.dart';
import '../../features/inventory/data/repositories/product_repository.dart';
import '../../features/quick_sale/data/quick_sale_repository_impl.dart';
import '../database/database_helper.dart';
import '../database/purchase_scope.dart';
import 'inventory_movement_sync_service.dart';
import 'owner_transaction_outbox.dart';
import '../storage/preferences_service.dart';
import '../utils/uuid_v4.dart';
import 'app_services.dart';
import 'business_image_paths.dart';
import 'sync_session.dart';
import 'table_sync_conflicts.dart';

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
  final Map<int, Future<bool>> _providerOperations = {};

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
    if (!_db.isAccountDatabaseAvailable) return;
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
      {'synced': 0},
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
    required String accessToken,
  }) async {
    try {
      debugPrint('[SyncService] pushSaleToCloud localId=$localSaleId');

      final session = _syncSession();
      if (session.billarId != billarId || session.token != accessToken) {
        throw StateError('La venta no corresponde a la sesión actual.');
      }
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) {
        debugPrint('[SyncService] Sin red, se pospone sync');
        return null;
      }
      _requireSyncSession(session);
      final db = await _db.database;
      final outbox = OwnerTransactionOutbox(db, _requireSyncSession);
      final request = await outbox.prepare(
        session: session,
        kind: 'sale',
        localId: localSaleId,
      );
      _requireSyncSession(session);
      final response = await _sup
          .rpc(
            'sync_owner_sale',
            params: {
              'p_request_id': request.requestId,
              'p_billar_id': billarId,
              ...request.payload,
            },
          )
          .setHeader('Authorization', 'Bearer $accessToken');
      if (response is! int || response <= 0) {
        throw StateError('La respuesta de la venta no es válida.');
      }
      final cloudId = response.toString();
      final unchanged = await outbox.acknowledge(
        session: session,
        kind: 'sale',
        localId: localSaleId,
        request: request,
        cloudId: cloudId,
      );
      if (!unchanged) schedulePendingSync();
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
    final updated = await db.update(
      'purchases',
      {'synced': 0},
      where: 'id = ? AND ${purchaseBusinessScope()}',
      whereArgs: [localPurchaseId, _prefs.billarId],
    );
    if (updated != 1) {
      throw StateError('La compra no pertenece al billar actual o no existe.');
    }
    schedulePendingSync();
  }

  /// Sube una compra (cabecera + detalles) a Supabase.
  Future<String?> pushPurchaseToCloud({
    required int localPurchaseId,
    required String billarId,
    required String accessToken,
  }) async {
    try {
      debugPrint('[SyncService] pushPurchaseToCloud localId=$localPurchaseId');

      final session = _syncSession();
      if (session.billarId != billarId || session.token != accessToken) {
        throw StateError('La compra no corresponde a la sesión actual.');
      }
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) {
        debugPrint('[SyncService] Sin red, se pospone sync');
        return null;
      }
      _requireSyncSession(session);
      final db = await _db.database;
      final outbox = OwnerTransactionOutbox(db, _requireSyncSession);
      final request = await outbox.prepare(
        session: session,
        kind: 'purchase',
        localId: localPurchaseId,
      );
      _requireSyncSession(session);
      final header = request.payload['p_purchase'];
      if (header is! Map<String, dynamic>) {
        throw StateError('La cabecera de compra pendiente no es válida.');
      }
      final response = await _sup
          .rpc(
            header.containsKey('payment_condition')
                ? 'sync_owner_purchase_with_payment'
                : 'sync_owner_purchase',
            params: {
              'p_request_id': request.requestId,
              'p_billar_id': billarId,
              ...request.payload,
            },
          )
          .setHeader('Authorization', 'Bearer $accessToken');
      if (response is! int || response <= 0) {
        throw StateError('La respuesta de la compra no es válida.');
      }
      final cloudId = response.toString();
      final unchanged = await outbox.acknowledge(
        session: session,
        kind: 'purchase',
        localId: localPurchaseId,
        request: request,
        cloudId: cloudId,
      );
      if (!unchanged) schedulePendingSync();
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
      final guard = SyncSessionGuard(_sup, _prefs);
      final session = guard.capture();
      final billarId = session.billarId;
      if (player.billarId != billarId) {
        throw StateError(
          'El jugador no pertenece a la sesión o al billar actual.',
        );
      }
      void requireSameSession() => guard.require(session);
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return null;
      requireSameSession();

      String? avatarUrl = player.avatar;

      if (player.avatar.isNotEmpty && !player.avatar.startsWith('http')) {
        final file = File(player.avatar);
        if (await file.exists()) {
          requireSameSession();
          final fileName = businessImagePath(
            billarId,
            'avatars',
            '${newUuidV4()}.jpg',
          );
          await _sup.storage
              .from('player_avatars')
              .setHeader('Authorization', 'Bearer ${session.token}')
              .upload(
                fileName,
                file,
                fileOptions: const FileOptions(
                  contentType: 'image/jpeg',
                  upsert: true,
                ),
              );
          requireSameSession();
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

      requireSameSession();
      final response =
          player.cloudId == null
              ? await _sup
                  .from('players')
                  .setHeader('Authorization', 'Bearer ${session.token}')
                  .upsert(map, onConflict: 'billar_id,client_id')
                  .select('id')
                  .single()
              : await _sup
                  .from('players')
                  .setHeader('Authorization', 'Bearer ${session.token}')
                  .update(map)
                  .eq('id', player.cloudId!)
                  .eq('billar_id', billarId)
                  .select('id')
                  .maybeSingle();
      requireSameSession();
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

  SyncSession _syncSession() {
    return SyncSessionGuard(_sup, _prefs).capture();
  }

  SyncSession captureProviderSession() => _syncSession();

  void requireProviderSession(SyncSession session) =>
      _requireSyncSession(session);

  void _requireSyncSession(SyncSession expected) {
    SyncSessionGuard(_sup, _prefs).require(expected);
  }

  Future<void> _requireRemoteProvider(
    int providerId,
    SyncSession session,
  ) async {
    _requireSyncSession(session);
    final provider =
        await _sup
            .from('providers')
            .setHeader('Authorization', 'Bearer ${session.token}')
            .select('id')
            .eq('id', providerId)
            .eq('billar_id', session.billarId)
            .maybeSingle();
    _requireSyncSession(session);
    if (provider == null) {
      throw StateError('El proveedor no está disponible en este billar.');
    }
  }

  Future<bool> _queueProviderOperation(
    int providerId,
    String operationName,
    Future<bool> Function(SyncSession) operation,
  ) async {
    final SyncSession session;
    try {
      session = _syncSession();
    } catch (error) {
      debugPrint('[SyncService] $operationName ERROR: $error');
      return false;
    }
    final previous = _providerOperations[providerId];
    final current = () async {
      if (previous != null) await previous;
      try {
        _requireSyncSession(session);
        return await operation(session);
      } catch (error) {
        debugPrint('[SyncService] $operationName ERROR: $error');
        return false;
      }
    }();
    _providerOperations[providerId] = current;
    try {
      return await current;
    } finally {
      if (identical(_providerOperations[providerId], current)) {
        _providerOperations.remove(providerId);
      }
    }
  }

  Future<bool> pushProviderToCloud(Map<String, dynamic> map, int localId) {
    return _queueProviderOperation(localId, 'pushProvider', (session) async {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return false;
      _requireSyncSession(session);

      final payload = {...map, 'id': localId, 'billar_id': session.billarId};
      final updated = await _sup
          .from('providers')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .update(payload)
          .eq('id', localId)
          .eq('billar_id', session.billarId)
          .select('id');
      _requireSyncSession(session);
      if (updated.isEmpty) {
        await _sup
            .from('providers')
            .setHeader('Authorization', 'Bearer ${session.token}')
            .insert(payload);
        _requireSyncSession(session);
      }
      return true;
    });
  }

  Future<bool> pushProviderProductsToCloud(
    int providerId, {
    List<int>? products,
  }) {
    return _queueProviderOperation(providerId, 'pushProviderProducts', (
      session,
    ) async {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return false;
      _requireSyncSession(session);

      final db = await _db.database;
      final productIds =
          products ??
          (await db.query(
            'provider_products',
            columns: ['product_id'],
            where: 'provider_id = ?',
            whereArgs: [providerId],
          )).map((r) => r['product_id'] as int).toList();
      for (final productId in productIds) {
        final products = await db.query(
          'products',
          columns: ['id'],
          where: 'id = ? AND billar_id = ?',
          whereArgs: [productId, session.billarId],
          limit: 1,
        );
        if (products.isEmpty) {
          throw StateError('Un producto no pertenece al billar actual.');
        }
      }
      await _requireRemoteProvider(providerId, session);

      await _sup
          .from('provider_products')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .delete()
          .eq('provider_id', providerId);
      _requireSyncSession(session);
      for (final productId in productIds) {
        await _sup
            .from('provider_products')
            .setHeader('Authorization', 'Bearer ${session.token}')
            .insert({'provider_id': providerId, 'product_id': productId});
        _requireSyncSession(session);
      }
      return true;
    });
  }

  Future<bool> archiveProviderInCloud(int localId, String requestId) {
    return _queueProviderOperation(localId, 'archiveProvider', (session) async {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return false;
      _requireSyncSession(session);
      final response = await _sup
          .rpc(
            'archive_provider_idempotent',
            params: {
              'p_request_id': requestId,
              'p_billar_id': session.billarId,
              'p_provider_id': localId,
            },
          )
          .setHeader('Authorization', 'Bearer ${session.token}');
      _requireSyncSession(session);
      if (response is! Map ||
          response['request_id'] != requestId ||
          response['billar_id'] != session.billarId ||
          response['provider_id'] != localId ||
          response['archived'] != true) {
        throw StateError('La confirmación de archivado no es válida.');
      }
      return true;
    });
  }

  Future<void> pullProvidersFromCloud() async {
    try {
      final session = _syncSession();
      final billarId = session.billarId;
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return;
      _requireSyncSession(session);

      final db = await _db.database;

      final remoteProviders = await _sup
          .from('providers')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .select()
          .eq('billar_id', billarId);
      _requireSyncSession(session);
      final providerIds = <int>{};
      for (final provider in remoteProviders) {
        if (provider['billar_id'] != billarId || provider['id'] is! int) {
          throw StateError(
            'La respuesta contiene un proveedor de otro billar.',
          );
        }
        if (provider.containsKey('is_active') &&
            provider['is_active'] is! bool) {
          throw StateError('El estado del proveedor recibido no es válido.');
        }
        providerIds.add(provider['id'] as int);
      }
      final remoteProducts =
          providerIds.isEmpty
              ? <Map<String, dynamic>>[]
              : await _sup
                  .from('provider_products')
                  .setHeader('Authorization', 'Bearer ${session.token}')
                  .select()
                  .inFilter('provider_id', providerIds.toList());
      _requireSyncSession(session);

      debugPrint(
        '[SyncService] pullProvidersFromCloud: ${remoteProviders.length} proveedores, ${remoteProducts.length} relaciones',
      );

      await db.transaction((txn) async {
        final pending = await txn.query(
          'pending_provider_operations',
          columns: ['provider_id'],
          distinct: true,
        );
        final pendingProviderIds =
            pending.map((row) => row['provider_id'] as int).toSet();
        for (final p in remoteProviders) {
          _requireSyncSession(session);
          final id = p['id'] as int;
          if (pendingProviderIds.contains(id)) continue;
          final provider = ProviderEntity.fromMap(p);
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
            if (p.containsKey('credit_days'))
              'credit_days': provider.creditDays,
            if (p.containsKey('preferred_payment_method'))
              'preferred_payment_method': provider.preferredPaymentMethod,
            'is_active': p['is_active'] == false ? 0 : 1,
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

        for (final rp in remoteProducts) {
          _requireSyncSession(session);
          final pid = rp['provider_id'] as int?;
          final prid = rp['product_id'] as int?;
          if (pid == null || prid == null || !providerIds.contains(pid)) {
            throw StateError('La relación recibida no pertenece al billar.');
          }
          if (pendingProviderIds.contains(pid)) continue;
          final products = await txn.query(
            'products',
            columns: ['id'],
            where: 'id = ? AND billar_id = ?',
            whereArgs: [prid, billarId],
            limit: 1,
          );
          if (products.isEmpty) {
            debugPrint(
              '[SyncService] Relación de proveedor pendiente: producto local no disponible.',
            );
            continue;
          }
          await txn.insert('provider_products', {
            'provider_id': pid,
            'product_id': prid,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        _requireSyncSession(session);
      });
    } catch (e, st) {
      debugPrint('[SyncService] pullProvidersFromCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
    }
  }

  Future<void> _syncPendingProviderOperations(
    Database db,
    SyncSession session,
  ) async {
    final pending = await db.query(
      'pending_provider_operations',
      where: 'actor_id = ? AND billar_id = ?',
      whereArgs: [session.actorId, session.billarId],
      orderBy: 'id ASC',
    );
    final blockedProviders = <int>{};
    for (final row in pending) {
      _requireSyncSession(session);
      final providerId = row['provider_id'] as int;
      if (blockedProviders.contains(providerId)) continue;
      final payload = jsonDecode(row['payload'] as String);
      final success = switch (row['operation']) {
        'save' when payload is Map => await pushProviderToCloud(
          Map<String, dynamic>.from(payload),
          providerId,
        ),
        'products' when payload is List => await pushProviderProductsToCloud(
          providerId,
          products: payload.cast<int>(),
        ),
        'delete' when payload is Map && payload['request_id'] is String =>
          await archiveProviderInCloud(
            providerId,
            payload['request_id'] as String,
          ),
        _ =>
          throw StateError(
            'La operación pendiente del proveedor no es válida.',
          ),
      };
      _requireSyncSession(session);
      if (!success) {
        blockedProviders.add(providerId);
        continue;
      }
      await db.delete(
        'pending_provider_operations',
        where: 'id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [row['id'], session.actorId, session.billarId],
      );
    }
  }

  // ────────────────────────────────────────────────────────────────────
  // AUTO-SYNC PENDIENTES
  // ────────────────────────────────────────────────────────────────────

  /// Sincroniza manualmente los datos pendientes. Público para permitir
  /// su uso antes de cerrar sesión u otras acciones explícitas.
  Future<void> syncAllPending() async => _syncAllPending();

  Future<void> _syncAllPending() async {
    if (!_db.isAccountDatabaseAvailable) return;
    if (_isSyncing) {
      _syncRequestedWhileRunning = true;
      return;
    }
    _isSyncing = true;

    try {
      if (_sup.auth.currentSession == null) {
        debugPrint(
          '[SyncService] Sin sesión activa; se conservan los pendientes.',
        );
        return;
      }
      final scope = _syncSession();
      bool ensureSession() {
        try {
          _requireSyncSession(scope);
          return true;
        } on StateError {
          debugPrint(
            '[SyncService] La sesión cambió; se detiene la sincronización.',
          );
          return false;
        }
      }

      final hasNet = await AppServices.connectivityService.isOnline;
      if (!ensureSession()) return;
      if (!hasNet) {
        debugPrint('[SyncService] Sin red, auto-sync abortado');
        _scheduleRetry();
        return;
      }

      final db = await _db.database;
      if (!ensureSession()) return;
      final billarId = scope.billarId;
      final session = scope.authSession;

      await pullTablesFromCloud();
      if (!ensureSession()) return;

      // ── Ventas pendientes ──
      final pendingSales = await db.query(
        'sales_history',
        where: 'synced = ? AND billar_id = ?',
        whereArgs: [0, billarId],
        orderBy: 'date ASC',
      );
      debugPrint('[SyncService] Ventas pendientes: ${pendingSales.length}');
      final otherBusinessSales = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM sales_history '
        'WHERE synced = 0 AND billar_id != ?',
        [billarId],
      );
      if ((otherBusinessSales.first['count'] as int? ?? 0) > 0) {
        debugPrint(
          '[SyncService] Hay ventas pendientes de otro billar; se conservan sin sincronizar.',
        );
      }

      // Descargar ventas nuevas de la nube (incluye anulaciones hechas en
      // otro dispositivo) dentro del ciclo de auto-sync.
      await pullSalesFromCloud();
      if (!ensureSession()) return;

      // Descargar retiros/gastos hechos en otro dispositivo (afectan
      // utilidad y flujo de caja en ambos lados).
      await pullOutflowsFromCloud();
      if (!ensureSession()) return;

      for (final sale in pendingSales) {
        if (!ensureSession()) return;
        final localId = sale['id'] as int;
        final cloudId = await pushSaleToCloud(
          localSaleId: localId,
          billarId: billarId,
          accessToken: session.accessToken,
        );

        if (cloudId == null) {
          debugPrint(
            '[SyncService] Falló sync venta $localId, se reintentará luego',
          );
        }
        if (!ensureSession()) return;
      }

      // ── Compras pendientes ──
      final pendingPurchases = await db.query(
        'purchases',
        where: 'synced = ? AND ${purchaseBusinessScope()}',
        whereArgs: [0, billarId],
        orderBy: 'date ASC',
      );
      debugPrint(
        '[SyncService] Compras pendientes: ${pendingPurchases.length}',
      );

      for (final purchase in pendingPurchases) {
        if (!ensureSession()) return;
        final localId = purchase['id'] as int;
        final cloudId = await pushPurchaseToCloud(
          localPurchaseId: localId,
          billarId: billarId,
          accessToken: session.accessToken,
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
        where: 'synced = ? AND billar_id = ?',
        whereArgs: [0, billarId],
        orderBy: 'created_at ASC',
      );
      debugPrint(
        '[SyncService] Jugadores pendientes: ${pendingPlayers.length}',
      );

      for (final row in pendingPlayers) {
        if (!ensureSession()) return;
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
        where: 'synced = ? AND billar_id = ?',
        whereArgs: [0, billarId],
        orderBy: 'created_at ASC',
      );
      debugPrint(
        '[SyncService] Retiros/gastos pendientes: ${pendingOutflows.length}',
      );

      for (final row in pendingOutflows) {
        if (!ensureSession()) return;
        final localId = row['id'] as int;
        final cloudId = await pushOutflowToCloud(
          localOutflowId: localId,
          billarId: billarId,
          accessToken: session.accessToken,
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

      if (!ensureSession()) return;
      await ProductRepository().syncPendingProducts();
      if (!ensureSession()) return;
      await InventoryMovementSyncService.instance.sync();
      if (!ensureSession()) return;
      await QuickSaleRepositoryImpl().syncPendingSales();
      if (!ensureSession()) return;
      try {
        await _syncPendingProviderOperations(db, scope);
      } catch (error, stack) {
        debugPrint('[SyncService] Cola de proveedores no sincronizada: $error');
        if (kDebugMode) debugPrint('$stack');
        if (ensureSession()) _scheduleRetry();
        return;
      }
      if (!ensureSession()) return;

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
    final session = _sup.auth.currentSession;
    if (session != null) {
      final pendingProviders = await db.query(
        'pending_provider_operations',
        columns: ['id'],
        where: 'actor_id = ? AND billar_id = ?',
        whereArgs: [session.user.id, _prefs.billarId],
        limit: 1,
      );
      if (pendingProviders.isNotEmpty) return true;
    }
    const businessScoped = {
      'sales_history',
      'cash_outflows',
      'inventory_movements',
      'players',
      'products',
      'pending_product_deletions',
    };
    for (final table in [
      'sales_history',
      'purchases',
      'players',
      'cash_outflows',
      'products',
      'pending_product_deletions',
      'inventory_movements',
      'billiard_tables',
    ]) {
      final result = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $table WHERE synced = 0'
        '${table == 'products' ? ' AND stock_conflict = 0' : ''}'
        '${table == 'purchases' ? ' AND ${purchaseBusinessScope()}' : ''}'
        '${businessScoped.contains(table) ? ' AND billar_id = ?' : ''}',
        businessScoped.contains(table) || table == 'purchases'
            ? [_prefs.billarId]
            : null,
      );
      if ((result.first['count'] as int? ?? 0) > 0) return true;
    }
    if (session != null) {
      final result = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM pending_sales '
        'WHERE synced = 0 AND actor_id = ? AND billar_id = ?',
        [session.user.id, _prefs.billarId],
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
    required String accessToken,
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
            .setHeader('Authorization', 'Bearer $accessToken')
            .update(payload)
            .eq('id', existingCloudId)
            .select('id');
      } else {
        response = await _sup
            .from('cash_outflows')
            .setHeader('Authorization', 'Bearer $accessToken')
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
      final session = _syncSession();
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return;
      _requireSyncSession(session);

      final db = await _db.database;
      final response = await _sup
          .from('cash_outflows')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .select()
          .eq('billar_id', session.billarId)
          .order('created_at', ascending: false)
          .limit(200)
          .timeout(const Duration(seconds: 8));
      _requireSyncSession(session);

      int nuevos = 0;
      await db.transaction((txn) async {
        for (final o in response) {
          _requireSyncSession(session);
          if (o['billar_id'] != session.billarId || o['id'] == null) {
            throw StateError(
              'El retiro recibido no pertenece al billar actual.',
            );
          }
          final cid = o['id'].toString();
          final existing = await txn.query(
            'cash_outflows',
            columns: ['id'],
            where: 'cloud_id = ?',
            whereArgs: [cid],
            limit: 1,
          );
          if (existing.isNotEmpty) continue;

          await txn.insert('cash_outflows', {
            'billar_id': session.billarId,
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
        _requireSyncSession(session);
      });
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
      final session = _syncSession();
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return;
      _requireSyncSession(session);

      final db = await _db.database;
      final response = await _sup
          .from('sales_history')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .select('*, sale_details(*)')
          .eq('billar_id', session.billarId)
          .order('date', ascending: false)
          .limit(200);
      _requireSyncSession(session);

      await db.transaction((txn) async {
        for (final sale in response) {
          _requireSyncSession(session);
          if (sale['billar_id'] != session.billarId || sale['id'] == null) {
            throw StateError(
              'La venta recibida no pertenece al billar actual.',
            );
          }
          final cid = sale['id'].toString();
          final requestId = sale['sync_client_id']?.toString();
          if (requestId != null && requestId.isNotEmpty) {
            final pending = await txn.query(
              'pending_owner_transactions',
              columns: ['local_id'],
              where:
                  'request_id = ? AND actor_id = ? AND billar_id = ? AND kind = ?',
              whereArgs: [requestId, session.actorId, session.billarId, 'sale'],
              limit: 1,
            );
            if (pending.isNotEmpty) continue;
          }
          final local = await txn.query(
            'sales_history',
            columns: ['id', 'cancelled'],
            where: 'cloud_id = ?',
            whereArgs: [cid],
            limit: 1,
          );
          if (local.isNotEmpty) {
            final cloudCancelled =
                sale['cancelled'] == true || sale['cancelled'] == 1;
            if (cloudCancelled &&
                (local.first['cancelled'] as int? ?? 0) == 0) {
              await txn.update(
                'sales_history',
                {'cancelled': 1},
                where: 'cloud_id = ?',
                whereArgs: [cid],
              );
              await txn.update(
                'sale_details',
                {'cancelled': 1},
                where: 'sale_id = ?',
                whereArgs: [local.first['id']],
              );
              debugPrint(
                '[SyncService] Venta $cid marcada anulada desde la nube',
              );
            }
            continue;
          }

          final localId = await txn.insert('sales_history', {
            'billar_id': session.billarId,
            'total': (sale['total'] as num).toDouble(),
            'paid': (sale['paid'] as num?)?.toDouble() ?? 0,
            'date': sale['date'],
            'type': sale['type'],
            'source_module': sale['source_module']?.toString(),
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
            _requireSyncSession(session);
            await txn.insert('sale_details', {
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
              'cost_available': d['cost_at_sale'] == null ? 0 : 1,
            });
          }
        }
        _requireSyncSession(session);
      });

      debugPrint('[SyncService] pullSalesFromCloud completado');
    } catch (e, st) {
      debugPrint('[SyncService] pullSalesFromCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
    }
  }

  /// Descarga compras desde Supabase para el billar actual.
  Future<void> pullPurchasesFromCloud() async {
    try {
      final session = _syncSession();
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return;
      _requireSyncSession(session);

      final db = await _db.database;
      final response = await _sup
          .from('purchases')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .select('*, purchase_details(*)')
          .eq('billar_id', session.billarId)
          .order('date', ascending: false)
          .limit(200);
      _requireSyncSession(session);

      await db.transaction((txn) async {
        for (final purchase in response) {
          _requireSyncSession(session);
          if (purchase['billar_id'] != session.billarId ||
              purchase['id'] == null) {
            throw StateError(
              'La compra recibida no pertenece al billar actual.',
            );
          }
          final cid = purchase['id'].toString();
          final requestId = purchase['sync_client_id']?.toString();
          if (requestId != null && requestId.isNotEmpty) {
            final pending = await txn.query(
              'pending_owner_transactions',
              columns: ['local_id'],
              where:
                  'request_id = ? AND actor_id = ? AND billar_id = ? AND kind = ?',
              whereArgs: [
                requestId,
                session.actorId,
                session.billarId,
                'purchase',
              ],
              limit: 1,
            );
            if (pending.isNotEmpty) continue;
          }
          final local = await txn.query(
            'purchases',
            columns: ['id', 'billar_id', 'cancelled'],
            where: 'cloud_id = ?',
            whereArgs: [cid],
            limit: 1,
          );
          if (local.isNotEmpty) {
            final localBillar = local.first['billar_id'];
            if (localBillar == null) {
              debugPrint(
                '[SyncService] Compra antigua sin billar omitida: $cid.',
              );
              continue;
            }
            if (localBillar != session.billarId) {
              throw StateError('La compra local pertenece a otro billar.');
            }
            if (purchase['cancelled'] == true &&
                (local.first['cancelled'] as int? ?? 0) == 0) {
              await txn.update(
                'purchases',
                {'cancelled': 1},
                where: 'id = ? AND billar_id = ?',
                whereArgs: [local.first['id'], session.billarId],
              );
              await txn.update(
                'purchase_details',
                {'cancelled': 1},
                where: 'purchase_id = ?',
                whereArgs: [local.first['id']],
              );
            }
            continue;
          }

          final localId = await txn.insert('purchases', {
            'billar_id': session.billarId,
            'provider_id': purchase['provider_id'],
            'total': (purchase['total'] as num).toDouble(),
            'date': purchase['date'],
            'reference': purchase['reference'] ?? '',
            'created_by': purchase['created_by'] ?? '',
            'cash_source':
                purchase['payment_condition'] == 'credito'
                    ? null
                    : purchase['cash_source'] ?? 'caja',
            for (final field in [
              'payment_condition',
              'payment_method',
              'credit_days',
              'due_date',
              'paid_amount',
              'balance_due',
            ])
              field: purchase[field],
            'cancelled': (purchase['cancelled'] ?? false) == true ? 1 : 0,
            'synced': 1,
            'cloud_id': cid,
          });

          final details = purchase['purchase_details'] as List? ?? [];
          for (final d in details) {
            _requireSyncSession(session);
            await txn.insert('purchase_details', {
              'purchase_id': localId,
              'product_id': d['product_id'],
              'quantity': (d['quantity'] as num).toDouble(),
              'cost_per_unit': (d['cost_per_unit'] as num).toDouble(),
              'created_by': d['created_by'] ?? '',
              'cancelled': (d['cancelled'] ?? false) == true ? 1 : 0,
            });
          }
        }
        _requireSyncSession(session);
      });

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
  Future<bool> pushTableToCloud(Map<String, dynamic> table) {
    try {
      return _pushTableToCloud(table, _syncSession());
    } catch (e) {
      debugPrint('[SyncService] pushTableToCloud ERROR: $e');
      return Future.value(false);
    }
  }

  Future<bool> _pushTableToCloud(
    Map<String, dynamic> table,
    SyncSession session,
  ) async {
    try {
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return false;
      _requireSyncSession(session);

      if (table['billar_id'] != session.billarId) {
        throw StateError('La mesa no pertenece al billar actual.');
      }
      final id = table['id'] as int;
      final db = await _db.database;
      _requireSyncSession(session);
      if (await TableSyncConflicts.contains(
        db,
        session.actorId,
        session.billarId,
        id,
      )) {
        return false;
      }
      _requireSyncSession(session);
      final map = {
        'id': id,
        'billar_id': session.billarId,
        'name': table['name'] ?? 'Mesa $id',
        'table_type': table['table_type'] ?? 'Billar',
        'is_occupied': table['is_occupied'] ?? 0,
        'start_time': table['start_time'],
        'orders': table['orders'] ?? '[]',
        'is_deleted': table['is_deleted'] ?? 0,
      };

      try {
        await _sup
            .from('billiard_tables')
            .setHeader('Authorization', 'Bearer ${session.token}')
            .upsert(map);
      } on PostgrestException catch (error) {
        if (error.code != 'PST01') rethrow;
        await db.transaction((txn) async {
          _requireSyncSession(session);
          await TableSyncConflicts.record(
            txn,
            session.actorId,
            session.billarId,
            id,
            map,
          );
          await txn.update(
            'billiard_tables',
            {'synced': 0},
            where: 'id = ? AND billar_id = ?',
            whereArgs: [id, session.billarId],
          );
          _requireSyncSession(session);
        });
        debugPrint('[SyncService] Mesa $id requiere revisión por conflicto.');
        return false;
      }
      _requireSyncSession(session);
      final applied = await db.transaction((txn) async {
        _requireSyncSession(session);
        if (await TableSyncConflicts.contains(
          txn,
          session.actorId,
          session.billarId,
          id,
        )) {
          return false;
        }
        final currentRows = await txn.query(
          'billiard_tables',
          where: 'id = ? AND billar_id = ?',
          whereArgs: [id, session.billarId],
          limit: 1,
        );
        if (currentRows.isNotEmpty &&
            currentRows.first['name'] == map['name'] &&
            currentRows.first['table_type'] == map['table_type'] &&
            currentRows.first['is_occupied'] == map['is_occupied'] &&
            currentRows.first['start_time'] == map['start_time'] &&
            currentRows.first['orders'] == map['orders'] &&
            currentRows.first['is_deleted'] == map['is_deleted']) {
          await txn.update(
            'billiard_tables',
            {'synced': 1},
            where: 'id = ? AND billar_id = ?',
            whereArgs: [id, session.billarId],
          );
        }
        _requireSyncSession(session);
        return true;
      });
      if (!applied) return false;
      debugPrint('[SyncService] pushTableToCloud id=$id OK');
      return true;
    } catch (e, st) {
      debugPrint('[SyncService] pushTableToCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
      return false;
    }
  }

  /// Descarga mesas de Supabase y las fusiona con las locales.
  /// La eliminación remota se propaga salvo que existan cambios locales pendientes.
  /// Cuando [forceApply] es `true` (usado por Realtime), se sobreescribe también
  /// la mesa si está ocupada localmente, porque la nube es la fuente de verdad
  /// para propagar en tiempo real el estado entre dispositivos.
  Future<void> pullTablesFromCloud({bool forceApply = false}) async {
    try {
      final session = _syncSession();
      final hasNet = await AppServices.connectivityService.isOnline;
      if (!hasNet) return;
      _requireSyncSession(session);

      final db = await _db.database;
      final billarId = session.billarId;

      var response = await _sup
          .from('billiard_tables')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .select()
          .eq('billar_id', billarId)
          .order('id', ascending: true);
      _requireSyncSession(session);
      var tables = response as List<dynamic>;
      for (final table in tables) {
        if (table['billar_id'] != billarId || table['id'] is! num) {
          throw StateError('La mesa recibida no pertenece al billar actual.');
        }
      }
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
        _requireSyncSession(session);
        final id = (table['id'] as num).toInt();
        if (await TableSyncConflicts.contains(
          db,
          session.actorId,
          billarId,
          id,
        )) {
          continue;
        }
        _requireSyncSession(session);
        final remote = remoteById[id];
        if (remote != null &&
            (remote['is_deleted'] as num?)?.toInt() == 1 &&
            (table['is_deleted'] as num?)?.toInt() != 1) {
          await db.transaction((txn) async {
            _requireSyncSession(session);
            if (await TableSyncConflicts.contains(
              txn,
              session.actorId,
              billarId,
              id,
            )) {
              return;
            }
            await TableSyncConflicts.recordRemoteDeletion(
              txn,
              session.actorId,
              billarId,
              id,
              table,
              remote,
            );
            final current = await txn.query(
              'billiard_tables',
              where: 'id = ? AND billar_id = ?',
              whereArgs: [id, billarId],
              limit: 1,
            );
            if (current.isNotEmpty) {
              await TableSyncConflicts.recordRemoteDeletion(
                txn,
                session.actorId,
                billarId,
                id,
                current.first,
                remote,
              );
              await txn.update(
                'billiard_tables',
                {'synced': 0},
                where: 'id = ? AND billar_id = ?',
                whereArgs: [id, billarId],
              );
            }
            _requireSyncSession(session);
          });
          continue;
        }
        await _pushTableToCloud(table, session);
      }
      _requireSyncSession(session);

      response = await _sup
          .from('billiard_tables')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .select()
          .eq('billar_id', billarId)
          .order('id', ascending: true);
      _requireSyncSession(session);
      tables = response as List<dynamic>;
      debugPrint('[SyncService] pullTablesFromCloud: ${tables.length} mesas');

      // RLS puede ocultar filas; solo un tombstone explícito elimina una mesa.
      await db.transaction((txn) async {
        for (final t in tables) {
          _requireSyncSession(session);
          if (t['billar_id'] != billarId || t['id'] is! num) {
            throw StateError('La mesa recibida no pertenece al billar actual.');
          }
          final id = (t['id'] as num).toInt();
          if (await TableSyncConflicts.contains(
            txn,
            session.actorId,
            billarId,
            id,
          )) {
            continue;
          }
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
            if ((local['synced'] as int? ?? 1) == 0) {
              if (cloudDeleted == 1 &&
                  (local['is_deleted'] as num?)?.toInt() != 1) {
                await TableSyncConflicts.recordRemoteDeletion(
                  txn,
                  session.actorId,
                  billarId,
                  id,
                  local,
                  Map<String, dynamic>.from(t as Map),
                );
              }
              continue;
            }
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
        _requireSyncSession(session);
      });

      final activeTableCount =
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM billiard_tables WHERE billar_id = ? AND is_deleted = 0',
              [billarId],
            ),
          )!;
      _requireSyncSession(session);
      await _prefs.setTableCount(activeTableCount);
    } catch (e, st) {
      debugPrint('[SyncService] pullTablesFromCloud ERROR: $e');
      if (kDebugMode) debugPrint('$st');
    }
  }
}
