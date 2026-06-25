class ProviderEntity {
  final int? id;
  final String name;
  final String phone;
  final String address;
  final String category;

  const ProviderEntity({this.id, required this.name, this.phone = '', this.address = '', this.category = 'Lunes'});

  factory ProviderEntity.fromMap(Map<String, dynamic> m) => ProviderEntity(
        id: m['id'] as int?,
        name: m['name'] ?? '',
        phone: m['phone'] ?? '',
        address: m['address'] ?? '',
        category: m['category'] ?? 'Lunes',
      );

  Map<String, dynamic> toMap() => {'name': name, 'phone': phone, 'address': address, 'category': category};
}
