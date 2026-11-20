import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import 'staff_table_conflict_repository.dart';

class StaffTableCheckoutSnapshot {
  const StaffTableCheckoutSnapshot({
    required this.serviceId,
    required this.tableId,
    required this.tableType,
    required this.actorId,
    required this.openedAt,
    required this.revision,
    required this.quotedAt,
    required this.timeCost,
    required this.total,
    required this.items,
  });

  final String serviceId;
  final int tableId;
  final String tableType;
  final String actorId;
  final DateTime openedAt;
  final int revision;
  final DateTime quotedAt;
  final double timeCost;
  final double total;
  final List<StaffTableConsumptionSnapshot> items;
}

class StaffTableCheckoutSnapshotRepository {
  const StaffTableCheckoutSnapshotRepository(this.client, this.requireSession);

  final SupabaseClient client;
  final void Function(SyncSession) requireSession;

  Future<StaffTableCheckoutSnapshot> read({
    required SyncSession session,
    required String tableType,
    required String serviceId,
  }) async {
    if ((tableType != 'Billar' && tableType != 'Comanda') ||
        serviceId.trim().isEmpty) {
      throw ArgumentError('La consulta de cobro no es válida.');
    }

    final items = <StaffTableConsumptionSnapshot>[];
    final requestIds = <String>{};
    int? revision;
    int? itemCount;
    int? before;
    int? tableId;
    String? actorId;
    DateTime? openedAt;
    while (true) {
      requireSession(session);
      final response = await client
          .rpc(
            'staff_table_checkout_snapshot',
            params: {
              'requested_billar_id': session.billarId,
              'requested_table_type': tableType,
              'requested_service_id': serviceId,
              'expected_revision': revision,
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
          response['actor_id'] is! String ||
          (response['actor_id'] as String).isEmpty ||
          response['opened_at'] is! String ||
          DateTime.tryParse(response['opened_at'] as String) == null ||
          response['revision'] is! int ||
          (response['revision'] as int) < 0 ||
          response['item_count'] is! int ||
          (response['item_count'] as int) < 0 ||
          response['quoted_at'] is! String ||
          DateTime.tryParse(response['quoted_at'] as String) == null ||
          response['time_cost'] is! num ||
          !(response['time_cost'] as num).isFinite ||
          (response['time_cost'] as num) < 0 ||
          (tableType == 'Comanda' && response['time_cost'] != 0) ||
          response['total'] is! num ||
          !(response['total'] as num).isFinite ||
          (response['total'] as num) < 0 ||
          response['items'] is! List ||
          response['has_more'] is! bool) {
        throw const FormatException('La respuesta de cobro no es válida.');
      }

      final pageRevision = response['revision'] as int;
      final pageCount = response['item_count'] as int;
      final pageTableId = response['table_id'] as int;
      final pageActorId = response['actor_id'] as String;
      final pageOpenedAt = DateTime.parse(response['opened_at'] as String);
      final quotedAt = DateTime.parse(response['quoted_at'] as String);
      final timeCost = (response['time_cost'] as num).toDouble();
      final total = (response['total'] as num).toDouble();
      if ((revision != null && revision != pageRevision) ||
          (itemCount != null && itemCount != pageCount) ||
          (tableId != null && tableId != pageTableId) ||
          (actorId != null && actorId != pageActorId) ||
          (openedAt != null && !openedAt.isAtSameMomentAs(pageOpenedAt)) ||
          quotedAt.isBefore(pageOpenedAt) ||
          ((pageCount == 0) != (pageRevision == 0))) {
        throw const FormatException('El servicio cambió durante la consulta.');
      }
      revision = pageRevision;
      itemCount = pageCount;
      tableId = pageTableId;
      actorId = pageActorId;
      openedAt = pageOpenedAt;
      final rows = response['items'] as List;
      final hasMore = response['has_more'] as bool;
      if (rows.length > 50 || (hasMore && rows.length != 50)) {
        throw const FormatException('La página de cobro no es válida.');
      }
      for (final row in rows) {
        if (row is! Map) {
          throw const FormatException('El consumo recibido no es válido.');
        }
        final item = StaffTableConsumptionSnapshot.fromMap(row);
        if ((before == null && items.isEmpty && item.ordinal != revision) ||
            (before != null && item.ordinal >= before) ||
            !requestIds.add(item.requestId)) {
          throw const FormatException('La página de cobro no es válida.');
        }
        before = item.ordinal;
        items.add(item);
      }
      if (items.length > itemCount || (hasMore && items.length >= itemCount)) {
        throw const FormatException(
          'Los consumos recibidos no están completos.',
        );
      }
      if (!hasMore) {
        if (items.length != itemCount) {
          throw const FormatException(
            'Los consumos recibidos no están completos.',
          );
        }
        final calculated = items.fold<double>(
          timeCost,
          (sum, item) => sum + item.quantity * item.price,
        );
        if (!calculated.isFinite ||
            (calculated - total).abs() >
                math.max(0.000001, calculated.abs() * 0.0000000001)) {
          throw const FormatException('El total de cobro no coincide.');
        }
        return StaffTableCheckoutSnapshot(
          serviceId: serviceId,
          tableId: tableId,
          tableType: tableType,
          actorId: actorId,
          openedAt: openedAt,
          revision: revision,
          quotedAt: quotedAt,
          timeCost: timeCost,
          total: total,
          items: List.unmodifiable(items),
        );
      }
    }
  }
}
