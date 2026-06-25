import '../entities/product_entity.dart';

abstract class IProductRepository {
  Future<List<ProductEntity>> getAll();
  Future<int> insert(ProductEntity product, {double? priceCaja});
  Future<int> update(ProductEntity product);
  Future<int> delete(int id);
  Future<void> insertPromo(ProductEntity promo, Map<int, int> components);
  Future<void> updatePromo(ProductEntity promo, Map<int, int> components);
  Future<Map<int, int>> getPromoComponents(int promoId);
  Future<void> decreaseStock(ProductEntity product, double quantity);
  Future<void> syncProductById(int id);
  Future<List<String>> getCategories();
  Future<void> addCategory(String name);
}
