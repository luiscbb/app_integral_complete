import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import 'staff_table_conflict_repository.dart';

class StaffTableLateAdjustmentSnapshot {
  const StaffTableLateAdjustmentSnapshot({
    required this.serviceId,
    required this.tableId,
    required this.tableType,
    required this.revision,
    required this.total,
    required this.items,
  });

  final String serviceId;
  final int tableId;
  final String tableType;
  final int revision;
  final double total;
  final List<StaffTableConsumptionSnapshot> items;
}

class StaffTableLateAdjustmentSnapshotRepository {
  const StaffTableLateAdjustmentSnapshotRepository(
    this.client,
    this.requireSession,
  );

  final SupabaseClient client;
  final void Function(SyncSession) requireSession;

  Future<StaffTableLateAdjustmentSnapshot> read({
    required SyncSession session,
    required String tableType,
    required String serviceId,
  }) async {
    if ((tableType != 'Billar' && tableType != 'Comanda') ||
        serviceId.trim().isEmpty) {
      throw ArgumentError('La consulta del ajuste tardío no es válida.');
    }

    final items = <StaffTableConsumptionSnapshot>[];
    final requestIds = <String>{};
    int? revision;
    int? itemCount;
    int? tableId;
    int? before;
    double? total;
    while (true) {
      requireSession(session);
      final response = await client
          .rpc(
            'staff_table_late_adjustment_snapshot',
            params: {
              'requested_billar_id': session.billarId,
              'requested_table_type': tableType,
              'requested_service_id': serviceId,
              'before_ordinal': before,
            },
          )
          .setHeader('Authorization', 'Bearer ${session.token}');
      requireSession(session);
      if (response is! Map ||
          response['billar_id'] != session.billarId ||
          response['table_type'] != tableType ||
          response['service_id'] != serviceId ||
          response['table_id'] is! int ||
          (response['table_id'] as int) <= 0 ||
          response['revision'] is! int ||
          (response['revision'] as int) <= 0 ||
          response['item_count'] is! int ||
          (response['item_count'] as int) <= 0 ||
          response['total'] is! num ||
          !(response['total'] as num).isFinite ||
          (response['total'] as num) <= 0 ||
          response['items'] is! List ||
          response['has_more'] is! bool) {
        throw const FormatException(
          'La respuesta del ajuste tardío no es válida.',
        );
      }

      final pageRevision = response['revision'] as int;
      final pageCount = response['item_count'] as int;
      final pageTableId = response['table_id'] as int;
      final pageTotal = (response['total'] as num).toDouble();
      if ((revision != null && revision != pageRevision) ||
          (itemCount != null && itemCount != pageCount) ||
          (tableId != null && tableId != pageTableId) ||
          (total != null && total != pageTotal)) {
        throw const FormatException(
          'El servicio cambió durante la consulta del ajuste.',
        );
      }
      revision = pageRevision;
      itemCount = pageCount;
      tableId = pageTableId;
      total = pageTotal;

      final rows = response['items'] as List;
      final hasMore = response['has_more'] as bool;
      if (rows.length > 50 || (hasMore && rows.length != 50)) {
        throw const FormatException(
          'La página del ajuste tardío no es válida.',
        );
      }
      for (final row in rows) {
        if (row is! Map) {
          throw const FormatException('El consumo recibido no es válido.');
        }
        final item = StaffTableConsumptionSnapshot.fromMap(row);
        if ((before == null && items.isEmpty && item.ordinal != revision) ||
            (before != null && item.ordinal >= before) ||
            !requestIds.add(item.requestId)) {
          throw const FormatException(
            'La página del ajuste tardío no es válida.',
          );
        }
        before = item.ordinal;
        items.add(item);
      }
      if (items.length > itemCount || (hasMore && items.length >= itemCount)) {
        throw const FormatException(
          'Los consumos tardíos recibidos no están completos.',
        );
      }
      if (!hasMore) {
        if (items.length != itemCount) {
          throw const FormatException(
            'Los consumos tardíos recibidos no están completos.',
          );
        }
        final calculated = items.fold<double>(
          0,
          (sum, item) => sum + item.quantity * item.price,
        );
        if (!calculated.isFinite ||
            (calculated - total).abs() >
                math.max(0.000001, calculated.abs() * 0.0000000001)) {
          throw const FormatException(
            'El total del ajuste no coincide con los consumos.',
          );
        }
        return StaffTableLateAdjustmentSnapshot(
          serviceId: serviceId,
          tableId: tableId,
          tableType: tableType,
          revision: revision,
          total: total,
          items: List.unmodifiable(items),
        );
      }
    }
  }
}
