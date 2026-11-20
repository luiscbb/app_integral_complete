import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import 'staff_table_service_outbox.dart';

class StaffTableServiceSync {
  const StaffTableServiceSync(this.client, this.outbox);

  final SupabaseClient client;
  final StaffTableServiceOutbox outbox;

  Future<Map<dynamic, dynamic>> _invoke(
    SyncSession session,
    String function,
    Map<String, Object> params,
  ) async {
    outbox.requireSession(session);
    final response = await client
        .rpc(function, params: params)
        .setHeader('Authorization', 'Bearer ${session.token}');
    outbox.requireSession(session);
    if (response is! Map) {
      throw const FormatException('La respuesta del servicio no es válida.');
    }
    return response;
  }

  Future<StaffTableServiceDraft> synchronize(
    SyncSession session,
    String serviceId,
  ) async {
    final drafts = await outbox.drafts(session);
    final matches = drafts.where((draft) => draft.id == serviceId).toList();
    if (matches.length != 1) {
      throw StateError('El servicio local no está disponible.');
    }
    var draft = matches.single;
    if (draft.state == 'pending') {
      final receipt = await _invoke(session, 'staff_table_open', {
        'requested_service_id': draft.id,
        'requested_billar_id': session.billarId,
        'requested_table_id': draft.tableId,
        'requested_table_type': draft.tableType,
        'requested_opened_at': draft.openedAt.toUtc().toIso8601String(),
      });
      draft = await outbox.confirmOpen(
        session: session,
        draft: draft,
        receipt: receipt,
      );
    }
    if (draft.state == 'closed') return draft;
    if (draft.state != 'active' && draft.state != 'conflict') {
      throw StateError('El servicio no puede sincronizarse.');
    }
    final items = await outbox.consumptions(session, draft.id);
    for (final item in items.where((item) => !item.confirmed)) {
      final receipt = await _invoke(session, 'staff_table_add_consumption', {
        'requested_request_id': item.requestId,
        'requested_billar_id': session.billarId,
        'requested_service_id': draft.id,
        'requested_table_type': draft.tableType,
        'requested_product_id': item.productId,
        'requested_product_name': item.productName,
        'requested_quantity': item.quantity,
        'requested_price': item.price,
        'requested_recorded_at': item.recordedAt.toUtc().toIso8601String(),
      });
      draft = await outbox.confirmConsumption(
        session: session,
        consumption: item,
        receipt: receipt,
      );
    }
    return draft;
  }
}
