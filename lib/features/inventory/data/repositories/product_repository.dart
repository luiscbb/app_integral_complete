import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../domain/entities/product_entity.dart';
import '../../domain/repositories/i_product_repository.dart';

class ProductRepository implements IProductRepository {
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  SupabaseClient get _supabase => Supabase.instance.client;

  @override
  Future<List<ProductEntity>> getAll() async {
    final db = await _db.database;
    final maps = await db.query('products', orderBy: 'name ASC');
    final base = maps.map((m) => ProductEntity.fromMap(m)).toList();

    // Sync en background sin bloquear la UI
    _syncFromCloud().catchError((e) => debugPrint('[Sync] Background sync error: $e'));

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

  Future<void> _syncFromCloud() async {
    try {
      final billarId = _prefs.billarId;
      debugPrint('[Sync] Iniciando descarga para billarId: $billarId');

      final response = await _supabase
          .from('products')
          .select()
          .eq('billar_id', billarId)
          .timeout(const Duration(seconds: 8));

      debugPrint('[Sync] Productos recibidos: ${(response as List).length}');

      final db = await _db.database;

      // Obtener IDs de productos en Supabase
      final cloudIds = (response as List).map((e) => e['id'] as int).toSet();

      await db.transaction((txn) async {
        for (final item in response) {
          final map = Map<String, dynamic>.from(item);
          final cleanMap = {
            'id': map['id'],
            'billar_id': map['billar_id'],
            'barcode': map['barcode'],
            'name': map['name'],
            'description': map['description'],
            'price': map['price'],
            'cost': map['cost'],
            'stock': map['stock'],
            'image_path': map['image_path'],
            'is_promo': map['is_promo'],
            'parent_id': map['parent_id'],
            'pieces_per_unit': map['pieces_per_unit'],
            'category': map['category'] ?? '',
            'presentation': map['presentation'] ?? '',
          };

          if (cleanMap['id'] != null) {
            // Para productos EXISTENTES: update SOLO datos administrativos, NUNCA stock
            final existing = await txn.query('products', where: 'id = ?', whereArgs: [cleanMap['id']]);
            if (existing.isNotEmpty) {
              // Producto local existe: actualizar solo lo que NO es stock
              await txn.update(
                'products',
                {
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
                  'billar_id': cleanMap['billar_id'],
                  'synced': 1,
                  // NUNCA actualizar stock
                },
                where: 'id = ?',
                whereArgs: [cleanMap['id']],
              );
            } else {
              // Producto NUEVO: insertar todo incluyendo stock
              await txn.insert('products', {...cleanMap, 'synced': 1});
            }
          }
        }

        // Eliminar productos locales que ya no existen en la nube.
        final localProducts = await txn.query('products', where: 'billar_id = ?', whereArgs: [billarId]);
        final hasUnsynced = localProducts.any((r) => (r['synced'] as int? ?? 0) == 0);
        // Si la nube está vacía y hay productos locales no sincronizados,
        // NO borrar: probablemente acaban de crearse y aún no suben.
        if (cloudIds.isNotEmpty || !hasUnsynced) {
          for (final local in localProducts) {
            final localId = local['id'] as int?;
            if (localId != null && !cloudIds.contains(localId)) {
              await txn.delete('products', where: 'id = ?', whereArgs: [localId]);
              debugPrint('[Sync] Producto eliminado localmente: $localId');
            }
          }
        } else {
          debugPrint('[Sync] Nube vacía y hay productos locales no sincronizados; no se eliminan locales');
        }
      });
      debugPrint('[Sync] Descarga completada exitosamente');
    } catch (e) {
      debugPrint('[Supabase syncFromCloud] ERROR: $e');
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
        final childRows = await txn.query(
          'products',
          where: 'parent_id = ?',
          whereArgs: [p.id],
        );
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
            },
            where: 'id = ?',
            whereArgs: [childId],
          );
          cajaMap = Map<String, dynamic>.from(childRows.first);
          cajaMap!['id'] = childId;
        }
        await txn.update('products', map, where: 'id = ?', whereArgs: [p.id]);
        id = p.id!;
      } else {
        id = await txn.insert('products', map);
      }

      if (p.id == null && p.piecesPerUnit > 1 && p.isPromo == 0) {
        cajaMap = {
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

    _syncToCloud(p, productId, cajaMap);
    return productId;
  }

  Future<void> _syncToCloud(ProductEntity p, int localId, Map<String, dynamic>? cajaData) async {
    try {
      String? finalUrl = p.imagePath;
      if (p.imagePath != null && !p.imagePath!.startsWith('http')) {
        finalUrl = await _uploadImage(p.imagePath!);
        if (finalUrl != null) {
          final db = await _db.database;
          await db.update(
            'products',
            {'image_path': finalUrl},
            where: 'id = ?',
            whereArgs: [localId],
          );
        }
      }
      final billarId = _prefs.billarId;
      final map =
          p.toMap()
            ..['id'] = localId
            ..['image_path'] = finalUrl
            ..['name'] = p.name.toUpperCase()
            ..['billar_id'] = billarId;

      debugPrint('[Sync] Subiendo producto: ${p.name} con precio: ${p.price}, billar_id: $billarId');
      debugPrint('[Sync] Map completo antes de upsert: $map');
      await _supabase.from('products').upsert(map);
      debugPrint('[Supabase] Producto sincronizado: ${p.name} con precio ${map['price']}');
      final db = await _db.database;
      await db.update('products', {'synced': 1}, where: 'id = ?', whereArgs: [localId]);

      if (cajaData != null) {
        cajaData['image_path'] = finalUrl;
        cajaData['billar_id'] = billarId;
        await _supabase.from('products').upsert(cajaData);
        debugPrint('[Supabase] Caja sincronizada: ${cajaData['name']}');
        final cajaId = cajaData['id'] as int?;
        if (cajaId != null) {
          await db.update('products', {'synced': 1}, where: 'id = ?', whereArgs: [cajaId]);
        }
      }
    } catch (e) {
      debugPrint('[Supabase syncToCloud] ERROR: $e');
    }
  }

  Future<String?> _uploadImage(String localPath) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) return null;
      final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
      final path = 'products/$fileName';
      await _supabase.storage
          .from('product_images')
          .uploadBinary(
            path,
            await file.readAsBytes(),
            fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
          );
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
    final map = p.toMap()..['name'] = p.name.toUpperCase();
    final result = await db.update('products', map, where: 'id = ?', whereArgs: [p.id]);
    _syncToCloud(p, p.id!, null);
    return result;
  }

  @override
  Future<int> delete(int id) async {
    final db = await _db.database;
    // Recuperar imágenes del producto y de sus hijos (promo) para limpiar el bucket.
    final rows = await db.query(
      'products',
      columns: ['image_path'],
      where: 'id = ? OR parent_id = ?',
      whereArgs: [id, id],
    );
    for (final row in rows) {
      await _deleteImageIfCloud(row['image_path'] as String?);
    }
    // Limpiar relaciones de promo (si las hubiera) en la nube y local.
    try {
      await _supabase.from('promo_items').delete().eq('parent_id', id);
    } catch (_) {}
    try {
      await _supabase.from('products').delete().eq('parent_id', id);
    } catch (_) {}
    try {
      await _supabase.from('products').delete().eq('id', id);
    } catch (e) {
      debugPrint('[Supabase delete] aviso: $e');
    }
    await db.delete('promo_items', where: 'parent_id = ?', whereArgs: [id]);
    await db.delete('products', where: 'parent_id = ?', whereArgs: [id]);
    return db.delete('products', where: 'id = ?', whereArgs: [id]);
  }

  /// Elimina un archivo de Supabase Storage a partir de su URL pública,
  /// si corresponde al bucket `product_images`. Evita acumular imágenes
  /// huérfanas cuando un producto se borra o se reemplaza su foto.
  Future<void> _deleteImageIfCloud(String? imageUrl) async {
    if (imageUrl == null || !imageUrl.startsWith('http')) return;
    try {
      const marker = 'product_images/';
      final idx = imageUrl.indexOf(marker);
      if (idx == -1) return;
      final storagePath = imageUrl.substring(idx + marker.length);
      await _supabase.storage.from('product_images').remove([storagePath]);
    } catch (e) {
      debugPrint('[Storage delete] aviso: $e');
    }
  }

  @override
  Future<void> insertPromo(ProductEntity promo, Map<int, int> components) async {
    final db = await _db.database;
    final promoId = await db.transaction((txn) async {
      final promoMap =
          promo.toMap()
            ..['name'] = promo.name.toUpperCase()
            ..['is_promo'] = 1
            ..['stock'] = 0.0
            ..['billar_id'] = _prefs.billarId;
      final id = await txn.insert('products', promoMap);
      for (final entry in components.entries) {
        await txn.insert('promo_items', {
          'parent_id': id,
          'child_id': entry.key,
          'quantity': entry.value,
        });
      }
      return id;
    });

    // Sincronizar promo a Supabase
    final insertedPromo = await db.query('products', where: 'id = ?', whereArgs: [promoId]);
    if (insertedPromo.isNotEmpty) {
      debugPrint('[Sync] Promo insertada localmente: ${insertedPromo.first}');
      await _syncToCloud(ProductEntity.fromMap(insertedPromo.first), promoId, null);
    }

    // Sincronizar promo_items a Supabase
    await _syncPromoItemsToCloud(promoId, components);
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
    final db = await _db.database;
    final promoId = promo.id!;
    await db.transaction((txn) async {
      final promoMap =
          promo.toMap()
            ..['name'] = promo.name.toUpperCase()
            ..['is_promo'] = 1
            ..['stock'] = 0.0
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
    });

    final updated = await db.query('products', where: 'id = ?', whereArgs: [promoId]);
    if (updated.isNotEmpty) {
      await _syncToCloud(ProductEntity.fromMap(updated.first), promoId, null);
    }
    // Reemplazar promo_items en la nube
    try {
      await _supabase.from('promo_items').delete().eq('parent_id', promoId);
    } catch (e) {
      debugPrint('[Supabase promo_items delete] aviso: $e');
    }
    await _syncPromoItemsToCloud(promoId, components);
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
      await db.rawUpdate('UPDATE products SET stock = stock - ? WHERE id = ?', [
        pieces,
        product.parentId,
      ]);
      // Sincronizar el producto padre a Supabase
      final updated = await db.query('products', where: 'id = ?', whereArgs: [product.parentId]);
      if (updated.isNotEmpty) {
        await _syncToCloud(ProductEntity.fromMap(updated.first), product.parentId!, null);
      }
    } else if (product.isPromo == 1) {
      final components = await db.query(
        'promo_items',
        where: 'parent_id = ?',
        whereArgs: [product.id],
      );
      for (final c in components) {
        await db.rawUpdate('UPDATE products SET stock = stock - (? * ?) WHERE id = ?', [
          quantity,
          c['quantity'],
          c['child_id'],
        ]);
        // Sincronizar cada componente a Supabase
        final updated = await db.query('products', where: 'id = ?', whereArgs: [c['child_id']]);
        if (updated.isNotEmpty) {
          await _syncToCloud(ProductEntity.fromMap(updated.first), c['child_id'] as int, null);
        }
      }
    } else {
      await db.rawUpdate('UPDATE products SET stock = stock - ? WHERE id = ?', [
        quantity,
        product.id,
      ]);
      // Sincronizar a Supabase con el stock actualizado
      final updated = await db.query('products', where: 'id = ?', whereArgs: [product.id]);
      if (updated.isNotEmpty) {
        await _syncToCloud(ProductEntity.fromMap(updated.first), product.id!, null);
      }
    }
  }

  @override
  Future<void> syncProductById(int id) async {
    try {
      final db = await _db.database;
      final rows = await db.query('products', where: 'id = ?', whereArgs: [id]);
      if (rows.isEmpty) return;
      final product = ProductEntity.fromMap(rows.first);
      await _syncToCloud(product, id, null);
      debugPrint('[Sync] Producto $id sincronizado tras cambio de stock');
    } catch (e) {
      debugPrint('[syncProductById] ERROR: $e');
    }
  }

  @override
  Future<List<String>> getCategories() async {
    final db = await _db.database;
    _syncCategoriesFromCloud().catchError((e) => debugPrint('[Categories] Background sync error: $e'));
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
      await _supabase.from('categories').upsert(
        {'name': clean, 'billar_id': billarId},
        onConflict: 'billar_id,name',
      );
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
