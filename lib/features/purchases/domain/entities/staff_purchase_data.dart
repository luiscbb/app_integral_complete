import 'provider_entity.dart';
import 'purchase_entity.dart';
import 'purchase_payment_terms.dart';

class StaffPurchaseProduct {
  const StaffPurchaseProduct({
    required this.id,
    required this.name,
    required this.cost,
    required this.parentId,
    required this.piecesPerUnit,
  });

  final int id;
  final String name;
  final double? cost;
  final int? parentId;
  final int piecesPerUnit;

  factory StaffPurchaseProduct.fromMap(
    Map<String, dynamic> row, {
    required String billarId,
  }) {
    final id = row['id'];
    final name = row['name'];
    final cost = row['cost'];
    final parent = row['parent_id'];
    final pieces = row['pieces_per_unit'];
    if (row['billar_id'] != billarId ||
        row['is_active'] != true ||
        row['is_promo'] != 0 ||
        id is! int ||
        id <= 0 ||
        name is! String ||
        name.trim().isEmpty ||
        cost != null &&
            (cost is! num || !cost.toDouble().isFinite || cost < 0) ||
        parent != null && (parent is! int || parent <= 0 || parent == id) ||
        pieces is! int ||
        pieces <= 0 ||
        pieces > 2147483647) {
      throw const FormatException('El catálogo de compras no es válido.');
    }
    return StaffPurchaseProduct(
      id: id,
      name: name,
      cost: (cost as num?)?.toDouble(),
      parentId: parent as int?,
      piecesPerUnit: pieces,
    );
  }
}

class StaffPurchaseSummary {
  const StaffPurchaseSummary({
    required this.id,
    required this.providerId,
    required this.reference,
    required this.date,
    required this.total,
    required this.cancelled,
    required this.payment,
    required this.cashSource,
  });

  final int id;
  final int? providerId;
  final String reference;
  final DateTime date;
  final double total;
  final bool cancelled;
  final PurchasePaymentTerms? payment;
  final String? cashSource;

  factory StaffPurchaseSummary.fromMap(
    Map<String, dynamic> row, {
    required String billarId,
  }) {
    final id = row['id'];
    final provider = row['provider_id'];
    final reference = row['reference'];
    final rawDate = row['date'];
    final date = rawDate is String ? DateTime.tryParse(rawDate) : null;
    final total = row['total'];
    final cancelled = row['cancelled'];
    final source = row['cash_source'];
    if (row['billar_id'] != billarId ||
        id is! int ||
        id <= 0 ||
        provider != null && (provider is! int || provider <= 0) ||
        reference != null && reference is! String ||
        date == null ||
        total is! num ||
        !total.toDouble().isFinite ||
        total < 0 ||
        cancelled is! bool ||
        source != null && !CashSource.values.contains(source)) {
      throw const FormatException('El historial de compras no es válido.');
    }
    PurchasePaymentTerms? payment;
    final condition = row['payment_condition'];
    if (condition != null) {
      if (condition != 'credito' && condition != 'contado' ||
          row['credit_days'] != null && row['credit_days'] is! int ||
          condition == 'credito' && provider == null) {
        throw const FormatException(
          'Las condiciones del historial no son válidas.',
        );
      }
      final method = row['payment_method'];
      if (condition == 'contado' && method is! String ||
          condition == 'credito' && method != null) {
        throw const FormatException('El pago del historial no es válido.');
      }
      try {
        payment = PurchasePaymentTerms(
          option: condition == 'credito' ? 'credito' : method as String,
          creditDays: row['credit_days'] as int?,
          cashSource: method == 'efectivo' ? source as String? : null,
        );
        final snapshot = payment.snapshot(
          total: total.toDouble(),
          recordedAt: date,
        );
        if (source != payment.legacyCashSource ||
            snapshot.entries.any(
              (entry) =>
                  !row.containsKey(entry.key) || row[entry.key] != entry.value,
            )) {
          throw const FormatException(
            'El saldo o vencimiento del historial no es válido.',
          );
        }
      } on ArgumentError {
        throw const FormatException(
          'Las condiciones del historial no son válidas.',
        );
      }
    } else if ([
      'payment_method',
      'credit_days',
      'due_date',
      'paid_amount',
      'balance_due',
    ].any((field) => row[field] != null)) {
      throw const FormatException(
        'El historial contiene condiciones incompletas.',
      );
    }
    return StaffPurchaseSummary(
      id: id,
      providerId: provider as int?,
      reference: reference as String? ?? '',
      date: date,
      total: total.toDouble(),
      cancelled: cancelled,
      payment: payment,
      cashSource: source as String?,
    );
  }
}

class StaffPurchaseData {
  StaffPurchaseData({
    required List<StaffPurchaseProduct> products,
    required List<ProviderEntity> providers,
    required List<StaffPurchaseSummary> history,
  }) : products = List.unmodifiable(products),
       providers = List.unmodifiable(providers),
       history = List.unmodifiable(history);

  final List<StaffPurchaseProduct> products;
  final List<ProviderEntity> providers;
  final List<StaffPurchaseSummary> history;
}
