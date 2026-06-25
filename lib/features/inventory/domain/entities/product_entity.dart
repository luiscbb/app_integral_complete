class ProductEntity {
  final int? id;
  final String? barcode;
  final String name;
  final String description;
  final double price;
  final double cost;
  final double stock;
  final String? imagePath;
  final int isPromo;
  final int? parentId;
  final int piecesPerUnit;
  final String category;

  const ProductEntity({
    this.id,
    this.barcode,
    required this.name,
    this.description = '',
    required this.price,
    this.cost = 0.0,
    required this.stock,
    this.imagePath,
    this.isPromo = 0,
    this.parentId,
    this.piecesPerUnit = 1,
    this.category = '',
  });

  ProductEntity copyWith({
    int? id,
    String? barcode,
    String? name,
    String? description,
    double? price,
    double? cost,
    double? stock,
    String? imagePath,
    int? isPromo,
    int? parentId,
    int? piecesPerUnit,
    String? category,
  }) {
    return ProductEntity(
      id: id ?? this.id,
      barcode: barcode ?? this.barcode,
      name: name ?? this.name,
      description: description ?? this.description,
      price: price ?? this.price,
      cost: cost ?? this.cost,
      stock: stock ?? this.stock,
      imagePath: imagePath ?? this.imagePath,
      isPromo: isPromo ?? this.isPromo,
      parentId: parentId ?? this.parentId,
      piecesPerUnit: piecesPerUnit ?? this.piecesPerUnit,
      category: category ?? this.category,
    );
  }

  factory ProductEntity.fromMap(Map<String, dynamic> m) {
    return ProductEntity(
      id: m['id'] as int?,
      barcode: m['barcode']?.toString(),
      name: m['name'] ?? 'Sin nombre',
      description: m['description'] ?? '',
      price: (m['price'] as num?)?.toDouble() ?? 0.0,
      cost: (m['cost'] as num?)?.toDouble() ?? 0.0,
      stock: (m['stock'] as num?)?.toDouble() ?? 0.0,
      imagePath: m['image_path']?.toString(),
      isPromo: (m['is_promo'] as int?) ?? 0,
      parentId: m['parent_id'] as int?,
      piecesPerUnit: (m['pieces_per_unit'] as int?) ?? 1,
      category: m['category']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'barcode': barcode,
      'name': name,
      'description': description,
      'price': price,
      'cost': cost,
      'stock': stock,
      'image_path': imagePath,
      'is_promo': isPromo,
      'parent_id': parentId,
      'pieces_per_unit': piecesPerUnit,
      'category': category,
    };
  }

  @override
  bool operator ==(Object other) => other is ProductEntity && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
