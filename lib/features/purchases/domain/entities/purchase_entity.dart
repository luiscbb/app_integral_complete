class PurchaseItemEntity {
  final int productId;
  final String productName;
  final double quantity;
  final double costPerUnit;

  const PurchaseItemEntity({
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.costPerUnit,
  });

  double get subtotal => quantity * costPerUnit;
}

class PurchaseEntity {
  final int? providerId;
  final String reference;
  final List<PurchaseItemEntity> items;

  const PurchaseEntity({this.providerId, this.reference = '', required this.items});

  double get total => items.fold(0, (acc, e) => acc + e.subtotal);
}
