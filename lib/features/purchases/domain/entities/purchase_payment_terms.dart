import 'purchase_entity.dart';

class PurchasePaymentTerms {
  PurchasePaymentTerms({
    required this.option,
    this.cashSource,
    this.creditDays,
  }) {
    if (!PurchasePaymentOption.values.contains(option) ||
        (option == PurchasePaymentOption.cash
            ? ![CashSource.caja, CashSource.cajero].contains(cashSource)
            : cashSource != null) ||
        (option == PurchasePaymentOption.credit
            ? creditDays == null || creditDays! < 0 || creditDays! > 2147483647
            : creditDays != null)) {
      throw ArgumentError('Las condiciones de la compra no son válidas.');
    }
  }

  final String option;
  final String? cashSource;
  final int? creditDays;

  bool get isCredit => option == PurchasePaymentOption.credit;
  String get condition => isCredit ? 'credito' : 'contado';
  String? get paymentMethod => isCredit ? null : option;
  String? get legacyCashSource =>
      isCredit
          ? null
          : option == PurchasePaymentOption.cash
          ? cashSource
          : option;

  Map<String, Object?> toJson() => {
    'option': option,
    'cash_source': cashSource,
    'credit_days': creditDays,
  };

  Map<String, Object?> snapshot({
    required double total,
    required DateTime recordedAt,
  }) {
    if (!total.isFinite || total < 0) {
      throw ArgumentError('El total de la compra no es válido.');
    }
    String? dueDate;
    if (isCredit) {
      final utc = recordedAt.toUtc();
      final day = DateTime.utc(utc.year, utc.month, utc.day);
      if (utc.year < 1 ||
          utc.year > 9999 ||
          creditDays! > DateTime.utc(9999, 12, 31).difference(day).inDays) {
        throw ArgumentError(
          'El vencimiento excede el rango de fechas admitido.',
        );
      }
      final due = day.add(Duration(days: creditDays!));
      dueDate = due.toIso8601String().substring(0, 10);
    }
    return {
      'payment_condition': condition,
      'payment_method': paymentMethod,
      'credit_days': creditDays,
      'due_date': dueDate,
      'paid_amount': isCredit ? 0.0 : total,
      'balance_due': isCredit ? total : 0.0,
    };
  }

  factory PurchasePaymentTerms.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 3 ||
        !value.keys.toSet().containsAll([
          'option',
          'cash_source',
          'credit_days',
        ]) ||
        value['option'] is! String ||
        value['cash_source'] != null && value['cash_source'] is! String ||
        value['credit_days'] != null && value['credit_days'] is! int) {
      throw const FormatException(
        'Las condiciones de la compra no son válidas.',
      );
    }
    return PurchasePaymentTerms(
      option: value['option'] as String,
      cashSource: value['cash_source'] as String?,
      creditDays: value['credit_days'] as int?,
    );
  }
}
