import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/entities/pending_sale.dart';
import 'quick_sale_remote_data_source.dart';

class QuickSaleRemoteSupabase implements QuickSaleRemoteDataSource {
  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<bool> syncSale(PendingSale sale) async {
    try {
      await _client.from('pending_sales').insert({
        'product': sale.product,
        'quantity': sale.quantity,
        'price': sale.price,
        'created_at': sale.createdAt.toIso8601String(),
      });
      return true;
    } catch (_) {
      return false;
    }
  }
}
