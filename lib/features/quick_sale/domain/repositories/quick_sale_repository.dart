abstract class QuickSaleRepository {
  Future<void> saveQuickSale(String product, int quantity, double price);
  Future<void> syncPendingSales();
  Future<int> pendingSyncCount();
}
