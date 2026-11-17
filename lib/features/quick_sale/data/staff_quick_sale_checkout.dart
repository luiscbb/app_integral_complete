import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/sync_session.dart';
import '../../auth/data/staff_module_access_guard.dart';
import '../../auth/domain/staff_access.dart';
import 'staff_quick_sale_outbox.dart';
import 'staff_quick_sale_reconciler.dart';

class StaffQuickSaleCheckout {
  const StaffQuickSaleCheckout(this.client, this.outbox);

  final SupabaseClient client;
  final StaffQuickSaleOutbox outbox;

  Future<void> _requireAccess(SyncSession session) => requireStaffModuleAccess(
    client: client,
    session: session,
    requireSession: outbox.requireSession,
    module: StaffModule.quickSale,
  );

  Future<int> checkout({
    required SyncSession session,
    required String saleDate,
    required String paymentMethod,
    required double total,
    required double paid,
    required List<StaffQuickSaleItem> items,
  }) async {
    await _requireAccess(session);
    final request = await outbox.prepare(
      session: session,
      saleDate: saleDate,
      paymentMethod: paymentMethod,
      total: total,
      paid: paid,
      items: items,
    );
    return _complete(session, request);
  }

  Future<int?> recover(SyncSession session) async {
    await _requireAccess(session);
    final request = await outbox.pending(session);
    if (request == null) return null;
    return _complete(session, request);
  }

  Future<int> _complete(
    SyncSession session,
    PendingStaffQuickSale request,
  ) async {
    await StaffQuickSaleSender(
      client,
      outbox,
    ).send(session: session, request: request);
    return StaffQuickSaleReconciler(
      client,
      outbox,
    ).reconcile(session: session, request: request);
  }
}
