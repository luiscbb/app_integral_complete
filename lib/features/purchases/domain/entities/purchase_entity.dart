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
  final String cashSource;

  const PurchaseEntity({
    this.providerId,
    this.reference = '',
    required this.items,
    this.cashSource = 'caja',
  });

  double get total => items.fold(0, (acc, e) => acc + e.subtotal);
}

/// Origen del dinero de una compra, para el corte de efectivo por turno.
class CashSource {
  static const caja = 'caja';
  static const cajero = 'cajero';
  static const transferencia = 'transferencia';
  static const tarjeta = 'tarjeta';

  static const values = [caja, cajero, transferencia, tarjeta];

  static String label(String value) {
    switch (value) {
      case cajero:
        return 'Cajero (directo)';
      case transferencia:
        return 'Transferencia';
      case tarjeta:
        return 'Tarjeta';
      case caja:
      default:
        return 'Caja';
    }
  }

  /// Nombre de icono Material sugerido para representar el origen visualmente.
  /// Se resuelve a `IconData` en la capa de UI (evita importar Flutter aquí).
  static String iconName(String value) {
    switch (value) {
      case cajero:
        return 'person';
      case transferencia:
        return 'swap_horiz';
      case tarjeta:
        return 'credit_card';
      case caja:
      default:
        return 'point_of_sale';
    }
  }
}