import 'dart:convert';
import 'dart:math';

import '../../../../core/utils/uuid_v4.dart';
import 'provider_entity.dart';

class StaffProviderDraft {
  factory StaffProviderDraft.save({
    required ProviderEntity provider,
    required List<int> productIds,
  }) => StaffProviderDraft.restore(
    newUuidV4(),
    jsonEncode({
      'p_provider_id':
          provider.id ??
          DateTime.now().millisecondsSinceEpoch * 1000000 +
              _random.nextInt(1000000),
      'p_operation': provider.id == null ? 'create' : 'update',
      'p_provider': provider.toMap(),
      'p_product_ids': productIds,
    }),
  );

  factory StaffProviderDraft.archive(int providerId) =>
      StaffProviderDraft.restore(
        newUuidV4(),
        jsonEncode({
          'p_provider_id': providerId,
          'p_operation': 'archive',
          'p_provider': <String, Object?>{},
          'p_product_ids': <int>[],
        }),
      );

  const StaffProviderDraft._(this.requestId, this.encodedPayload);

  static final _random = Random.secure();
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static const _textFields = [
    'name',
    'phone',
    'email',
    'address',
    'contact_name',
    'notes',
    'category',
    'visit_days',
  ];

  final String requestId;
  final String encodedPayload;

  Map<String, dynamic> get parameters => _object(jsonDecode(encodedPayload));
  int get providerId => parameters['p_provider_id'] as int;
  String get operation => parameters['p_operation'] as String;

  factory StaffProviderDraft.restore(String requestId, String encoded) {
    final map = _object(jsonDecode(encoded));
    final id = map['p_provider_id'];
    final operation = map['p_operation'];
    final products = map['p_product_ids'];
    final provider = _object(map['p_provider']);
    if (!_uuid.hasMatch(requestId) ||
        map.length != 4 ||
        id is! int ||
        id <= 0 ||
        !['create', 'update', 'archive'].contains(operation) ||
        products is! List ||
        products.any((id) => id is! int || id <= 0) ||
        products.toSet().length != products.length) {
      throw const FormatException('La solicitud de proveedor no es válida.');
    }
    if (operation == 'archive') {
      if (provider.isNotEmpty || products.isNotEmpty) {
        throw const FormatException('El archivado no admite otros cambios.');
      }
    } else {
      if (provider.length != 10 ||
          _textFields.any((field) => provider[field] is! String) ||
          (provider['name'] as String).trim().isEmpty ||
          !provider.containsKey('credit_days') ||
          !provider.containsKey('preferred_payment_method')) {
        throw const FormatException('Los datos del proveedor no son válidos.');
      }
      ProviderEntity.fromMap(provider);
    }
    return StaffProviderDraft._(requestId, encoded);
  }
}

class StaffProviderReceipt {
  const StaffProviderReceipt._(this.providerId, this.operation, this.encoded);

  final int providerId;
  final String operation;
  final String encoded;

  factory StaffProviderReceipt.validate(
    Object? response, {
    required StaffProviderDraft draft,
    required String actorId,
    required String billarId,
  }) {
    Never invalid() =>
        throw const FormatException(
          'El comprobante de proveedor no es válido.',
        );
    final receipt = _object(response);
    final provider = _object(receipt['provider']);
    final products = receipt['product_ids'];
    if (receipt['request_id'] != draft.requestId ||
        receipt['actor_id'] != actorId ||
        receipt['billar_id'] != billarId ||
        receipt['provider_id'] is! int ||
        receipt['provider_id'] != draft.providerId ||
        receipt['operation'] != draft.operation ||
        provider['id'] is! int ||
        provider['id'] != draft.providerId ||
        provider['billar_id'] != billarId ||
        provider['is_active'] != (draft.operation != 'archive') ||
        products is! List ||
        products.any((id) => id is! int || id <= 0) ||
        products.toSet().length != products.length) {
      invalid();
    }
    if (draft.operation != 'archive') {
      ProviderEntity.fromMap(provider);
      final expected = _object(draft.parameters['p_provider']);
      if (expected.keys.any(
        (key) => !provider.containsKey(key) || provider[key] != expected[key],
      )) {
        invalid();
      }
      final requested = draft.parameters['p_product_ids'] as List;
      if (products.length != requested.length ||
          !products.toSet().containsAll(requested)) {
        invalid();
      }
    }
    return StaffProviderReceipt._(
      draft.providerId,
      draft.operation,
      jsonEncode(receipt),
    );
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('La información de proveedor no es válida.');
  }
  return value;
}
