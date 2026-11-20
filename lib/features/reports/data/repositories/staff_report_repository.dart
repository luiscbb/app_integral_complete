import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import '../../../auth/data/staff_module_access_guard.dart';
import '../../../auth/domain/staff_access.dart';
import 'staff_purchase_report_repository.dart';

typedef StaffReportItem =
    ({int id, DateTime date, String label, double amount, String details});

class StaffReport {
  const StaffReport({
    required this.count,
    required this.metrics,
    required this.items,
    required this.hasMore,
    this.incompleteExpenses = false,
  });

  final int count;
  final Map<String, double?> metrics;
  final List<StaffReportItem> items;
  final bool hasMore;
  final bool incompleteExpenses;
}

class StaffReportRepository {
  const StaffReportRepository(this.client, this.requireSession);

  final SupabaseClient client;
  final void Function(SyncSession) requireSession;

  Future<StaffReport> load(
    SyncSession session,
    StaffModule module,
    DateTime start,
    DateTime end, {
    int? beforeId,
  }) async {
    if (module.parent != StaffModule.reports ||
        !end.isAfter(start) ||
        end.difference(start) > const Duration(days: 366) ||
        (beforeId != null && beforeId <= 0)) {
      throw ArgumentError(
        'Selecciona un informe y un rango de hasta 366 días.',
      );
    }
    if (module == StaffModule.reportsPurchases) {
      final report = await StaffPurchaseReportRepository(
        client,
        requireSession,
      ).load(session, start, end, beforeId: beforeId);
      return StaffReport(
        count: report.count,
        metrics: {
          'Total comprado': report.total,
          'Pagado registrado': report.paid,
          'Saldo registrado': report.balance,
        },
        items: List.unmodifiable([
          for (final purchase in report.items)
            (
              id: purchase.id,
              date: purchase.date,
              label: purchase.providerName ?? 'Sin proveedor',
              amount: purchase.total,
              details:
                  '${purchase.reference}\n'
                  'Pagado: ${purchase.paid.toStringAsFixed(2)} · '
                  'Saldo: ${purchase.balance.toStringAsFixed(2)}',
            ),
        ]),
        hasMore: report.hasMore,
      );
    }
    Future<void> authorize() => requireStaffModuleAccess(
      client: client,
      session: session,
      requireSession: requireSession,
      module: module,
    );
    await authorize();
    final Object? response = await client
        .rpc(
          'staff_read_report',
          params: {
            'requested_billar_id': session.billarId,
            'requested_report': module.id,
            'start_at': start.toUtc().toIso8601String(),
            'end_at': end.toUtc().toIso8601String(),
            'before_id': beforeId,
          },
        )
        .setHeader('Authorization', 'Bearer ${session.token}');
    requireSession(session);
    if (response is! Map<String, dynamic> ||
        response['billar_id'] != session.billarId ||
        response['report'] != module.id ||
        response['count'] is! int ||
        response['count'] < 0 ||
        response['has_more'] is! bool ||
        response['items'] is! List ||
        response['metrics'] is! Map<String, dynamic> ||
        response['incomplete_expenses'] is! bool) {
      throw const FormatException('La respuesta del informe no es válida.');
    }
    final labels = switch (module) {
      StaffModule.reportsSales => const {
        'total': 'Total vendido',
        'paid': 'Cobrado registrado',
      },
      StaffModule.reportsCashFlow => const {
        'sales': 'Ventas en efectivo',
        'purchases': 'Compras pagadas de caja',
        'inflows': 'Aportes manuales',
        'outflows': 'Salidas en efectivo',
        'netCash': 'Movimiento neto de efectivo',
        'netFlow': 'Flujo total',
      },
      StaffModule.reportsProfit => const {
        'sales': 'Ventas',
        'cost': 'Costo de lo vendido',
        'expenses': 'Gastos identificados',
        'profit': 'Utilidad',
      },
      StaffModule.reportsKardex => const <String, String>{},
      _ => throw StateError('Informe no integrado.'),
    };
    final rawMetrics = response['metrics'] as Map<String, dynamic>;
    if (rawMetrics.length != labels.length ||
        !rawMetrics.keys.every(labels.containsKey)) {
      throw const FormatException('Los totales del informe no son válidos.');
    }
    final metrics = <String, double?>{};
    for (final entry in labels.entries) {
      final value = rawMetrics[entry.key];
      final nullable =
          module == StaffModule.reportsProfit &&
          const {'cost', 'profit'}.contains(entry.key);
      if (value == null && nullable) {
        metrics[entry.value] = null;
      } else if (value is num &&
          value.isFinite &&
          (value >= 0 ||
              const {'netCash', 'netFlow', 'profit'}.contains(entry.key))) {
        metrics[entry.value] = value.toDouble();
      } else {
        throw const FormatException('Un total del informe no es válido.');
      }
    }
    final rows = response['items'] as List;
    if (rows.length > 50 ||
        response['count'] < rows.length ||
        (response['has_more'] == true && rows.length != 50) ||
        ((module == StaffModule.reportsCashFlow ||
                module == StaffModule.reportsProfit) &&
            (rows.isNotEmpty || response['has_more'] == true))) {
      throw const FormatException('La página del informe no es válida.');
    }
    final items = <StaffReportItem>[];
    var previous = beforeId;
    for (final row in rows) {
      if (row is! Map<String, dynamic> ||
          row['billar_id'] != session.billarId ||
          row['id'] is! int ||
          row['id'] <= 0 ||
          (previous != null && row['id'] >= previous) ||
          row['date'] is! String ||
          row['label'] is! String ||
          row['details'] is! String ||
          row['amount'] is! num ||
          !(row['amount'] as num).isFinite ||
          (module != StaffModule.reportsKardex && row['amount'] < 0)) {
        throw const FormatException('Un registro del informe no es válido.');
      }
      final date = DateTime.tryParse(row['date'] as String);
      if (date == null || date.isBefore(start) || !date.isBefore(end)) {
        throw const FormatException(
          'Un registro está fuera del rango solicitado.',
        );
      }
      previous = row['id'] as int;
      items.add((
        id: previous,
        date: date.toLocal(),
        label: row['label'] as String,
        amount: (row['amount'] as num).toDouble(),
        details: row['details'] as String,
      ));
    }
    final report = StaffReport(
      count: response['count'] as int,
      metrics: Map.unmodifiable(metrics),
      items: List.unmodifiable(items),
      hasMore: response['has_more'] as bool,
      incompleteExpenses: response['incomplete_expenses'] as bool,
    );
    await authorize();
    return report;
  }
}
