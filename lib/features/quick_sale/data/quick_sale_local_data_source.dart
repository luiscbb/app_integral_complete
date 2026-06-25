import '../../../../core/database/database_helper.dart';
import '../domain/entities/pending_sale.dart';

class QuickSaleLocalDataSource {
  Future<void> savePendingSale(PendingSale sale) async {
    final db = await DatabaseHelper.instance.database;
    await db.insert('pending_sales', sale.toMap());
  }

  Future<List<PendingSale>> loadPendingSales() async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('pending_sales', where: 'synced = 0');
    return rows.map((r) => PendingSale.fromMap(r)).toList();
  }

  Future<void> markPendingSaleSynced(int id) async {
    final db = await DatabaseHelper.instance.database;
    await db.update('pending_sales', {'synced': 1}, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> pendingCount() async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.rawQuery('SELECT COUNT(*) as c FROM pending_sales WHERE synced = 0');
    return (result.first['c'] as int?) ?? 0;
  }
}
