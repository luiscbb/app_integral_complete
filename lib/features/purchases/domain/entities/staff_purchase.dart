import 'dart:convert';
import 'dart:math' as math;

import '../../../../core/utils/uuid_v4.dart';
import 'purchase_entity.dart';
import 'purchase_payment_terms.dart';

class StaffPurchaseItem {
  const StaffPurchaseItem({
    required this.productId,
    required this.quantity,
    required this.costPerUnit,
    required this.parentId,
    required this.piecesPerUnit,
  });

  final int productId;
  final double quantity;
  final double costPerUnit;
  final int? parentId;
  final int piecesPerUnit;

  Map<String, Object?> toJson() {
    if (productId <= 0 ||
        !quantity.isFinite ||
        quantity <= 0 ||
        !costPerUnit.isFinite ||
        costPerUnit < 0 ||
        piecesPerUnit <= 0 ||
        piecesPerUnit > 2147483647 ||
        !(quantity * (parentId == null ? 1 : piecesPerUnit)).isFinite ||
        parentId != null && (parentId! <= 0 || parentId == productId)) {
      throw ArgumentError('El detalle de compra no es válido.');
    }
    return {
      'product_id': productId,
      'quantity': quantity,
      'cost_per_unit': costPerUnit,
      'parent_id': parentId,
      'pieces_per_unit': piecesPerUnit,
    };
  }
}

class StaffPurchaseDraft {
  factory StaffPurchaseDraft({
    required int? providerId,
    required String reference,
    required String? cashSource,
    required List<StaffPurchaseItem> items,
    PurchasePaymentTerms? payment,
  }) => StaffPurchaseDraft._validated(
    newUuidV4(),
    providerId,
    reference,
    cashSource,
    items,
    payment,
  );

  StaffPurchaseDraft._validated(
    this.requestId,
    this.providerId,
    this.reference,
    this.cashSource,
    List<StaffPurchaseItem> items,
    this.payment,
  ) : items = List.unmodifiable(items) {
    if (!_uuid.hasMatch(requestId) ||
        providerId != null && providerId! <= 0 ||
        (payment == null
            ? !CashSource.values.contains(cashSource)
            : cashSource != payment!.legacyCashSource ||
                payment!.isCredit && providerId == null) ||
        items.isEmpty ||
        items.map((item) => item.productId).toSet().length != items.length) {
      throw ArgumentError('Los datos de compra no son válidos.');
    }
    for (final item in items) {
      item.toJson();
    }
    if (!total.isFinite) {
      throw ArgumentError('El total de compra no es válido.');
    }
  }

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  final String requestId;
  final int? providerId;
  final String reference;
  final String? cashSource;
  final PurchasePaymentTerms? payment;
  final List<StaffPurchaseItem> items;

  double get total =>
      items.fold(0, (total, item) => total + item.quantity * item.costPerUnit);

  Map<String, Object?> get parameters => {
    'p_provider_id': providerId,
    'p_reference': reference,
    'p_cash_source': cashSource,
    'p_items': items.map((item) => item.toJson()).toList(),
    if (payment != null) 'p_payment': payment!.toJson(),
  };
  String get encodedPayload => jsonEncode(parameters);

  factory StaffPurchaseDraft.restore(String requestId, String encoded) {
    final map = _object(jsonDecode(encoded));
    final provider = map['p_provider_id'];
    final rows = map['p_items'];
    if ((map.length != 4 && map.length != 5) ||
        !map.keys.toSet().containsAll([
          'p_provider_id',
          'p_reference',
          'p_cash_source',
          'p_items',
        ]) ||
        (map.length == 5 && !map.containsKey('p_payment')) ||
        provider != null && provider is! int ||
        rows is! List) {
      throw const FormatException(
        'La solicitud de compra guardada no es válida.',
      );
    }
    final items = <StaffPurchaseItem>[];
    for (final value in rows) {
      final row = _object(value);
      final parent = row['parent_id'];
      if (row.length != 5 ||
          !row.containsKey('parent_id') ||
          parent != null && parent is! int) {
        throw const FormatException(
          'El detalle de compra guardado no es válido.',
        );
      }
      items.add(
        StaffPurchaseItem(
          productId: _integer(row['product_id']),
          quantity: _number(row['quantity']),
          costPerUnit: _number(row['cost_per_unit']),
          parentId: parent as int?,
          piecesPerUnit: _integer(row['pieces_per_unit']),
        ),
      );
    }
    return StaffPurchaseDraft._validated(
      requestId,
      provider as int?,
      _text(map['p_reference']),
      map['p_cash_source'] == null ? null : _text(map['p_cash_source']),
      items,
      map.containsKey('p_payment')
          ? PurchasePaymentTerms.fromJson(map['p_payment'])
          : null,
    );
  }
}

class StaffPurchaseReceipt {
  const StaffPurchaseReceipt._(this.purchaseId, this.total, this.encoded);

  final int purchaseId;
  final double total;
  final String encoded;
  Map<String, dynamic> get json => _object(jsonDecode(encoded));

  factory StaffPurchaseReceipt.validate(
    Object? response, {
    required StaffPurchaseDraft draft,
    required String actorId,
    required String billarId,
  }) {
    Never invalid() =>
        throw const FormatException('El comprobante de compra no es válido.');
    final receipt = _object(response);
    final purchase = _object(receipt['purchase']);
    final id = _integer(purchase['id']);
    final total = _number(purchase['total']);
    final date = purchase['date'];
    final creator = purchase['created_by'];
    final items = receipt['items'];
    if (receipt['request_id'] != draft.requestId ||
        receipt['billar_id'] != billarId ||
        receipt['actor_id'] != actorId ||
        id <= 0 ||
        purchase['billar_id'] != billarId ||
        !purchase.containsKey('provider_id') ||
        (draft.providerId != null &&
            _integer(purchase['provider_id']) != draft.providerId) ||
        purchase['provider_id'] != draft.providerId ||
        purchase['reference'] != draft.reference ||
        purchase['cash_source'] != draft.cashSource ||
        purchase['cancelled'] != false ||
        creator is! String ||
        creator.trim().isEmpty ||
        date is! String ||
        DateTime.tryParse(date) == null ||
        total < 0 ||
        !_close(total, draft.total) ||
        items is! List ||
        items.length != draft.items.length) {
      invalid();
    }
    final payment = draft.payment;
    if (payment == null) {
      if ([
        'payment_condition',
        'payment_method',
        'credit_days',
        'due_date',
        'paid_amount',
        'balance_due',
      ].any((field) => purchase[field] != null)) {
        invalid();
      }
    } else {
      if (purchase['payment_condition'] != payment.condition ||
          !purchase.containsKey('payment_method') ||
          purchase['payment_method'] != payment.paymentMethod ||
          !purchase.containsKey('credit_days') ||
          purchase['credit_days'] != payment.creditDays ||
          _number(purchase['paid_amount']) != (payment.isCredit ? 0 : total) ||
          _number(purchase['balance_due']) != (payment.isCredit ? total : 0)) {
        invalid();
      }
      final due = purchase['due_date'];
      if (payment.isCredit) {
        final parsed =
            due is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(due)
                ? DateTime.tryParse('${due}T00:00:00Z')
                : null;
        final recorded = DateTime.parse(date).toUtc();
        final start = DateTime.utc(recorded.year, recorded.month, recorded.day);
        if (parsed == null ||
            parsed.toUtc().difference(start).inDays != payment.creditDays ||
            due != parsed.toIso8601String().substring(0, 10)) {
          invalid();
        }
      } else if (!purchase.containsKey('due_date') || due != null) {
        invalid();
      }
    }
    final before = _stocks(receipt['stock_before'], allowUnknownCost: true);
    final after = _stocks(receipt['stock_after'], allowUnknownCost: false);
    if (before.isEmpty ||
        before.length != after.length ||
        before.keys.any(
          (id) =>
              !after.containsKey(id) ||
              _integer(after[id]!['stock_revision']) <=
                  _integer(before[id]!['stock_revision']),
        )) {
      invalid();
    }
    final additions = <int, double>{};
    final costs = <int, double>{};
    final revisions = <int, int>{};
    for (var index = 0; index < draft.items.length; index++) {
      final requested = draft.items[index];
      final item = _object(items[index]);
      final target = requested.parentId ?? requested.productId;
      final factor = requested.parentId == null ? 1 : requested.piecesPerUnit;
      final quantity = requested.quantity * factor;
      final cost = requested.costPerUnit / factor;
      final name = item['product_name'];
      if (_integer(item['product_id']) != requested.productId ||
          !item.containsKey('parent_id') ||
          item['parent_id'] != requested.parentId ||
          (requested.parentId != null &&
              _integer(item['parent_id']) != requested.parentId) ||
          _integer(item['pieces_per_unit']) != requested.piecesPerUnit ||
          _number(item['quantity']) != requested.quantity ||
          _number(item['cost_per_unit']) != requested.costPerUnit ||
          _integer(item['stock_product_id']) != target ||
          !_close(_number(item['stock_quantity']), quantity) ||
          !_close(_number(item['cost_per_piece']), cost) ||
          name is! String ||
          name.trim().isEmpty ||
          !after.containsKey(requested.productId) ||
          !after.containsKey(target)) {
        invalid();
      }
      additions[target] = (additions[target] ?? 0) + quantity;
      costs[target] = cost;
      revisions[target] = (revisions[target] ?? 0) + 1;
    }
    for (final target in additions.keys) {
      if (!_close(
            _number(after[target]!['stock']),
            _number(before[target]!['stock']) + additions[target]!,
          ) ||
          !_close(_number(after[target]!['cost']), costs[target]!) ||
          _integer(after[target]!['stock_revision']) !=
              _integer(before[target]!['stock_revision']) +
                  revisions[target]!) {
        invalid();
      }
    }
    return StaffPurchaseReceipt._(id, total, jsonEncode(receipt));
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Los datos de compra no son válidos.');
  }
  return value;
}

int _integer(Object? value) {
  if (value is! int) {
    throw const FormatException('Un identificador de compra no es válido.');
  }
  return value;
}

double _number(Object? value) {
  if (value is! num || !value.toDouble().isFinite) {
    throw const FormatException(
      'Un importe o cantidad de compra no es válido.',
    );
  }
  return value.toDouble();
}

String _text(Object? value) {
  if (value is! String) {
    throw const FormatException('Un texto de compra no es válido.');
  }
  return value;
}

bool _close(double a, double b) =>
    a.isFinite &&
    b.isFinite &&
    (a - b).abs() <=
        math.max(0.000001, math.max(a.abs(), b.abs()) * 0.0000000001);

Map<int, Map<String, dynamic>> _stocks(
  Object? value, {
  required bool allowUnknownCost,
}) {
  if (value is! List) {
    throw const FormatException(
      'Las existencias del comprobante no son válidas.',
    );
  }
  final result = <int, Map<String, dynamic>>{};
  for (final raw in value) {
    final row = _object(raw);
    final id = _integer(row['product_id']);
    _number(row['stock']);
    final cost = row['cost'];
    final parsedCost = cost == null && allowUnknownCost ? null : _number(cost);
    if (id <= 0 ||
        result.containsKey(id) ||
        !row.containsKey('cost') ||
        _integer(row['stock_revision']) < 0 ||
        !allowUnknownCost && parsedCost != null && parsedCost < 0) {
      throw const FormatException(
        'Las existencias del comprobante no son válidas.',
      );
    }
    result[id] = row;
  }
  return result;
}
