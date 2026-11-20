import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import '../../../auth/data/staff_module_access_guard.dart';
import '../../../auth/domain/staff_access.dart';

typedef ReportedPurchase =
    ({
      int id,
      DateTime date,
      String reference,
      String? providerName,
      double total,
      double paid,
      double balance,
    });

class StaffPurchaseReport {
  const StaffPurchaseReport({
    required this.count,
    required this.total,
    required this.paid,
    required this.balance,
    required this.items,
    required this.hasMore,
  });

  final int count;
  final double total;
  final double paid;
  final double balance;
  final List<ReportedPurchase> items;
  final bool hasMore;
}

class StaffPurchaseReportRepository {
  const StaffPurchaseReportRepository(this.client, this.requireSession);

  final SupabaseClient client;
  final void Function(SyncSession) requireSession;

  double _amount(Object? value) {
    if (value is! num || !value.isFinite || value < 0) {
      throw const FormatException('El informe contiene un importe inválido.');
    }
    return value.toDouble();
  }

  Future<StaffPurchaseReport> load(
    SyncSession session,
    DateTime start,
    DateTime end, {
    int? beforeId,
  }) async {
    if (!end.isAfter(start) ||
        end.difference(start) > const Duration(days: 366) ||
        (beforeId != null && beforeId <= 0)) {
      throw ArgumentError('Selecciona un rango válido de hasta 366 días.');
    }
    Future<void> authorize() => requireStaffModuleAccess(
      client: client,
      session: session,
      requireSession: requireSession,
      module: StaffModule.reportsPurchases,
    );
    await authorize();
    final Object? response = await client
        .rpc(
          'staff_purchase_report',
          params: {
            'requested_billar_id': session.billarId,
            'start_at': start.toUtc().toIso8601String(),
            'end_at': end.toUtc().toIso8601String(),
            'before_id': beforeId,
          },
        )
        .setHeader('Authorization', 'Bearer ${session.token}');
    requireSession(session);
    if (response is! Map<String, dynamic> ||
        response['billar_id'] != session.billarId ||
        response['count'] is! int ||
        (response['count'] as int) < 0 ||
        response['has_more'] is! bool ||
        response['items'] is! List) {
      throw const FormatException('La respuesta del informe no es válida.');
    }
    final rows = response['items'] as List;
    if (rows.length > 50 ||
        response['count'] < rows.length ||
        (response['has_more'] == true && rows.length != 50)) {
      throw const FormatException('La página del informe no es válida.');
    }
    final items = <ReportedPurchase>[];
    var previousId = beforeId;
    for (final row in rows) {
      if (row is! Map<String, dynamic> ||
          row['billar_id'] != session.billarId ||
          row['id'] is! int ||
          row['id'] <= 0 ||
          (previousId != null && row['id'] >= previousId) ||
          row['date'] is! String ||
          (row['reference'] != null && row['reference'] is! String) ||
          (row['provider_name'] != null && row['provider_name'] is! String)) {
        throw const FormatException('Una compra del informe no es válida.');
      }
      final date = DateTime.tryParse(row['date'] as String);
      if (date == null || date.isBefore(start) || !date.isBefore(end)) {
        throw const FormatException(
          'Una compra está fuera del rango solicitado.',
        );
      }
      previousId = row['id'] as int;
      items.add((
        id: previousId,
        date: date.toLocal(),
        reference: row['reference'] as String? ?? '',
        providerName: row['provider_name'] as String?,
        total: _amount(row['total']),
        paid: _amount(row['paid_amount']),
        balance: _amount(row['balance_due']),
      ));
    }
    final report = StaffPurchaseReport(
      count: response['count'] as int,
      total: _amount(response['total']),
      paid: _amount(response['paid']),
      balance: _amount(response['balance']),
      items: List.unmodifiable(items),
      hasMore: response['has_more'] as bool,
    );
    await authorize();
    return report;
  }
}
