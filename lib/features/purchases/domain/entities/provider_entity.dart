import 'purchase_entity.dart';

class ProviderEntity {
  final int? id;
  final String name;
  final String phone;
  final String email;
  final String address;
  final String contactName;
  final String notes;
  final String category;
  final List<String> visitDays;
  final int? creditDays;
  final String? preferredPaymentMethod;

  const ProviderEntity({
    this.id,
    required this.name,
    this.phone = '',
    this.email = '',
    this.address = '',
    this.contactName = '',
    this.notes = '',
    this.category = 'General',
    this.visitDays = const [],
    this.creditDays,
    this.preferredPaymentMethod,
  });

  factory ProviderEntity.fromMap(Map<String, dynamic> m) {
    final creditDays = m['credit_days'];
    final preferredPaymentMethod = m['preferred_payment_method'];
    if (creditDays != null &&
            (creditDays is! int || creditDays < 0 || creditDays > 2147483647) ||
        preferredPaymentMethod != null &&
            !PurchasePaymentOption.values.contains(preferredPaymentMethod)) {
      throw const FormatException(
        'Las condiciones de pago del proveedor no son válidas.',
      );
    }
    return ProviderEntity(
      id: m['id'] as int?,
      name: m['name'] ?? '',
      phone: m['phone'] ?? '',
      email: m['email'] ?? '',
      address: m['address'] ?? '',
      contactName: m['contact_name'] ?? '',
      notes: m['notes'] ?? '',
      category: m['category'] ?? 'General',
      visitDays: _parseVisitDays(m['visit_days']),
      creditDays: creditDays as int?,
      preferredPaymentMethod: preferredPaymentMethod as String?,
    );
  }

  Map<String, dynamic> toMap() {
    if (creditDays != null && (creditDays! < 0 || creditDays! > 2147483647) ||
        preferredPaymentMethod != null &&
            !PurchasePaymentOption.values.contains(preferredPaymentMethod)) {
      throw ArgumentError(
        'Las condiciones de pago del proveedor no son válidas.',
      );
    }
    return {
      'name': name,
      'phone': phone,
      'email': email,
      'address': address,
      'contact_name': contactName,
      'notes': notes,
      'category': category,
      'visit_days': visitDays.join(','),
      'credit_days': creditDays,
      'preferred_payment_method': preferredPaymentMethod,
    };
  }

  static List<String> _parseVisitDays(dynamic value) {
    if (value == null) return [];
    if (value is String) {
      if (value.isEmpty) return [];
      return value.split(',').where((s) => s.trim().isNotEmpty).toList();
    }
    return [];
  }
}
