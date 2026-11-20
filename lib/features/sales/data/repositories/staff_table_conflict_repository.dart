import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';

class StaffTableConflict {
  const StaffTableConflict({
    required this.ordinal,
    required this.serviceId,
    required this.actorId,
    required this.tableId,
    required this.openedAt,
    required this.reason,
  });

  final int ordinal;
  final String serviceId;
  final String actorId;
  final int tableId;
  final DateTime openedAt;
  final String reason;
}

class StaffTableConsumptionSnapshot {
  const StaffTableConsumptionSnapshot({
    required this.ordinal,
    required this.requestId,
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.price,
    required this.recordedAt,
  });

  final int ordinal;
  final String requestId;
  final int productId;
  final String productName;
  final double quantity;
  final double price;
  final DateTime recordedAt;

  factory StaffTableConsumptionSnapshot.fromMap(Map<dynamic, dynamic> row) {
    final ordinal = row['ordinal'];
    final requestId = row['request_id'];
    final productId = row['product_id'];
    final name = row['product_name'];
    final quantity = row['quantity'];
    final price = row['price'];
    final recorded = row['recorded_at'];
    if (ordinal is! int ||
        ordinal <= 0 ||
        requestId is! String ||
        requestId.isEmpty ||
        productId is! int ||
        productId <= 0 ||
        name is! String ||
        name.trim().isEmpty ||
        name.runes.length > 255 ||
        quantity is! num ||
        !quantity.isFinite ||
        quantity <= 0 ||
        price is! num ||
        !price.isFinite ||
        price < 0 ||
        recorded is! String ||
        DateTime.tryParse(recorded) == null) {
      throw const FormatException('El consumo recibido no es válido.');
    }
    return StaffTableConsumptionSnapshot(
      ordinal: ordinal,
      requestId: requestId,
      productId: productId,
      productName: name,
      quantity: quantity.toDouble(),
      price: price.toDouble(),
      recordedAt: DateTime.parse(recorded),
    );
  }
}

typedef StaffTableConflictConsumption = StaffTableConsumptionSnapshot;

class StaffTableConflictPage<T> {
  const StaffTableConflictPage(this.items, this.hasMore);
  final List<T> items;
  final bool hasMore;
}

class StaffTableConflictReviewReceipt {
  const StaffTableConflictReviewReceipt({
    required this.reviewedAt,
    required this.reviewedBy,
  });

  final DateTime reviewedAt;
  final String reviewedBy;
}

class StaffTableConflictRepository {
  const StaffTableConflictRepository(this.client, this.requireSession);

  final SupabaseClient client;
  final void Function(SyncSession) requireSession;

  Future<StaffTableConflictReviewReceipt> reviewOpening({
    required SyncSession session,
    required String tableType,
    required String serviceId,
  }) async {
    if ((tableType != 'Billar' && tableType != 'Comanda') ||
        serviceId.trim().isEmpty) {
      throw ArgumentError('La revisión del conflicto no es válida.');
    }
    requireSession(session);
    final response = await client
        .rpc(
          'staff_table_review_opening_conflict',
          params: {
            'requested_billar_id': session.billarId,
            'requested_table_type': tableType,
            'requested_service_id': serviceId,
          },
        )
        .setHeader('Authorization', 'Bearer ${session.token}');
    requireSession(session);
    if (response is! Map ||
        response['service_id'] != serviceId ||
        response['billar_id'] != session.billarId ||
        response['table_type'] != tableType ||
        response['state'] != 'conflict' ||
        response['reviewed_by'] is! String ||
        (response['reviewed_by'] as String).isEmpty ||
        response['reviewed_at'] is! String ||
        DateTime.tryParse(response['reviewed_at'] as String) == null) {
      throw const FormatException('La confirmación de revisión no es válida.');
    }
    return StaffTableConflictReviewReceipt(
      reviewedAt: DateTime.parse(response['reviewed_at'] as String),
      reviewedBy: response['reviewed_by'] as String,
    );
  }

  Future<StaffTableConflictPage<T>> _page<T>({
    required SyncSession session,
    required String tableType,
    required String function,
    required String idField,
    required T Function(Map<dynamic, dynamic>) read,
    String? serviceId,
    int? beforeOrdinal,
  }) async {
    if ((tableType != 'Billar' && tableType != 'Comanda') ||
        (beforeOrdinal != null && beforeOrdinal <= 0) ||
        (serviceId != null && serviceId.isEmpty)) {
      throw ArgumentError('La consulta de conflictos no es válida.');
    }
    requireSession(session);
    final response = await client
        .rpc(
          function,
          params: {
            'requested_billar_id': session.billarId,
            'requested_table_type': tableType,
            if (serviceId != null) 'requested_service_id': serviceId,
            'before_ordinal': beforeOrdinal,
          },
        )
        .setHeader('Authorization', 'Bearer ${session.token}');
    requireSession(session);
    if (response is! Map ||
        response['billar_id'] != session.billarId ||
        response['table_type'] != tableType ||
        (serviceId != null && response['service_id'] != serviceId) ||
        response['items'] is! List ||
        response['has_more'] is! bool) {
      throw const FormatException('La respuesta de conflictos no es válida.');
    }
    final rows = response['items'] as List;
    final hasMore = response['has_more'] as bool;
    if (rows.length > 50 || (hasMore && rows.length != 50)) {
      throw const FormatException('La página de conflictos no es válida.');
    }
    final items = <T>[];
    final identifiers = <String>{};
    var upperBound = beforeOrdinal;
    for (final row in rows) {
      if (row is! Map ||
          row['ordinal'] is! int ||
          (row['ordinal'] as int) <= 0 ||
          row[idField] is! String ||
          (row[idField] as String).isEmpty ||
          !identifiers.add(row[idField] as String) ||
          (upperBound != null && (row['ordinal'] as int) >= upperBound)) {
        throw const FormatException('La página de conflictos no es válida.');
      }
      upperBound = row['ordinal'] as int;
      items.add(read(row));
    }
    return StaffTableConflictPage(List.unmodifiable(items), hasMore);
  }

  Future<StaffTableConflictPage<StaffTableConflict>> list({
    required SyncSession session,
    required String tableType,
    int? beforeOrdinal,
  }) => _page(
    session: session,
    tableType: tableType,
    function: 'staff_table_conflicts',
    idField: 'service_id',
    beforeOrdinal: beforeOrdinal,
    read: (row) {
      final serviceId = row['service_id'];
      final actorId = row['actor_id'];
      final tableId = row['table_id'];
      final opened = row['opened_at'];
      final reason = row['reason'];
      if (row['billar_id'] != session.billarId ||
          row['table_type'] != tableType ||
          serviceId is! String ||
          serviceId.isEmpty ||
          actorId is! String ||
          actorId.isEmpty ||
          tableId is! int ||
          tableId <= 0 ||
          opened is! String ||
          DateTime.tryParse(opened) == null ||
          (reason != 'opening' && reason != 'late_consumption')) {
        throw const FormatException('El conflicto no es válido.');
      }
      return StaffTableConflict(
        ordinal: row['ordinal'] as int,
        serviceId: serviceId,
        actorId: actorId,
        tableId: tableId,
        openedAt: DateTime.parse(opened),
        reason: reason as String,
      );
    },
  );

  Future<StaffTableConflictPage<StaffTableConflictConsumption>> consumptions({
    required SyncSession session,
    required String tableType,
    required String serviceId,
    int? beforeOrdinal,
  }) => _page(
    session: session,
    tableType: tableType,
    function: 'staff_table_conflict_consumptions',
    idField: 'request_id',
    serviceId: serviceId,
    beforeOrdinal: beforeOrdinal,
    read: StaffTableConsumptionSnapshot.fromMap,
  );
}
