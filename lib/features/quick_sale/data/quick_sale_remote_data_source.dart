import '../domain/entities/pending_sale.dart';

abstract class QuickSaleRemoteDataSource {
  Future<bool> syncSale(PendingSale sale);
}
