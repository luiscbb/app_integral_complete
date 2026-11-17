import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/services/sync_session.dart';
import '../../../../core/services/business_image_paths.dart';
import '../../../../core/utils/uuid_v4.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../domain/entities/product_entity.dart';
import '../../domain/repositories/i_product_repository.dart';
import 'owner_promo_outbox.dart';

const _atomicPromoSyncEnabled = false;

typedef StockConflictSnapshot = ({
  ProductEntity product,
  int localRevision,
  double remoteStock,
  int remoteRevision,
});

class ProductRepository implements IProductRepository {
  ProductRepository({bool atomicPromoSync = _atomicPromoSyncEnabled})
    : _atomicPromoSync = atomicPromoSync;

  final bool _atomicPromoSync;
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  static final Random _idRandom = Random.secure();
  static final Map<int, Future<void>> _productSyncs = {};
  static final ValueNotifier<int> conflictChanges = ValueNotifier<int>(0);
  SupabaseClient get _supabase => Supabase.instance.client;
  SyncSessionGuard get _sessionGuard => SyncSessionGuard(_supabase, _prefs);

  // SQLite IDs are also sent to Supabase, so independent devices need disjoint IDs.
  int _newProductId() =>
      DateTime.now().millisecondsSinceEpoch * 1000000 + _idRandom.nextInt(1000000);

  @override
  Future<List<ProductEntity>> getAll({
    bool syncRemote = true,
    bool includeArchived = false,
  }) async {
    final db = await _db.database;
    final maps = await db.query(
      'products',
      where: includeArchived ? 'billar_id = ?' : 'billar_id = ? AND is_active = ?',
      whereArgs: includeArchived ? [_prefs.billarId] : [_prefs.billarId, 1],
      orderBy: 'name ASC',
    );
    final base = maps.map((m) => ProductEntity.fromMap(m)).toList();

    // Sync en background sin bloquear la UI
    if (syncRemote) {
      _syncFromCloud().catchError((e) => debugPrint('[Sync] Background sync error: $e'));
    }

    final result = <ProductEntity>[];
    for (final p in base) {
      double stock = p.stock;
      if (p.parentId != null && p.piecesPerUnit > 0) {
        try {
          final padre = base.firstWhere((x) => x.id == p.parentId);
          stock = padre.stock / p.piecesPerUnit;
        } catch (_) {
          stock = 0;
        }
      } else if (p.isPromo == 1) {
        final components = await db.query('promo_items', where: 'parent_id = ?', whereArgs: [p.id]);
        if (components.isEmpty) {
          stock = 0;
        } else {
          double min = 999999;
          for (final c in components) {
            try {
              final hijo = base.firstWhere((x) => x.id == c['child_id']);
              final need = (c['quantity'] as num).toDouble();
              final possible = hijo.stock / need;
              if (possible < min) min = possible;
            } catch (_) {
              min = 0;
            }
          }
          stock = min < 0 ? 0 : min.floorToDouble();
        }
      }
      result.add(p.copyWith(stock: stock));
    }
    return result;
  }

  Future<List<ProductEntity>> refreshFromCloud() async {
    await _syncFromCloud();
    return getAll(syncRemote: false);
  }

  Future<void> _syncFromCloud() async {
    try {
      final guardedSession = _atomicPromoSync ? _sessionGuard.capture() : null;
      final billarId = _prefs.billarId;
      final session = _supabase.auth.currentSession;
      if (session == null) {
        throw StateError('Se requiere una sesión para descargar productos.');
      }
      void requireSameSession() {
        if (guardedSession != null) _sessionGuard.require(guardedSession);
        final current = _supabase.auth.currentSession;
        if (_prefs.billarId != billarId ||
            current?.user.id != session.user.id ||
            current?.accessToken != session.accessToken) {
          throw StateError('La sesión o el billar cambió durante la descarga.');
        }
      }
      debugPrint('[Sync] Iniciando descarga para billarId: $billarId');

      final response = await _supabase
          .from('products')
          .setHeader('Authorization', 'Bearer ${session.accessToken}')
          .select()
          .eq('billar_id', billarId)
          .timeout(const Duration(seconds: 8));
      requireSameSession();

      debugPrint('[Sync] Productos recibidos: ${(response as List).length}');
      final promoSnapshots = <int, Map<String, dynamic>>{};
      if (_atomicPromoSync) {
        for (final item in response) {
          final product = Map<String, dynamic>.from(item);
          if (product['billar_id'] != billarId) {
            throw StateError('El producto recibido pertenece a otro billar.');
          }
          if (product['is_promo'] != 1) continue;
          final id = product['id'];
          if (id is! int || id <= 0 || promoSnapshots.containsKey(id)) {
            throw StateError('La promoción recibida no es válida.');
          }
          final snapshot = await _supabase.rpc(
            'read_owner_promo_snapshot',
            params: {'p_billar_id': billarId, 'p_product_id': id},
          ).setHeader('Authorization', 'Bearer ${session.accessToken}')
              .timeout(const Duration(seconds: 8));
          requireSameSession();
          if (snapshot is! Map ||
              snapshot['product'] is! Map ||
              snapshot['components'] is! List) {
            throw StateError('La respuesta de la promoción no es válida.');
          }
          final remoteProduct = Map<String, dynamic>.from(snapshot['product'] as Map);
          if (remoteProduct['id'] != id ||
              remoteProduct['billar_id'] != billarId ||
              remoteProduct['is_promo'] != 1 ||
              remoteProduct['parent_id'] != null ||
              remoteProduct['stock_revision'] is! int ||
              (remoteProduct['stock_revision'] as int) < 0) {
            throw StateError('La identidad o revisión de la promoción no es válida.');
          }
          final components = <Map<String, int>>[];
          final seen = <int>{};
          for (final component in snapshot['components'] as List) {
            if (component is! Map ||
                component['child_id'] is! int ||
                component['quantity'] is! int) {
              throw StateError('Los componentes de la promoción no son válidos.');
            }
            final childId = component['child_id'] as int;
            final quantity = component['quantity'] as int;
            if (childId <= 0 || quantity <= 0 || !seen.add(childId)) {
              throw StateError('Los componentes de la promoción no son válidos.');
            }
            components.add({'child_id': childId, 'quantity': quantity});
          }
          if (components.isEmpty) {
            throw StateError('La promoción no tiene componentes.');
          }
          promoSnapshots[id] = {'product': remoteProduct, 'components': components};
        }
      }

      final db = await _db.database;

      final pendingDeletions = await db.query(
        'pending_product_deletions',
        columns: ['product_id'],
        where: 'billar_id = ?',
        whereArgs: [billarId],
      );
      final pendingDeletionIds = pendingDeletions.map((row) => row['product_id'] as int).toSet();

      await db.transaction((txn) async {
        final acceptedPromos = <int>[];
        for (final item in response) {
          requireSameSession();
          var map = Map<String, dynamic>.from(item);
          final promoSnapshot = promoSnapshots[map['id']];
          if (promoSnapshot != null) {
            map = promoSnapshot['product'] as Map<String, dynamic>;
          }
          if (map['billar_id'] != billarId) {
            throw StateError('El producto recibido pertenece a otro billar.');
          }
          final remoteId = map['id'] as int?;
          if (remoteId != null && pendingDeletionIds.contains(remoteId)) continue;
          if (promoSnapshot != null) {
            final pending = await txn.query(
              'pending_owner_promos',
              columns: ['product_id'],
              where: 'product_id = ?',
              whereArgs: [remoteId],
              limit: 1,
            );
            if (pending.isNotEmpty) continue;
          }
          final cleanMap = {
            'id': map['id'],
            'billar_id': map['billar_id'],
            'barcode': map['barcode'],
            'name': map['name'],
            'description': map['description'],
            'price': map['price'],
            'cost': map['cost'],
            'stock': map['stock'],
            'stock_revision': map['stock_revision'],
            'image_path': map['image_path'],
            'is_promo': map['is_promo'],
            'parent_id': map['parent_id'],
            'pieces_per_unit': map['pieces_per_unit'],
            'category': map['category'] ?? '',
            'presentation': map['presentation'] ?? '',
            'is_active': map['is_active'] == false || map['is_active'] == 0 ? 0 : 1,
          };

          if (cleanMap['id'] != null) {
            // Para productos EXISTENTES: actualizar también el stock.
            // La nube siempre refleja el último movimiento real (compra/venta),
            // porque cada cambio de stock se sube de inmediato tras aplicarse
            // (ver `_syncProductStockToCloud`, `decreaseStock`, `syncProductById`).
            // Solo se excluyen los productos con cambios locales aún sin subir
            // (synced = 0), para no pisar una venta/compra que no ha llegado a
            // la nube todavía.
            final existing = await txn.query(
              'products',
              where: 'id = ?',
              whereArgs: [cleanMap['id']],
            );
            if (existing.isNotEmpty) {
              if (existing.first['billar_id'] != billarId) {
                throw StateError('El producto local pertenece a otro billar.');
              }
              final localSynced = (existing.first['synced'] as int?) ?? 1;
              if (localSynced == 0) continue;
              final localRevision = existing.first['stock_revision'] as int?;
              final remoteRevision = cleanMap['stock_revision'] as int?;
              if (localRevision != null && remoteRevision == null) {
                throw StateError('El producto remoto no tiene revisión de stock.');
              }
              final keepLocalStock =
                  localRevision != null &&
                  remoteRevision != null &&
                  remoteRevision < localRevision;
              if (promoSnapshot != null && keepLocalStock) continue;
              if (localRevision != null &&
                  remoteRevision == localRevision &&
                  existing.first['stock'] != cleanMap['stock']) {
                throw StateError('La revisión de stock tiene valores diferentes.');
              }
              final updateMap = {
                'name': cleanMap['name'],
                'description': cleanMap['description'],
                'price': cleanMap['price'],
                'cost': cleanMap['cost'],
                'image_path': cleanMap['image_path'],
                'is_promo': cleanMap['is_promo'],
                'parent_id': cleanMap['parent_id'],
                'pieces_per_unit': cleanMap['pieces_per_unit'],
                'category': cleanMap['category'],
                'presentation': cleanMap['presentation'],
                'is_active': cleanMap['is_active'],
                'billar_id': cleanMap['billar_id'],
                'stock_revision':
                    keepLocalStock ? localRevision : cleanMap['stock_revision'],
                'stock_conflict': 0,
                'synced': 1,
              };
              if (promoSnapshot != null) updateMap['barcode'] = cleanMap['barcode'];
              updateMap['stock'] =
                  keepLocalStock ? existing.first['stock'] : cleanMap['stock'];
              await txn.update('products', updateMap, where: 'id = ?', whereArgs: [cleanMap['id']]);
            } else {
              // Producto NUEVO: insertar todo incluyendo stock
              await txn.insert('products', {...cleanMap, 'synced': 1});
            }
            if (promoSnapshot != null) acceptedPromos.add(remoteId!);
          }
        }
        for (final promoId in acceptedPromos) {
          final components = promoSnapshots[promoId]!['components'] as List<Map<String, int>>;
          for (final component in components) {
            final children = await txn.query(
              'products',
              columns: ['id'],
              where: 'id = ? AND billar_id = ? AND is_promo = 0 AND parent_id IS NULL',
              whereArgs: [component['child_id'], billarId],
              limit: 1,
            );
            if (children.length != 1) {
              throw StateError('Falta un componente local de la promoción.');
            }
          }
          await txn.delete('promo_items', where: 'parent_id = ?', whereArgs: [promoId]);
          for (final component in components) {
            await txn.insert('promo_items', {'parent_id': promoId, ...component});
          }
        }
        requireSameSession();
      });
      debugPrint('[Sync] Descarga completada exitosamente');
    } catch (e) {
      debugPrint('[Supabase syncFromCloud] ERROR: $e');
      if (_atomicPromoSync) rethrow;
    }
  }

  @override
  Future<int> insert(ProductEntity p, {double? priceCaja}) async {
    final db = await _db.database;

    if (p.barcode != null && p.barcode!.isNotEmpty) {
      final existing = await db.query(
        'products',
        where: 'barcode = ? AND id != ?',
        whereArgs: [p.barcode, p.id ?? -1],
      );
      if (existing.isNotEmpty) throw Exception("El codigo '${p.barcode}' ya esta registrado.");
    }

    Map<String, dynamic>? cajaMap;
    int productId = await db.transaction((txn) async {
      final map =
          p.toMap()
            ..['name'] = p.name.toUpperCase()
            ..['description'] = p.description.toUpperCase()
            ..['billar_id'] = _prefs.billarId;

      int id;
      if (p.id != null) {
        // Al editar un producto padre, sincronizamos también su presentación
        // y datos administrativos en la caja hija sin tocar el stock.
        final childRows = await txn.query('products', where: 'parent_id = ?', whereArgs: [p.id]);
        if (childRows.isNotEmpty) {
          final childId = childRows.first['id'] as int;
          await txn.update(
            'products',
            {
              'name': '${p.name.toUpperCase()} (CAJA)',
              'description': 'PAQUETE DE ${p.piecesPerUnit} PZ',
              'barcode': p.barcode != null ? '${p.barcode}-C' : null,
              'price': priceCaja ?? (p.price * p.piecesPerUnit),
              'cost': p.cost * p.piecesPerUnit,
              'pieces_per_unit': p.piecesPerUnit,
              'image_path': p.imagePath,
              'category': p.category,
              'presentation': p.presentation,
              'billar_id': _prefs.billarId,
              'synced': 0,
            },
            where: 'id = ?',
            whereArgs: [childId],
          );
          cajaMap = Map<String, dynamic>.from(childRows.first);
          cajaMap!['id'] = childId;
        }
        map['synced'] = 0;
        await txn.update('products', map, where: 'id = ?', whereArgs: [p.id]);
        id = p.id!;
      } else {
        map['id'] = _newProductId();
        id = await txn.insert('products', map);
      }

      if (p.id == null && p.piecesPerUnit > 1 && p.isPromo == 0) {
        cajaMap = {
          'id': _newProductId(),
          'name': '${p.name.toUpperCase()} (CAJA)',
          'description': 'PAQUETE DE ${p.piecesPerUnit} PZ',
          'barcode': p.barcode != null ? '${p.barcode}-C' : null,
          'price': priceCaja ?? (p.price * p.piecesPerUnit),
          'cost': p.cost * p.piecesPerUnit,
          'stock': 0.0,
          'is_promo': 0,
          'parent_id': id,
          'pieces_per_unit': p.piecesPerUnit,
          'billar_id': _prefs.billarId,
          'image_path': p.imagePath,
          'category': p.category,
          'presentation': p.presentation,
        };
        final cajaId = await txn.insert('products', cajaMap!);
        cajaMap!['id'] = cajaId;
      }
      return id;
    });

    _syncToCloud(productId, childId: cajaMap?['id'] as int?);
    return productId;
  }

  Future<void> _syncToCloud(int localId, {int? childId, SyncSession? session}) async {
    try {
      final captured = session ?? _sessionGuard.capture();
      _sessionGuard.require(captured);
      await _queueProductSync(localId, captured);
      if (childId != null) await _queueProductSync(childId, captured);
    } on StateError catch (error) {
      debugPrint('[Sync] Producto $localId queda pendiente: $error');
    }
  }

  Future<void> _queueProductSync(int localId, SyncSession session) async {
    final previous = _productSyncs[localId];
    final current = () async {
      if (previous != null) await previous;
      _sessionGuard.require(session);
      await _syncProductSnapshot(localId, session);
    }();
    _productSyncs[localId] = current;
    try {
      await current;
    } finally {
      if (identical(_productSyncs[localId], current)) _productSyncs.remove(localId);
    }
  }

  Future<void> _syncProductSnapshot(int localId, SyncSession session) async {
    var syncingPromo = false;
    try {
      _sessionGuard.require(session);
      final db = await _db.database;
      var rows = await db.query(
        'products',
        where: 'id = ? AND billar_id = ?',
        whereArgs: [localId, session.billarId],
      );
      _sessionGuard.require(session);
      if (rows.isEmpty || rows.first['synced'] != 0 || rows.first['stock_conflict'] == 1) return;
      var snapshot = rows.first;
      syncingPromo = _atomicPromoSync && snapshot['is_promo'] == 1;
      if (!_atomicPromoSync && snapshot['is_promo'] == 1) {
        final pending = await db.query(
          'pending_owner_promos',
          columns: ['product_id'],
          where: 'product_id = ?',
          whereArgs: [localId],
          limit: 1,
        );
        _sessionGuard.require(session);
        if (pending.isNotEmpty) {
          debugPrint('[Sync] Promoción $localId requiere sincronización atómica.');
          return;
        }
      }
      if (syncingPromo) {
        await OwnerPromoOutbox(db, _sessionGuard.require).validateOwner(session, localId);
      }
      final imagePath = snapshot['image_path'] as String?;
      if (imagePath != null && !imagePath.startsWith('http')) {
        final finalUrl = await _uploadImage(imagePath, session);
        _sessionGuard.require(session);
        if (finalUrl == null) {
          debugPrint(
            '[Sync] Imagen local del producto $localId pendiente de subir; se reintentará.',
          );
          return;
        }
        final changed = await db.transaction((txn) async {
          _sessionGuard.require(session);
          final changed = await txn.update(
            'products',
            {'image_path': finalUrl, 'synced': 0},
            where: 'id = ? AND billar_id = ? AND local_revision = ?',
            whereArgs: [localId, session.billarId, snapshot['local_revision']],
          );
          _sessionGuard.require(session);
          return changed;
        });
        if (changed == 0) return;
        rows = await db.query('products', where: 'id = ?', whereArgs: [localId]);
        if (rows.isEmpty) return;
        snapshot = rows.first;
      }
      if (syncingPromo) {
        final outbox = OwnerPromoOutbox(db, _sessionGuard.require);
        final request = await outbox.prepare(session: session, productId: localId);
        _sessionGuard.require(session);
        final response = await _supabase.rpc(
          'sync_owner_promo',
          params: {
            'p_request_id': request.requestId,
            'p_billar_id': session.billarId,
            ...request.payload,
          },
        ).setHeader('Authorization', 'Bearer ${session.token}');
        _sessionGuard.require(session);
        if (response is! int || response < 0) {
          throw StateError('La respuesta de la promoción no es válida.');
        }
        final unchanged = await outbox.acknowledge(
          session: session, productId: localId, request: request, revision: response,
        );
        if (!unchanged) SyncService().schedulePendingSync();
        return;
      }
      final p = ProductEntity.fromMap(snapshot);
      final billarId = snapshot['billar_id'] as String;
      _sessionGuard.require(session);
      final map =
          p.toMap()
            ..['id'] = localId
            ..['name'] = p.name.toUpperCase()
            ..['billar_id'] = billarId
            ..['is_active'] = p.isActive;
      final revision = snapshot['stock_revision'] as int?;
      if (revision != null) map['stock_revision'] = revision + 1;

      debugPrint(
        '[Sync] Subiendo producto: ${p.name} con precio: ${p.price}, billar_id: $billarId',
      );
      debugPrint('[Sync] Map completo antes de upsert: $map');
      final remote = await _supabase.from('products')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .upsert(map).select().single();
      _sessionGuard.require(session);
      if (remote['id'] != localId || remote['billar_id'] != billarId) {
        throw StateError('El servidor devolvió otro producto o billar.');
      }
      debugPrint('[Supabase] Producto sincronizado: ${p.name} con precio ${map['price']}');
      await db.transaction((txn) async {
        _sessionGuard.require(session);
        await txn.update(
          'products',
          {'stock_revision': remote['stock_revision']},
          where: 'id = ? AND billar_id = ?',
          whereArgs: [localId, billarId],
        );
        await txn.update(
          'products',
          {'synced': 1},
          where: 'id = ? AND billar_id = ? AND local_revision = ? AND stock_conflict = 0',
          whereArgs: [localId, billarId, snapshot['local_revision']],
        );
        _sessionGuard.require(session);
      });
    } on PostgrestException catch (e) {
      if (e.code == '40001' && !syncingPromo) {
        try {
          _sessionGuard.require(session);
          final db = await _db.database;
          final changed = await db.transaction((txn) async {
            _sessionGuard.require(session);
            final changed = await txn.update(
              'products',
              {'stock_conflict': 1},
              where: 'id = ? AND billar_id = ?',
              whereArgs: [localId, session.billarId],
            );
            _sessionGuard.require(session);
            return changed;
          });
          if (changed > 0) conflictChanges.value++;
        } on StateError catch (error) {
          debugPrint('[Sync] Conflicto de producto no aplicado: $error');
        }
      }
      debugPrint('[Supabase syncToCloud] ERROR: $e');
    } catch (e, st) {
      debugPrint('[Supabase syncToCloud] ERROR: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  Future<String?> _uploadImage(String localPath, SyncSession session) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) return null;
      final path = businessImagePath(
        session.billarId, 'products', '${newUuidV4()}.jpg',
      );
      final bytes = await file.readAsBytes();
      _sessionGuard.require(session);
      await _supabase.storage
          .from('product_images')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
          );
      _sessionGuard.require(session);
      return _supabase.storage.from('product_images').getPublicUrl(path);
    } catch (e, st) {
      debugPrint('[Storage uploadImage] ERROR: $e');
      debugPrint('[Storage uploadImage] STACK: $st');
      return null;
    }
  }

  @override
  Future<int> update(ProductEntity p) async {
    final db = await _db.database;
    if (p.id != null) {
      final pending = await db.query(
        'pending_owner_promos',
        columns: ['product_id'],
        where: 'product_id = ?',
        whereArgs: [p.id],
        limit: 1,
      );
      if (pending.isNotEmpty) {
        throw StateError('La promoción tiene una operación atómica pendiente.');
      }
    }
    // Si la imagen cambió (nueva foto o eliminada), borrar la anterior del bucket
    // para no dejar archivos huérfanos en Supabase Storage.
    if (p.id != null) {
      final prevRows = await db.query(
        'products',
        columns: ['image_path'],
        where: 'id = ?',
        whereArgs: [p.id],
      );
      if (prevRows.isNotEmpty) {
        final prevImage = prevRows.first['image_path'] as String?;
        if (prevImage != null && prevImage != p.imagePath) {
          await _deleteImageIfCloud(prevImage);
        }
      }
    }
    final map =
        p.toMap()
          ..['name'] = p.name.toUpperCase()
          ..['synced'] = 0;
    final result = await db.update('products', map, where: 'id = ?', whereArgs: [p.id]);
    _syncToCloud(p.id!);
    return result;
  }

  @override
  Future<int> archive(int id) async {
    if (_atomicPromoSync) {
      final session = _sessionGuard.capture();
      final db = await _db.database;
      final count = await db.transaction((txn) async {
        _sessionGuard.require(session);
        final rows = await txn.query(
          'products',
          columns: ['id', 'is_promo', 'stock_revision'],
          where: 'billar_id = ? AND (id = ? OR parent_id = ?)',
          whereArgs: [session.billarId, id, id],
        );
        for (final row in rows.where((row) => row['is_promo'] == 1)) {
          final pending = await txn.query(
            'pending_owner_promos',
            where: 'product_id = ?',
            whereArgs: [row['id']],
          );
          if (pending.isNotEmpty &&
              (pending.single['actor_id'] != session.actorId ||
                  pending.single['billar_id'] != session.billarId)) {
            throw StateError('La promoción pendiente pertenece a otra cuenta.');
          }
          if (row['stock_revision'] == null &&
              (pending.isEmpty || pending.single['is_new'] != 1)) {
            throw StateError('La promoción necesita una revisión remota antes de archivarse.');
          }
          if (pending.isEmpty) {
            await txn.insert('pending_owner_promos', {
              'product_id': row['id'],
              'actor_id': session.actorId,
              'billar_id': session.billarId,
              'is_new': 0,
            });
          }
        }
        if (rows.isEmpty) return 0;
        final ids = rows.map((row) => row['id'] as int).toList();
        final placeholders = List.filled(ids.length, '?').join(', ');
        final updated = await txn.update(
          'products',
          {'is_active': 0, 'synced': 0},
          where: 'billar_id = ? AND id IN ($placeholders)',
          whereArgs: [session.billarId, ...ids],
        );
        _sessionGuard.require(session);
        return updated;
      });
      if (count > 0) SyncService().schedulePendingSync();
      return count;
    }
    final db = await _db.database;
    final products = await db.query(
      'products',
      columns: ['id'],
      where: 'id = ? OR parent_id = ?',
      whereArgs: [id, id],
    );
    if (products.isEmpty) return 0;
    final productIds = products.map((row) => row['id'] as int).toList();
    final placeholders = List.filled(productIds.length, '?').join(', ');
    final pending = await db.query(
      'pending_owner_promos',
      columns: ['product_id'],
      where: 'product_id IN ($placeholders)',
      whereArgs: productIds,
      limit: 1,
    );
    if (pending.isNotEmpty) {
      throw StateError('La promoción tiene una operación atómica pendiente.');
    }
    final count = await db.update(
      'products',
      {'is_active': 0, 'synced': 0},
      where: 'id IN ($placeholders)',
      whereArgs: productIds,
    );
    SyncService().schedulePendingSync();
    return count;
  }

  @override
  Future<int> delete(int id) => archive(id);

  Future<void> syncPendingProductDeletions() async {
    final session = _sessionGuard.capture();
    await _syncPendingProductDeletions(session);
  }

  Future<void> _syncPendingProductDeletions(SyncSession session) async {
    final db = await _db.database;
    _sessionGuard.require(session);
    final pending = await db.query(
      'pending_product_deletions',
      where: 'synced = ? AND billar_id = ?',
      whereArgs: [0, session.billarId],
      orderBy: 'id ASC',
    );

    for (final deletion in pending) {
      _sessionGuard.require(session);
      final deletionId = deletion['id'] as int;
      final productId = deletion['product_id'] as int;
      try {
        final archived = await _supabase
            .from('products')
            .setHeader('Authorization', 'Bearer ${session.token}')
            .update({'is_active': false})
            .eq('billar_id', session.billarId)
            .eq('id', productId)
            .select('id')
            .maybeSingle();
        _sessionGuard.require(session);
        if (archived == null || archived['id'] != productId) {
          throw StateError('El servidor no confirmó el archivado del producto.');
        }
        await db.transaction((txn) async {
          _sessionGuard.require(session);
          await txn.delete(
            'pending_product_deletions',
            where: 'id = ? AND billar_id = ?',
            whereArgs: [deletionId, session.billarId],
          );
          _sessionGuard.require(session);
        });
        debugPrint('[Supabase archive] Producto $productId sincronizado');
      } catch (e) {
        debugPrint('[Supabase archive] Producto $productId queda pendiente: $e');
      }
    }
  }

  /// Elimina un archivo de Supabase Storage a partir de su URL pública,
  /// si corresponde al bucket `product_images`. Evita acumular imágenes
  /// huérfanas cuando un producto se borra o se reemplaza su foto.
  Future<void> _deleteImageIfCloud(String? imageUrl) async {
    if (imageUrl == null || !imageUrl.startsWith('http')) return;
    try {
      final session = _sessionGuard.capture();
      final storagePath = publicStorageObjectPath(
        _supabase, 'product_images', imageUrl,
      );
      if (storagePath == null ||
          !storagePath.startsWith('${session.billarId}/products/')) {
        debugPrint('[Storage delete] Imagen anterior no identificada; se conserva.');
        return;
      }
      _sessionGuard.require(session);
      await _supabase.storage
          .from('product_images')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .remove([storagePath]);
      _sessionGuard.require(session);
    } catch (e) {
      debugPrint('[Storage delete] aviso: $e');
    }
  }

  @override
  Future<void> insertPromo(ProductEntity promo, Map<int, int> components) async {
    final session = _atomicPromoSync ? _sessionGuard.capture() : null;
    final db = await _db.database;
    final promoId = await db.transaction((txn) async {
      if (session != null) _sessionGuard.require(session);
      final promoMap =
          promo.toMap()
            ..['id'] = _newProductId()
            ..['name'] = promo.name.toUpperCase()
            ..['is_promo'] = 1
            ..['stock'] = 0.0
            ..['synced'] = 0
            ..['billar_id'] = _prefs.billarId;
      final id = await txn.insert('products', promoMap);
      for (final entry in components.entries) {
        await txn.insert('promo_items', {
          'parent_id': id,
          'child_id': entry.key,
          'quantity': entry.value,
        });
      }
      if (session != null) {
        await OwnerPromoOutbox(db, _sessionGuard.require).registerNew(
          txn, session, id,
        );
        _sessionGuard.require(session);
      }
      return id;
    });

    // Sincronizar promo a Supabase
    final insertedPromo = await db.query('products', where: 'id = ?', whereArgs: [promoId]);
    if (insertedPromo.isNotEmpty) {
      debugPrint('[Sync] Promo insertada localmente: ${insertedPromo.first}');
      await _syncToCloud(promoId, session: session);
    }

    // Sincronizar promo_items a Supabase
    if (_atomicPromoSync) {
      SyncService().schedulePendingSync();
    } else {
      await _syncPromoItemsToCloud(promoId, components);
    }
  }

  @override
  Future<Map<int, int>> getPromoComponents(int promoId) async {
    final db = await _db.database;
    final rows = await db.query('promo_items', where: 'parent_id = ?', whereArgs: [promoId]);
    final result = <int, int>{};
    for (final r in rows) {
      result[r['child_id'] as int] = (r['quantity'] as num).toInt();
    }
    return result;
  }

  @override
  Future<void> updatePromo(ProductEntity promo, Map<int, int> components) async {
    final session = _atomicPromoSync ? _sessionGuard.capture() : null;
    final db = await _db.database;
    final promoId = promo.id!;
    await db.transaction((txn) async {
      if (session != null) {
        _sessionGuard.require(session);
        final rows = await txn.query(
          'products',
          columns: ['stock_revision'],
          where: 'id = ? AND billar_id = ? AND is_promo = 1',
          whereArgs: [promoId, session.billarId],
        );
        if (rows.length != 1) {
          throw StateError('La promoción no pertenece al billar actual.');
        }
        final pending = await txn.query(
          'pending_owner_promos',
          where: 'product_id = ?',
          whereArgs: [promoId],
        );
        if (pending.isNotEmpty &&
            (pending.single['actor_id'] != session.actorId ||
                pending.single['billar_id'] != session.billarId)) {
          throw StateError('La promoción pendiente pertenece a otra cuenta.');
        }
        if (rows.single['stock_revision'] == null) {
          if (pending.isEmpty || pending.single['is_new'] != 1) {
            throw StateError('La promoción necesita una revisión remota antes de editarse.');
          }
        }
        if (pending.isEmpty) {
          await txn.insert('pending_owner_promos', {
            'product_id': promoId,
            'actor_id': session.actorId,
            'billar_id': session.billarId,
            'is_new': 0,
          });
        }
      } else {
        final pending = await txn.query(
          'pending_owner_promos',
          columns: ['product_id'],
          where: 'product_id = ?',
          whereArgs: [promoId],
          limit: 1,
        );
        if (pending.isNotEmpty) {
          throw StateError('La promoción tiene una operación atómica pendiente.');
        }
      }
      final promoMap =
          promo.toMap()
            ..['name'] = promo.name.toUpperCase()
            ..['is_promo'] = 1
            ..['stock'] = 0.0
            ..['synced'] = 0
            ..['billar_id'] = _prefs.billarId;
      await txn.update('products', promoMap, where: 'id = ?', whereArgs: [promoId]);
      // Reemplazar componentes
      await txn.delete('promo_items', where: 'parent_id = ?', whereArgs: [promoId]);
      for (final entry in components.entries) {
        await txn.insert('promo_items', {
          'parent_id': promoId,
          'child_id': entry.key,
          'quantity': entry.value,
        });
      }
      if (session != null) _sessionGuard.require(session);
    });

    final updated = await db.query('products', where: 'id = ?', whereArgs: [promoId]);
    if (updated.isNotEmpty) {
      await _syncToCloud(promoId, session: session);
    }
    // Reemplazar promo_items en la nube
    if (_atomicPromoSync) {
      SyncService().schedulePendingSync();
    } else {
      try {
        await _supabase.from('promo_items').delete().eq('parent_id', promoId);
      } catch (e) {
        debugPrint('[Supabase promo_items delete] aviso: $e');
      }
      await _syncPromoItemsToCloud(promoId, components);
    }
  }

  Future<void> _syncPromoItemsToCloud(int promoId, Map<int, int> components) async {
    try {
      for (final entry in components.entries) {
        await _supabase.from('promo_items').insert({
          'parent_id': promoId,
          'child_id': entry.key,
          'quantity': entry.value,
        });
      }
      debugPrint('[Sync] Promo items sincronizados para promo $promoId');
    } catch (e) {
      debugPrint('[Supabase promo_items sync] ERROR: $e');
    }
  }

  @override
  Future<void> decreaseStock(ProductEntity product, double quantity) async {
    final db = await _db.database;
    if (product.parentId != null) {
      // Es un producto hijo (caja/paquete): descontar piezas equivalentes del padre.
      // El stock del hijo se calcula siempre a partir del padre.
      final pieces = quantity * product.piecesPerUnit;
      await db.rawUpdate('UPDATE products SET stock = stock - ?, synced = 0 WHERE id = ?', [
        pieces,
        product.parentId,
      ]);
      // Sincronizar el producto padre a Supabase
      final updated = await db.query('products', where: 'id = ?', whereArgs: [product.parentId]);
      if (updated.isNotEmpty) {
        await _syncToCloud(product.parentId!);
      }
    } else if (product.isPromo == 1) {
      final components = await db.query(
        'promo_items',
        where: 'parent_id = ?',
        whereArgs: [product.id],
      );
      for (final c in components) {
        await db.rawUpdate('UPDATE products SET stock = stock - (? * ?), synced = 0 WHERE id = ?', [
          quantity,
          c['quantity'],
          c['child_id'],
        ]);
        // Sincronizar cada componente a Supabase
        final updated = await db.query('products', where: 'id = ?', whereArgs: [c['child_id']]);
        if (updated.isNotEmpty) {
          await _syncToCloud(c['child_id'] as int);
        }
      }
    } else {
      await db.rawUpdate('UPDATE products SET stock = stock - ?, synced = 0 WHERE id = ?', [
        quantity,
        product.id,
      ]);
      // Sincronizar a Supabase con el stock actualizado
      final updated = await db.query('products', where: 'id = ?', whereArgs: [product.id]);
      if (updated.isNotEmpty) {
        await _syncToCloud(product.id!);
      }
    }
  }

  /// Inverso de [decreaseStock]: devuelve stock al inventario (usado al anular
  /// una venta). Replica la misma lógica de hijos/promos y sincroniza a nube.
  Future<void> increaseStock(ProductEntity product, double quantity) async {
    final db = await _db.database;
    if (product.parentId != null) {
      // Es un producto hijo (caja/paquete): devolver piezas equivalentes al padre.
      final pieces = quantity * product.piecesPerUnit;
      await db.rawUpdate('UPDATE products SET stock = stock + ?, synced = 0 WHERE id = ?', [
        pieces,
        product.parentId,
      ]);
      final updated = await db.query('products', where: 'id = ?', whereArgs: [product.parentId]);
      if (updated.isNotEmpty) {
        await _syncToCloud(product.parentId!);
      }
    } else if (product.isPromo == 1) {
      final components = await db.query(
        'promo_items',
        where: 'parent_id = ?',
        whereArgs: [product.id],
      );
      for (final c in components) {
        await db.rawUpdate('UPDATE products SET stock = stock + (? * ?), synced = 0 WHERE id = ?', [
          quantity,
          c['quantity'],
          c['child_id'],
        ]);
        final updated = await db.query('products', where: 'id = ?', whereArgs: [c['child_id']]);
        if (updated.isNotEmpty) {
          await _syncToCloud(c['child_id'] as int);
        }
      }
    } else {
      await db.rawUpdate('UPDATE products SET stock = stock + ?, synced = 0 WHERE id = ?', [
        quantity,
        product.id,
      ]);
      final updated = await db.query('products', where: 'id = ?', whereArgs: [product.id]);
      if (updated.isNotEmpty) {
        await _syncToCloud(product.id!);
      }
    }
  }

  @override
  Future<void> syncProductById(int id) async {
    try {
      final session = _sessionGuard.capture();
      final db = await _db.database;
      final rows = await db.query(
        'products',
        where: 'id = ? AND billar_id = ?',
        whereArgs: [id, session.billarId],
      );
      _sessionGuard.require(session);
      if (rows.isEmpty) return;
      await _syncToCloud(id, session: session);
    } catch (e) {
      debugPrint('[syncProductById] ERROR: $e');
    }
  }

  Future<void> syncPendingProducts() async {
    try {
      final session = _sessionGuard.capture();
      await _syncPendingProductDeletions(session);
      _sessionGuard.require(session);
      final db = await _db.database;
      final pending = await db.query(
        'products',
        where: 'synced = ? AND stock_conflict = ? AND billar_id = ?',
        whereArgs: [0, 0, session.billarId],
        orderBy: 'id ASC',
      );
      debugPrint('[Sync] Productos pendientes: ${pending.length}');
      for (final row in pending) {
        _sessionGuard.require(session);
        await _syncToCloud(row['id'] as int, session: session);
      }
    } on StateError catch (error) {
      debugPrint('[Sync] Productos pendientes: $error');
    }
  }

  Future<List<ProductEntity>> getStockConflicts() async {
    final db = await _db.database;
    final rows = await db.query(
      'products',
      where: 'billar_id = ? AND stock_conflict = 1',
      whereArgs: [_prefs.billarId],
      orderBy: 'name ASC',
    );
    return rows.map(ProductEntity.fromMap).toList();
  }

  Future<StockConflictSnapshot> getStockConflictSnapshot(int id) async {
    final db = await _db.database;
    final rows = await db.query(
      'products',
      where: 'id = ? AND billar_id = ? AND stock_conflict = 1',
      whereArgs: [id, _prefs.billarId],
    );
    if (rows.isEmpty) throw StateError('El conflicto ya no está disponible.');
    final remote = await _supabase
        .from('products')
        .select('stock, stock_revision')
        .eq('billar_id', _prefs.billarId)
        .eq('id', id)
        .maybeSingle();
    if (remote == null || remote['stock_revision'] == null || remote['stock'] == null) {
      throw StateError('No se pudo consultar la existencia actual en el servidor.');
    }
    return (
      product: ProductEntity.fromMap(rows.first),
      localRevision: rows.first['local_revision'] as int,
      remoteStock: (remote['stock'] as num).toDouble(),
      remoteRevision: (remote['stock_revision'] as num).toInt(),
    );
  }

  Future<void> resolveStockConflict(StockConflictSnapshot snapshot, double stock) async {
    if (!stock.isFinite) throw ArgumentError('La existencia debe ser un número válido.');
    final id = snapshot.product.id;
    if (id == null) throw StateError('El producto no tiene identificador.');
    final billarId = _prefs.billarId;
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) throw StateError('Inicia sesión para resolver el conflicto.');
    final db = await _db.database;
    final current = await db.query(
      'products',
      where: 'id = ? AND billar_id = ? AND stock_conflict = 1 AND local_revision = ?',
      whereArgs: [id, billarId, snapshot.localRevision],
    );
    if (current.isEmpty) {
      throw StateError('El producto cambió en este dispositivo. Vuelve a revisar el conflicto.');
    }
    final remote = await _supabase.rpc(
      'resolve_product_stock_conflict',
      params: {
        'p_billar_id': billarId,
        'p_product_id': id,
        'p_expected_revision': snapshot.remoteRevision,
        'p_stock': stock,
      },
    );
    if (remote is! int) {
      throw StateError('El inventario cambió en el servidor. Vuelve a revisar el conflicto.');
    }
    if (_supabase.auth.currentUser?.id != userId || _prefs.billarId != billarId) {
      throw StateError('La sesión cambió durante la revisión. Vuelve a revisar el conflicto.');
    }
    final updated = await db.transaction((txn) async {
      await txn.update(
        'products',
        {'stock_revision': remote},
        where: 'id = ? AND billar_id = ?',
        whereArgs: [id, billarId],
      );
      return txn.update(
        'products',
        {'stock': stock, 'synced': 0, 'stock_conflict': 0},
        where: 'id = ? AND billar_id = ? AND stock_conflict = 1 AND local_revision = ?',
        whereArgs: [id, billarId, snapshot.localRevision],
      );
    });
    conflictChanges.value++;
    if (updated == 0) {
      throw StateError(
        'El producto cambió en este dispositivo durante la revisión. Vuelve a revisar el conflicto.',
      );
    }
    await _syncToCloud(id);
    final after = await db.query(
      'products',
      columns: ['stock_conflict', 'synced'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (after.isNotEmpty && after.first['stock_conflict'] == 1) {
      throw StateError('El inventario cambió nuevamente. Vuelve a revisar el conflicto.');
    }
    if (after.isNotEmpty && after.first['synced'] == 0) {
      SyncService().schedulePendingSync();
    }
  }

  @override
  Future<List<String>> getCategories() async {
    final db = await _db.database;
    _syncCategoriesFromCloud().catchError(
      (e) => debugPrint('[Categories] Background sync error: $e'),
    );
    final rows = await db.query('categories', orderBy: 'name ASC');
    return rows.map((m) => m['name'].toString()).toList();
  }

  @override
  Future<void> addCategory(String name) async {
    final clean = name.trim().toUpperCase();
    if (clean.isEmpty) return;
    final db = await _db.database;
    final billarId = _prefs.billarId;
    try {
      await db.insert('categories', {'name': clean, 'billar_id': billarId});
    } catch (e) {
      // Categoría duplicada (UNIQUE) u otro error no crítico.
      debugPrint('[Categories] addCategory aviso: $e');
    }
    try {
      await _supabase.from('categories').upsert({
        'name': clean,
        'billar_id': billarId,
      }, onConflict: 'billar_id,name');
      debugPrint('[Supabase] Categoría sincronizada: $clean');
    } catch (e) {
      debugPrint('[Supabase] addCategory ERROR: $e');
    }
  }

  Future<void> _syncCategoriesFromCloud() async {
    try {
      final billarId = _prefs.billarId;
      final response = await _supabase
          .from('categories')
          .select()
          .eq('billar_id', billarId)
          .timeout(const Duration(seconds: 8));

      final db = await _db.database;
      for (final item in (response as List)) {
        final name = item['name']?.toString();
        if (name == null || name.isEmpty) continue;
        try {
          await db.insert('categories', {'name': name, 'billar_id': billarId});
        } catch (_) {
          // Ya existe localmente (UNIQUE), se ignora.
        }
      }
    } catch (e) {
      debugPrint('[Categories syncFromCloud] ERROR: $e');
    }
  }
}
