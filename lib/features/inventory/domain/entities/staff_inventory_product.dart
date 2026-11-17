class StaffInventoryProduct {
  const StaffInventoryProduct({
    required this.id,
    required this.name,
    required this.price,
    required this.cost,
    required this.stock,
    required this.category,
    required this.presentation,
    required this.barcode,
    required this.isPromo,
    required this.parentId,
  });

  final int id;
  final String name;
  final double price;
  final double cost;
  final double stock;
  final String category;
  final String presentation;
  final String? barcode;
  final bool isPromo;
  final int? parentId;

  factory StaffInventoryProduct.fromMap(
    Map<String, dynamic> row, {
    required String billarId,
  }) {
    final id = row['id'];
    final name = row['name'];
    final price = row['price'];
    final cost = row['cost'];
    final stock = row['stock'];
    final category = row['category'];
    final presentation = row['presentation'];
    final barcode = row['barcode'];
    final promo = row['is_promo'];
    final parent = row['parent_id'];
    if (row['billar_id'] != billarId ||
        id is! int ||
        id <= 0 ||
        name is! String ||
        name.trim().isEmpty ||
        price is! num ||
        !price.toDouble().isFinite ||
        price < 0 ||
        cost is! num ||
        !cost.toDouble().isFinite ||
        cost < 0 ||
        stock is! num ||
        !stock.toDouble().isFinite ||
        category != null && category is! String ||
        presentation != null && presentation is! String ||
        barcode != null && barcode is! String ||
        promo is! int ||
        (promo != 0 && promo != 1) ||
        parent != null && (parent is! int || parent <= 0 || parent == id) ||
        row['is_active'] != true) {
      throw const FormatException(
        'La información del inventario no es válida.',
      );
    }
    return StaffInventoryProduct(
      id: id,
      name: name,
      price: price.toDouble(),
      cost: cost.toDouble(),
      stock: stock.toDouble(),
      category: category as String? ?? '',
      presentation: presentation as String? ?? '',
      barcode: barcode as String?,
      isPromo: promo == 1,
      parentId: parent as int?,
    );
  }
}
