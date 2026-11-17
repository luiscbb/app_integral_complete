import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../domain/entities/sale_item_entity.dart';

/// Gestiona reservas temporales de stock que aún no han sido cobradas.
/// Se usa para compartir entre venta rápida y mesas de billar la misma
/// percepción de stock disponible, sin descontar físicamente del inventario
/// hasta que la venta se concrete.
class StockReservationService {
  static final StockReservationService _instance =
      StockReservationService._internal();
  factory StockReservationService({String? Function()? currentActorId}) =>
      currentActorId == null
          ? _instance
          : StockReservationService._internal(currentActorId: currentActorId);
  StockReservationService._internal({String? Function()? currentActorId})
    : _currentActorId =
          currentActorId ??
          (() => Supabase.instance.client.auth.currentUser?.id);

  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  final String? Function() _currentActorId;

  String _captureActor() {
    final actorId = _currentActorId();
    if (actorId == null || actorId.isEmpty) {
      throw StateError(
        'Se requiere una sesión para consultar o modificar reservas.',
      );
    }
    return actorId;
  }

  void _requireScope(String actorId, String billarId) {
    if (_currentActorId() != actorId || _prefs.billarId != billarId) {
      throw StateError(
        'La cuenta o el billar cambió durante la operación de reservas.',
      );
    }
  }

  Future<void> _replaceReservation({
    required String source,
    required List<SaleItemEntity> items,
    int? sourceId,
    String? sourceKey,
  }) async {
    final actorId = _captureActor();
    final billarId = _prefs.billarId;
    final db = await _db.database;
    await db.transaction((txn) async {
      _requireScope(actorId, billarId);
      if (source == 'quick_sale') {
        final pending = await txn.query(
          'pending_staff_sales',
          columns: ['request_id'],
          where: 'actor_id = ? AND billar_id = ?',
          whereArgs: [actorId, billarId],
          limit: 1,
        );
        if (pending.isNotEmpty) {
          throw StateError(
            'Hay una venta pendiente; recupérala antes de modificar el carrito.',
          );
        }
      }
      if (source == 'table' && sourceId != null) {
        final table = await txn.query(
          'billiard_tables',
          columns: ['id'],
          where: 'id = ? AND billar_id = ?',
          whereArgs: [sourceId, billarId],
          limit: 1,
        );
        if (table.isEmpty) {
          throw StateError(
            'La mesa no pertenece al billar actual o no existe.',
          );
        }
      }
      final filters = <String>[
        'source = ?',
        'product_id IN (SELECT id FROM products WHERE billar_id = ?)',
      ];
      final args = <Object?>[source, billarId];
      if (sourceId != null) {
        filters.add('source_id = ?');
        args.add(sourceId);
      }
      if (sourceKey != null) {
        filters.add('source_key = ?');
        args.add(sourceKey);
      }
      await txn.delete(
        'temp_reservations',
        where: filters.join(' AND '),
        whereArgs: args,
      );
      for (final item in items) {
        if (item.productId == null || item.quantity <= 0) continue;
        final product = await txn.query(
          'products',
          columns: ['id'],
          where: 'id = ? AND billar_id = ?',
          whereArgs: [item.productId, billarId],
          limit: 1,
        );
        if (product.isEmpty) {
          throw StateError(
            'El producto reservado no pertenece al billar actual o no existe.',
          );
        }
        await txn.insert('temp_reservations', {
          'source': source,
          'source_id': sourceId ?? 0,
          if (sourceKey != null) 'source_key': sourceKey,
          'product_id': item.productId,
          'quantity': item.quantity,
          'created_at': DateTime.now().toIso8601String(),
        });
      }
      _requireScope(actorId, billarId);
    });
  }

  /// Crea o reemplaza una reserva de venta rápida (hay una sola activa).
  /// [items] son las cantidades actuales del carrito.
  Future<void> setQuickSaleReservation(List<SaleItemEntity> items) async {
    await _replaceReservation(source: 'quick_sale', items: items);
  }

  /// Limpia la reserva de venta rápida (por ejemplo al cerrar/cobrar).
  Future<void> clearQuickSaleReservation() async {
    await _replaceReservation(source: 'quick_sale', items: const []);
  }

  /// Guarda las órdenes de una mesa como reservas temporales.
  Future<void> setTableReservation(
    int tableId,
    List<SaleItemEntity> items,
  ) async {
    await _replaceReservation(source: 'table', sourceId: tableId, items: items);
  }

  /// Limpia las reservas de una mesa específica.
  Future<void> clearTableReservation(int tableId) async {
    await _replaceReservation(
      source: 'table',
      sourceId: tableId,
      items: const [],
    );
  }

  Future<void> setCustomerReservation(
    String clientKey,
    List<SaleItemEntity> items,
  ) async {
    await _replaceReservation(
      source: 'customer',
      sourceKey: clientKey,
      items: items,
    );
  }

  /// Suma todas las cantidades reservadas por producto, excluyendo una
  /// fuente opcional (por ejemplo, la mesa actual o el carrito actual).
  Future<Map<int, double>> getReservedQuantities({
    String? excludeSource,
    int? excludeSourceId,
    String? includeSource,
    Set<String> excludeSources = const {},
  }) async {
    final actorId = _captureActor();
    final billarId = _prefs.billarId;
    final db = await _db.database;
    final rows = await db.query(
      'temp_reservations',
      where: 'product_id IN (SELECT id FROM products WHERE billar_id = ?)',
      whereArgs: [billarId],
    );
    _requireScope(actorId, billarId);
    final Map<int, double> reserved = {};
    for (final row in rows) {
      final source = row['source'] as String;
      final sourceId = row['source_id'] as int;
      if (includeSource != null && source != includeSource) continue;
      if (excludeSources.contains(source)) continue;
      if (excludeSource != null &&
          source == excludeSource &&
          (excludeSourceId == null || sourceId == excludeSourceId)) {
        continue;
      }
      final pid = row['product_id'] as int;
      final qty = (row['quantity'] as num).toDouble();
      reserved[pid] = (reserved[pid] ?? 0) + qty;
    }
    return reserved;
  }
}
