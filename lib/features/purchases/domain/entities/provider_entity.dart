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
  });

  factory ProviderEntity.fromMap(Map<String, dynamic> m) => ProviderEntity(
        id: m['id'] as int?,
        name: m['name'] ?? '',
        phone: m['phone'] ?? '',
        email: m['email'] ?? '',
        address: m['address'] ?? '',
        contactName: m['contact_name'] ?? '',
        notes: m['notes'] ?? '',
        category: m['category'] ?? 'General',
        visitDays: _parseVisitDays(m['visit_days']),
      );

  Map<String, dynamic> toMap() => {
    'name': name,
    'phone': phone,
    'email': email,
    'address': address,
    'contact_name': contactName,
    'notes': notes,
    'category': category,
    'visit_days': visitDays.join(','),
  };

  static List<String> _parseVisitDays(dynamic value) {
    if (value == null) return [];
    if (value is String) {
      if (value.isEmpty) return [];
      return value.split(',').where((s) => s.trim().isNotEmpty).toList();
    }
    return [];
  }
}
