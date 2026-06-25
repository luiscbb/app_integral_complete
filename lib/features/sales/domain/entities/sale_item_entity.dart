class SaleItemEntity {
  final int? productId;
  final String productName;
  final double price;

  /// Cantidad. Es `double` para soportar unidades fraccionarias como las
  /// horas de mesa (ej. 0.83 h). Para productos normales será un entero (1, 2…).
  double quantity;

  SaleItemEntity({
    this.productId,
    required this.productName,
    required this.price,
    this.quantity = 1,
  });

  double get subtotal => price * quantity;

  /// Etiqueta amigable de la cantidad: muestra "2" en vez de "2.0",
  /// pero conserva los decimales cuando son relevantes (ej. "0.83").
  String get qtyLabel =>
      quantity % 1 == 0 ? quantity.toInt().toString() : quantity.toStringAsFixed(2);
}
