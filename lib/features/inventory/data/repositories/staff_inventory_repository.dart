import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import '../../../auth/data/staff_module_access_guard.dart';
import '../../../auth/domain/staff_access.dart';
import '../../domain/entities/staff_inventory_product.dart';

class StaffInventoryRepository {
  const StaffInventoryRepository(this.client, this.requireSession);

  final SupabaseClient client;
  final void Function(SyncSession) requireSession;

  Future<List<StaffInventoryProduct>> load(SyncSession session) async {
    Future<void> authorize() => requireStaffModuleAccess(
      client: client,
      session: session,
      requireSession: requireSession,
      module: StaffModule.inventory,
    );
    await authorize();
    final products = <StaffInventoryProduct>[];
    var lastId = 0;
    while (true) {
      final Object response = await client
          .from('products')
          .setHeader('Authorization', 'Bearer ${session.token}')
          .select(
            'id,billar_id,name,barcode,category,presentation,price,cost,stock,is_active,is_promo,parent_id',
          )
          .eq('billar_id', session.billarId)
          .eq('is_active', true)
          .gt('id', lastId)
          .order('id', ascending: true)
          .limit(500);
      requireSession(session);
      if (response is! List) {
        throw const FormatException(
          'La respuesta del inventario no es válida.',
        );
      }
      if (response.isEmpty) break;
      for (final row in response) {
        if (row is! Map<String, dynamic>) {
          throw const FormatException(
            'La respuesta del inventario no es válida.',
          );
        }
        final product = StaffInventoryProduct.fromMap(
          row,
          billarId: session.billarId,
        );
        if (product.id <= lastId) {
          throw const FormatException(
            'El inventario contiene productos repetidos o desordenados.',
          );
        }
        lastId = product.id;
        products.add(product);
      }
    }
    await authorize();
    return List.unmodifiable(products);
  }
}
