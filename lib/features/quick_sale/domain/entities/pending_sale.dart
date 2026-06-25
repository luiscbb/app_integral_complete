class PendingSale {
  final int? id;
  final String product;
  final int quantity;
  final double price;
  final DateTime createdAt;
  final bool synced;

  PendingSale({
    this.id,
    required this.product,
    required this.quantity,
    required this.price,
    required this.createdAt,
    required this.synced,
  });

  double get total => quantity * price;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'product': product,
      'quantity': quantity,
      'price': price,
      'created_at': createdAt.toIso8601String(),
      'synced': synced ? 1 : 0,
    };
  }

  factory PendingSale.fromMap(Map<String, Object?> map) {
    return PendingSale(
      id: map['id'] as int?,
      product: map['product'] as String,
      quantity: map['quantity'] as int,
      price: map['price'] as double,
      createdAt: DateTime.parse(map['created_at'] as String),
      synced: (map['synced'] as int) == 1,
    );
  }
}
