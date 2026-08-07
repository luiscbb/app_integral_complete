import '../../../../core/database/database_helper.dart';
import '../../domain/entities/sale_item_entity.dart';

/// Gestiona reservas temporales de stock que aún no han sido cobradas.
/// Se usa para compartir entre venta rápida y mesas de billar la misma
/// percepción de stock disponible, sin descontar físicamente del inventario
/// hasta que la venta se concrete.
class StockReservationService {
  static final StockReservationService _instance = StockReservationService._internal();
  factory StockReservationService() => _instance;
  StockReservationService._internal();

  final _db = DatabaseHelper.instance;

  /// Crea o reemplaza una reserva de venta rápida (hay una sola activa).
  /// [items] son las cantidades actuales del carrito.
  Future<void> setQuickSaleReservation(List<SaleItemEntity> items) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.delete('temp_reservations', where: 'source = ?', whereArgs: ['quick_sale']);
      for (final item in items) {
        if (item.productId == null || item.quantity <= 0) continue;
        await txn.insert('temp_reservations', {
          'source': 'quick_sale',
          'source_id': 0,
          'product_id': item.productId,
          'quantity': item.quantity,
          'created_at': DateTime.now().toIso8601String(),
        });
      }
    });
  }

  /// Limpia la reserva de venta rápida (por ejemplo al cerrar/cobrar).
  Future<void> clearQuickSaleReservation() async {
    final db = await _db.database;
    await db.delete('temp_reservations', where: 'source = ?', whereArgs: ['quick_sale']);
  }

  /// Guarda las órdenes de una mesa como reservas temporales.
  Future<void> setTableReservation(int tableId, List<SaleItemEntity> items) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.delete('temp_reservations', where: 'source = ? AND source_id = ?', whereArgs: ['table', tableId]);
      for (final item in items) {
        if (item.productId == null || item.quantity <= 0) continue;
        await txn.insert('temp_reservations', {
          'source': 'table',
          'source_id': tableId,
          'product_id': item.productId,
          'quantity': item.quantity,
          'created_at': DateTime.now().toIso8601String(),
        });
      }
    });
  }

  /// Limpia las reservas de una mesa específica.
  Future<void> clearTableReservation(int tableId) async {
    final db = await _db.database;
    await db.delete('temp_reservations', where: 'source = ? AND source_id = ?', whereArgs: ['table', tableId]);
  }

  /// Suma todas las cantidades reservadas por producto, excluyendo una
  /// fuente opcional (por ejemplo, la mesa actual o el carrito actual).
  Future<Map<int, double>> getReservedQuantities({
    String? excludeSource,
    int? excludeSourceId,
  }) async {
    final db = await _db.database;
    final rows = await db.query('temp_reservations');
    final Map<int, double> reserved = {};
    for (final row in rows) {
      final source = row['source'] as String;
      final sourceId = row['source_id'] as int;
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
