import 'dart:math' as math;

class StaffSaleProduct {
  const StaffSaleProduct._({
    required this.id,
    required this.billarId,
    required this.barcode,
    required this.name,
    required this.description,
    required this.price,
    required this.stock,
    required this.imagePath,
    required this.isPromo,
    required this.parentId,
    required this.piecesPerUnit,
    required this.category,
    required this.presentation,
    required this.inventoryStock,
    required this.stockRevision,
    required this.components,
    required this.isActive,
  });

  final int id;
  final String billarId;
  final String? barcode;
  final String name;
  final String description;
  final double price;
  final double stock;
  final String? imagePath;
  final bool isPromo;
  final int? parentId;
  final int piecesPerUnit;
  final String category;
  final String presentation;
  final double inventoryStock;
  final int stockRevision;
  final Map<int, int> components;
  final bool isActive;

  Map<int, int> get stockRequirements =>
      parentId != null
          ? {parentId!: piecesPerUnit}
          : isPromo
          ? components
          : {id: 1};

  double availableStock(
    Map<int, StaffSaleProduct> products,
    Map<int, int> cart,
  ) {
    final requirements = stockRequirements;
    if (!isActive || requirements.isEmpty) return 0;
    final reserved = <int, int>{};
    for (final entry in cart.entries) {
      final selected = products[entry.key];
      if (selected == null) {
        throw StateError('El carrito contiene un producto sin catálogo.');
      }
      for (final requirement in selected.stockRequirements.entries) {
        reserved.update(
          requirement.key,
          (value) => value + requirement.value * entry.value,
          ifAbsent: () => requirement.value * entry.value,
        );
      }
    }
    var available = double.infinity;
    for (final entry in requirements.entries) {
      final base = products[entry.key];
      if (base == null ||
          !base.isActive ||
          base.parentId != null ||
          base.isPromo) {
        return 0;
      }
      available = math.min(
        available,
        (base.inventoryStock - (reserved[base.id] ?? 0)) / entry.value,
      );
    }
    return isPromo ? math.max(0, available.floorToDouble()) : available;
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'billar_id': billarId,
    'barcode': barcode,
    'name': name,
    'description': description,
    'price': price,
    'stock': stock,
    'image_path': imagePath,
    'is_promo': isPromo ? 1 : 0,
    'parent_id': parentId,
    'pieces_per_unit': piecesPerUnit,
    'category': category,
    'presentation': presentation,
    'inventory_stock': inventoryStock,
    'stock_revision': stockRevision,
    'components':
        components.entries
            .map((entry) => {'product_id': entry.key, 'quantity': entry.value})
            .toList(),
    'is_active': isActive,
  };

  factory StaffSaleProduct.fromMap(
    Map<String, dynamic> row, {
    required String billarId,
  }) {
    final id = row['id'];
    final name = row['name'];
    final price = row['price'];
    final stock = row['stock'];
    final promo = row['is_promo'];
    final parent = row['parent_id'];
    final pieces = row['pieces_per_unit'];
    final inventoryStock = row['inventory_stock'];
    final revision = row['stock_revision'];
    final componentRows = row['components'];
    if (id is! int ||
        id <= 0 ||
        billarId.trim().isEmpty ||
        row['billar_id'] != billarId ||
        name is! String ||
        name.trim().isEmpty ||
        price is! num ||
        !price.isFinite ||
        price < 0 ||
        stock is! num ||
        !stock.isFinite ||
        promo is! int ||
        (promo != 0 && promo != 1) ||
        (parent != null && (parent is! int || parent <= 0 || parent == id)) ||
        pieces is! int ||
        pieces <= 0 ||
        inventoryStock is! num ||
        !inventoryStock.isFinite ||
        revision is! int ||
        revision < 0 ||
        componentRows is! List ||
        (row.containsKey('is_active') && row['is_active'] is! bool)) {
      throw const FormatException('El producto de venta no es válido.');
    }
    final components = <int, int>{};
    for (final component in componentRows) {
      if (component is! Map ||
          component['product_id'] is! int ||
          (component['product_id'] as int) <= 0 ||
          component['product_id'] == id ||
          component['quantity'] is! int ||
          (component['quantity'] as int) <= 0 ||
          components.containsKey(component['product_id'])) {
        throw const FormatException('Los componentes de venta no son válidos.');
      }
      components[component['product_id'] as int] = component['quantity'] as int;
    }
    if (promo == 0 && components.isNotEmpty) {
      throw const FormatException('El producto no es una promoción.');
    }
    for (final key in [
      'barcode',
      'description',
      'image_path',
      'category',
      'presentation',
    ]) {
      if (row[key] != null && row[key] is! String) {
        throw const FormatException('El producto de venta no es válido.');
      }
    }
    return StaffSaleProduct._(
      id: id,
      billarId: billarId,
      barcode: row['barcode'] as String?,
      name: name,
      description: row['description'] as String? ?? '',
      price: price.toDouble(),
      stock: stock.toDouble(),
      imagePath: row['image_path'] as String?,
      isPromo: promo == 1,
      parentId: parent as int?,
      piecesPerUnit: pieces,
      category: row['category'] as String? ?? '',
      presentation: row['presentation'] as String? ?? '',
      inventoryStock: inventoryStock.toDouble(),
      stockRevision: revision,
      components: Map.unmodifiable(components),
      isActive: row['is_active'] as bool? ?? true,
    );
  }
}
