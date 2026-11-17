import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import '../../../auth/data/staff_module_access_guard.dart';
import '../../../auth/domain/staff_access.dart';
import '../../domain/entities/staff_provider_operation.dart';
import '../../domain/entities/staff_operation_rejection.dart';
import 'staff_provider_outbox.dart';

class StaffProvidersRepository {
  const StaffProvidersRepository(this.client, this.outbox);

  final SupabaseClient client;
  final StaffProviderOutbox outbox;

  Future<void> _authorize(SyncSession session) => requireStaffModuleAccess(
    client: client,
    session: session,
    requireSession: outbox.requireSession,
    module: StaffModule.purchases,
  );

  Future<List<int>> productIds(SyncSession session, int providerId) async {
    if (providerId <= 0) throw ArgumentError('El proveedor no es válido.');
    await _authorize(session);
    final ids = <int>{};
    var cursor = 0;
    while (true) {
      final Object response = await client
          .from('provider_products')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .select('id,provider_id,product_id,providers!inner(billar_id)')
          .eq('providers.billar_id', session.billarId)
          .eq('provider_id', providerId)
          .gt('id', cursor)
          .order('id', ascending: true)
          .limit(500);
      outbox.requireSession(session);
      if (response is! List) {
        throw const FormatException(
          'Las relaciones del proveedor no son válidas.',
        );
      }
      if (response.isEmpty) break;
      for (final row in response) {
        if (row is! Map<String, dynamic>) {
          throw const FormatException(
            'La relación del proveedor no es válida.',
          );
        }
        final id = row['id'];
        final product = row['product_id'];
        final provider = row['providers'];
        if (id is! int ||
            id <= cursor ||
            row['provider_id'] != providerId ||
            product is! int ||
            product <= 0 ||
            provider is! Map<String, dynamic> ||
            provider['billar_id'] != session.billarId ||
            !ids.add(product)) {
          throw const FormatException(
            'Las relaciones del proveedor no son válidas.',
          );
        }
        cursor = id;
      }
    }
    await _authorize(session);
    return List.unmodifiable(ids);
  }

  Future<StaffProviderReceipt> apply(
    SyncSession session,
    StaffProviderDraft draft,
  ) async {
    await _authorize(session);
    final request = await outbox.prepare(session, draft);
    return _send(session, request);
  }

  Future<StaffProviderReceipt?> recover(SyncSession session) async {
    await _authorize(session);
    final request = await outbox.pending(session);
    return request == null ? null : _send(session, request);
  }

  Future<StaffProviderReceipt?> resolvePending(SyncSession session) async {
    await _authorize(session);
    final request = await outbox.pending(session);
    if (request == null) return null;
    final Object? response = await client
        .rpc(
          'resolve_staff_purchase_request',
          params: {
            'p_request_id': request.draft.requestId,
            'p_billar_id': session.billarId,
            'p_kind': 'provider',
            'p_request_payload': StaffOperationRejection.requestPayload(
              request.draft.parameters,
            ),
          },
        )
        .setHeader('Authorization', 'Bearer ${session.token}');
    outbox.requireSession(session);
    await _authorize(session);
    return outbox.complete(session, request, response);
  }

  Future<StaffProviderReceipt> _send(
    SyncSession session,
    PendingStaffProvider request,
  ) async {
    outbox.requireSession(session);
    if (request.rejection != null) throw request.rejection!;
    if (request.receipt != null) {
      await _authorize(session);
      return request.receipt!;
    }
    final Object? response = await client
        .rpc(
          'apply_staff_provider_operation',
          params: {
            ...request.draft.parameters,
            'p_request_id': request.draft.requestId,
            'p_billar_id': session.billarId,
          },
        )
        .setHeader('Authorization', 'Bearer ${session.token}');
    outbox.requireSession(session);
    await _authorize(session);
    return outbox.complete(session, request, response);
  }
}
