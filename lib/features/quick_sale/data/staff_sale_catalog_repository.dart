import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/sync_session.dart';
import '../../auth/data/staff_module_access_guard.dart';
import '../../auth/domain/staff_access.dart';
import '../domain/entities/staff_sale_product.dart';

class StaffSaleCatalogRepository {
  const StaffSaleCatalogRepository(this.client, this.requireSession);

  final SupabaseClient client;
  final void Function(SyncSession) requireSession;

  Future<List<StaffSaleProduct>> load(SyncSession session) async {
    await requireStaffModuleAccess(
      client: client,
      session: session,
      requireSession: requireSession,
      module: StaffModule.quickSale,
    );
    final response = await client
        .rpc('staff_sale_products', params: {'p_billar_id': session.billarId})
        .setHeader('Authorization', 'Bearer ${session.token}');
    requireSession(session);
    if (response is! List) {
      throw const FormatException('El catálogo de venta no es válido.');
    }
    final products = <StaffSaleProduct>[];
    final ids = <int>{};
    for (final row in response) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('El catálogo de venta no es válido.');
      }
      final product = StaffSaleProduct.fromMap(row, billarId: session.billarId);
      if (!ids.add(product.id)) {
        throw const FormatException(
          'El catálogo contiene productos duplicados.',
        );
      }
      products.add(product);
    }
    return List.unmodifiable(products);
  }
}
