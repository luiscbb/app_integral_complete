import 'dart:convert';

class StaffOperationRejection implements Exception {
  const StaffOperationRejection._(this.encoded);

  final String encoded;

  static bool isResponse(Object? value) =>
      value is Map<String, dynamic> && value['status'] == 'rejected';

  static Map<String, Object?> requestPayload(
    Map<String, Object?> parameters,
  ) => {
    for (final entry in parameters.entries) entry.key.substring(2): entry.value,
  };

  factory StaffOperationRejection.validate(
    Object? response, {
    required String kind,
    required String requestId,
    required String actorId,
    required String billarId,
    required Map<String, Object?> parameters,
  }) {
    if (response is! Map<String, dynamic> ||
        response.length != 7 ||
        response['status'] != 'rejected' ||
        response['reason_code'] != 'not_applied_closed' ||
        response['kind'] != kind ||
        response['request_id'] != requestId ||
        response['actor_id'] != actorId ||
        response['billar_id'] != billarId ||
        !_sameJson(response['request_payload'], requestPayload(parameters))) {
      throw const FormatException(
        'El cierre de la solicitud no es válido. Conserva el pendiente.',
      );
    }
    return StaffOperationRejection._(jsonEncode(response));
  }

  @override
  String toString() =>
      'Solicitud cerrada: el servidor confirmó que no se aplicó y bloqueó '
      'sus reintentos. Puedes corregir los datos y enviar una nueva.';
}

bool _sameJson(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _sameJson(left[key], right[key]),
        );
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_sameJson(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
