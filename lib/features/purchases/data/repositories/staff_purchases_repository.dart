import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import '../../../auth/data/staff_module_access_guard.dart';
import '../../../auth/domain/staff_access.dart';
import '../../domain/entities/staff_purchase.dart';
import '../../domain/entities/staff_purchase_data.dart';
import '../../domain/entities/provider_entity.dart';
import '../../domain/entities/staff_operation_rejection.dart';
import 'staff_purchase_outbox.dart';

class StaffPurchasesRepository {
  const StaffPurchasesRepository(this.client, this.outbox);

  final SupabaseClient client;
  final StaffPurchaseOutbox outbox;

  Future<void> _authorize(SyncSession session) => requireStaffModuleAccess(
    client: client,
    session: session,
    requireSession: outbox.requireSession,
    module: StaffModule.purchases,
  );

  Future<StaffPurchaseData> load(SyncSession session) async {
    await _authorize(session);
    final rows = await _activeRows(
      session,
      'products',
      'id,billar_id,name,cost,parent_id,pieces_per_unit,is_active,is_promo',
    );
    final products =
        rows
            .map(
              (row) =>
                  StaffPurchaseProduct.fromMap(row, billarId: session.billarId),
            )
            .toList();
    final byId = {for (final product in products) product.id: product};
    for (final product in products.where(
      (product) => product.parentId != null,
    )) {
      final parent = byId[product.parentId];
      if (parent == null || parent.parentId != null) {
        throw const FormatException(
          'Una presentación no tiene un producto base activo.',
        );
      }
    }
    final providerRows = await _activeRows(
      session,
      'providers',
      'id,billar_id,name,phone,email,address,contact_name,notes,category,visit_days,credit_days,preferred_payment_method,is_active',
    );
    final providers = <ProviderEntity>[];
    for (final row in providerRows) {
      if (row['name'] is! String ||
          (row['name'] as String).trim().isEmpty ||
          [
            'phone',
            'email',
            'address',
            'contact_name',
            'notes',
            'category',
            'visit_days',
          ].any((field) => row[field] != null && row[field] is! String)) {
        throw const FormatException(
          'La información del proveedor no es válida.',
        );
      }
      providers.add(ProviderEntity.fromMap(row));
    }
    final history = <StaffPurchaseSummary>[];
    int? previous;
    while (history.length < 50) {
      var query = client
          .from('purchases')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .select(
            'id,billar_id,provider_id,reference,date,total,cancelled,cash_source,payment_condition,payment_method,credit_days,due_date,paid_amount,balance_due',
          )
          .eq('billar_id', session.billarId);
      if (previous != null) query = query.lt('id', previous);
      final Object historyRows = await query
          .order('id', ascending: false)
          .limit(50 - history.length);
      outbox.requireSession(session);
      if (historyRows is! List || historyRows.length > 50 - history.length) {
        throw const FormatException('La respuesta del historial no es válida.');
      }
      if (historyRows.isEmpty) break;
      for (final row in historyRows) {
        if (row is! Map<String, dynamic>) {
          throw const FormatException(
            'La respuesta del historial no es válida.',
          );
        }
        final purchase = StaffPurchaseSummary.fromMap(
          row,
          billarId: session.billarId,
        );
        if (previous != null && purchase.id >= previous) {
          throw const FormatException(
            'El historial contiene compras repetidas o desordenadas.',
          );
        }
        previous = purchase.id;
        history.add(purchase);
      }
    }
    await _authorize(session);
    return StaffPurchaseData(
      products: products,
      providers: providers,
      history: history,
    );
  }

  Future<List<Map<String, dynamic>>> _activeRows(
    SyncSession session,
    String table,
    String columns,
  ) async {
    final rows = <Map<String, dynamic>>[];
    var cursor = 0;
    while (true) {
      outbox.requireSession(session);
      var query = client
          .from(table)
          .setHeader('Authorization', 'Bearer ${session.token}')
          .select(columns)
          .eq('billar_id', session.billarId)
          .eq('is_active', true)
          .gt('id', cursor);
      if (table == 'products') query = query.eq('is_promo', 0);
      final Object response = await query
          .order('id', ascending: true)
          .limit(500);
      outbox.requireSession(session);
      if (response is! List) {
        throw const FormatException('La respuesta de compras no es válida.');
      }
      if (response.isEmpty) return rows;
      for (final row in response) {
        if (row is! Map<String, dynamic> ||
            row['id'] is! int ||
            (row['id'] as int) <= cursor ||
            row['billar_id'] != session.billarId ||
            row['is_active'] != true) {
          throw const FormatException(
            'La respuesta de compras contiene registros inválidos o repetidos.',
          );
        }
        cursor = row['id'] as int;
        rows.add(row);
      }
    }
  }

  Future<StaffPurchaseReceipt> record(
    SyncSession session,
    StaffPurchaseDraft draft,
  ) async {
    await _authorize(session);
    final request = await outbox.prepare(session, draft);
    return _send(session, request);
  }

  Future<StaffPurchaseReceipt?> recover(SyncSession session) async {
    await _authorize(session);
    final request = await outbox.pending(session);
    if (request == null) return null;
    return _send(session, request);
  }

  Future<StaffPurchaseReceipt?> resolvePending(SyncSession session) async {
    await _authorize(session);
    final request = await outbox.pending(session);
    if (request == null) return null;
    final Object? response = await client
        .rpc(
          'resolve_staff_purchase_request',
          params: {
            'p_request_id': request.draft.requestId,
            'p_billar_id': session.billarId,
            'p_kind': 'purchase',
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

  Future<StaffPurchaseReceipt> _send(
    SyncSession session,
    PendingStaffPurchase request,
  ) async {
    outbox.requireSession(session);
    if (request.rejection != null) throw request.rejection!;
    if (request.receipt != null) {
      await _authorize(session);
      return request.receipt!;
    }
    final Object? response = await client
        .rpc(
          'record_staff_purchase',
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
