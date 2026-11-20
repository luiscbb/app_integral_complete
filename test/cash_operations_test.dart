import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/core/theme/theme_provider.dart';
import 'package:app_integral_complete/features/cash/presentation/pages/cash_operations_page.dart';
import 'package:app_integral_complete/features/reports/data/repositories/reports_repository.dart';
import 'package:app_integral_complete/features/reports/presentation/pages/reports_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';

class CashPageRepository extends ReportsRepository {
  CashPageRepository({this.open = false});
  final bool open;

  @override
  Future<Map<String, dynamic>?> getOpenSession() async =>
      open
          ? {
            'id': 1,
            'billar_id': 'A',
            'opening_amount': 100,
            'created_by': 'Caja',
          }
          : null;

  @override
  Future<List<String>> getConcepts() async => ['GASTO'];

  @override
  Future<List<Map<String, dynamic>>> getCashOutflows(
    DateTime start,
    DateTime end,
  ) async => [];

  @override
  Future<Map<String, double>> getSessionCashFlowSummary(
    Map<String, dynamic> session,
  ) async => {'netCash': 0};
}

class FailingCashReportRepository extends ReportsRepository {
  @override
  Future<Map<String, double>> getCashFlowSummary(
    DateTime start,
    DateTime end,
  ) async {
    throw const FormatException('Forma de pago inválida.');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cash separates payment means, shift boundaries and partial withdrawals',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cash_operations_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      SharedPreferences.setMockInitialValues({'billar_id': 'A'});
      await PreferencesService().init();
      Database? db;
      try {
        db = await DatabaseHelper.instance.database;
        final repo = ReportsRepository();
        final opening = DateTime.now().subtract(const Duration(hours: 1));
        final during = opening.add(const Duration(minutes: 5));
        final sessionId = await repo.openSession(
          openingAmount: 50,
          createdBy: 'Caja',
        );
        await db.update(
          'cashier_sessions',
          {
            'opened_at': opening.toIso8601String(),
            'partial_closures': jsonEncode([
              {
                'amount': 6,
                'created_at': during.toIso8601String(),
                'notes': 'Anterior',
              },
            ]),
          },
          where: 'id = ?',
          whereArgs: [sessionId],
        );
        await expectLater(
          repo.openSession(openingAmount: 500),
          throwsStateError,
        );
        for (final (amount, paid, method, date, business, cancelled) in [
          (
            200,
            200,
            'Efectivo',
            opening.subtract(const Duration(minutes: 1)),
            'A',
            0,
          ),
          (10, 10, 'Efectivo', opening, 'A', 0),
          (100, 200, 'Efectivo', during, 'A', 0),
          (80, 80, 'Tarjeta', during.toUtc(), 'A', 0),
          (50, 50, 'Transferencia', during, 'A', 0),
          (900, 900, 'Efectivo', during, 'A', 1),
          (999, 999, 'Efectivo', during, 'B', 0),
          (888, 888, 'Efectivo', during.add(const Duration(days: 3)), 'A', 0),
        ]) {
          await db.insert('sales_history', {
            'billar_id': business,
            'total': amount,
            'paid': paid,
            'payment_method': method,
            'date': date.toIso8601String(),
            'type': 'Venta Rápida',
            'cancelled': cancelled,
          });
        }
        for (final (amount, source, method, condition) in [
          (40, 'caja', 'efectivo', 'contado'),
          (10, 'cajero', 'efectivo', 'contado'),
          (20, 'tarjeta', 'tarjeta', 'contado'),
          (30, 'transferencia', 'transferencia', 'contado'),
          (60, null, null, 'credito'),
          (5, 'caja', null, null),
        ]) {
          await db.insert('purchases', {
            'billar_id': 'A',
            'total': amount,
            'cash_source': source,
            'payment_method': method,
            'payment_condition': condition,
            'paid_amount':
                condition == 'credito'
                    ? 0
                    : condition == null
                    ? null
                    : amount,
            'date': during.toIso8601String(),
          });
        }
        for (final (amount, method) in [
          (15, 'Efectivo'),
          (5, 'Tarjeta'),
          (7, 'Transferencia'),
        ]) {
          await db.insert('cash_outflows', {
            'billar_id': 'A',
            'outflow_type': method == 'Efectivo' ? 'CORTE PARCIAL' : 'GASTO',
            'amount': amount,
            'payment_method': method,
            'created_at': during.toIso8601String(),
          });
        }
        await db.insert('cash_outflows', {
          'billar_id': 'A',
          'outflow_type': 'GASTO',
          'amount': 3,
          'created_at': during
              .toUtc()
              .toIso8601String()
              .replaceFirst('T', ' ')
              .replaceFirst('Z', ''),
        });
        final day = await repo.getCashFlowSummary(
          opening.subtract(const Duration(days: 1)),
          DateTime.now(),
        );
        expect(day['totalSales'], 440);
        expect(day['sales'], 310);
        expect(day['cardSales'], 80);
        expect(day['transferSales'], 50);
        expect(day['purchases'], 45);
        expect(day['totalPurchases'], 105);
        expect(day['creditPurchases'], 60);
        expect(day['totalOutflows'], 36);
        expect(day['netCash'], 241);
        expect(day['netFlow'], 299);
        for (final (id, business, kind, amount) in [
          (1, 'A', 'contribution', 50),
          (2, 'A', 'expense', 4),
          (3, 'A', 'withdrawal', 6),
          (4, 'A', 'partial', 8),
          (5, 'B', 'contribution', 999),
        ]) {
          await db.insert('cash_shared_movement_cache', {
            'cloud_id': id,
            'billar_id': business,
            'kind': kind,
            'amount': amount,
            'payment_method': 'Efectivo',
            'description': kind,
            'created_at': during.toIso8601String(),
          });
        }
        final withShared = await repo.getCashFlowSummary(
          opening.subtract(const Duration(days: 1)),
          DateTime.now(),
        );
        expect(withShared['inflows'], 50);
        expect(withShared['netCash'], 273);
        expect(withShared['netFlow'], 331);
        final session = (await repo.getOpenSession())!;
        expect(session['id'], sessionId);
        expect((await repo.getSessionCashFlowSummary(session))['netCash'], 41);
        await repo.addPartialClosure(
          amount: 11,
          notes: 'Parcial registrado',
          sessionId: sessionId,
          createdBy: 'Caja',
        );
        expect((await repo.getSessionCashFlowSummary(session))['netCash'], 30);
        expect(
          (await db.query(
            'cash_outflows',
            where: 'outflow_type = ? AND description = ?',
            whereArgs: ['CORTE PARCIAL', 'Parcial registrado'],
          )),
          hasLength(1),
        );
        expect(
          (await repo.getProfitSummary(
            opening.subtract(const Duration(days: 1)),
            DateTime.now(),
          ))['expenses'],
          34,
        );
        final closed = await repo.closeSession(
          closingAmount: 83,
          closedBy: 'Caja',
          sessionId: sessionId,
          nextOpeningAmount: 20,
        );
        expect(closed['expected'], 80);
        expect(closed['difference'], 3);
        final previous =
            (await db.query(
              'cashier_sessions',
              where: 'id = ?',
              whereArgs: [sessionId],
            )).single;
        expect(previous['is_closed'], 1);
        expect(previous['expected_amount'], 80);
        final next = (await repo.getOpenSession())!;
        expect(next['id'], isNot(sessionId));
        expect(next['opening_amount'], 20);
        expect((await repo.getSessionCashFlowSummary(next))['netCash'], 0);
        await expectLater(
          repo.closeSession(closingAmount: 0, sessionId: sessionId),
          throwsStateError,
        );
        await expectLater(
          repo.openSession(openingAmount: double.nan),
          throwsFormatException,
        );
        await expectLater(
          repo.closeSession(closingAmount: double.infinity),
          throwsFormatException,
        );
        await expectLater(
          repo.addPartialClosure(amount: -1),
          throwsArgumentError,
        );
        await repo.closeSession(
          closingAmount: 20,
          sessionId: next['id'] as int,
        );
        await expectLater(repo.addPartialClosure(amount: 5), throwsStateError);
        await expectLater(
          repo.closeSession(closingAmount: 0),
          throwsStateError,
        );
      } finally {
        if (db?.isOpen == true) await db!.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'invalid accounting data shows a retryable report error instead of loading forever',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReportsPage(repository: FailingCashReportRepository()),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('No se pudieron cargar los informes:'),
        findsOneWidget,
      );
      expect(find.text('REINTENTAR'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cash report is read-only and distinguishes total flow from physical cash',
    (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => ThemeProvider(),
          child: const MaterialApp(
            home: Scaffold(
              body: CashFlowReport(
                summary: {'totalSales': 440, 'netFlow': 299, 'netCash': 241},
              ),
            ),
          ),
        ),
      );
      expect(find.text('FLUJO DE CAJA · SOLO CONSULTA'), findsOneWidget);
      expect(find.text(r'$299.00'), findsOneWidget);
      expect(find.text(r'$241.00'), findsOneWidget);
      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.text('REGISTRAR RETIRO / GASTO'), findsNothing);
      expect(find.text('ABRIR TURNO'), findsNothing);
      expect(find.text('CORTE TOTAL'), findsNothing);
    },
  );

  testWidgets('operations without a shift do not allow withdrawals', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: CashOperationsPage(repository: CashPageRepository())),
    );
    await tester.pumpAndSettle();
    expect(find.text('CAJA Y TURNOS'), findsOneWidget);
    expect(find.text('ABRIR TURNO'), findsOneWidget);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'REGISTRAR RETIRO / GASTO'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('ABRIR TURNO'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Monto inicial en caja'),
      'NaN',
    );
    await tester.tap(find.text('ABRIR'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ingresa un monto válido'), findsOneWidget);
    expect(find.text('ABRIR'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'total cut asks explicitly whether to reopen and shows the counted difference',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CashOperationsPage(repository: CashPageRepository(open: true)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('CORTE TOTAL'));
      await tester.tap(find.text('CORTE TOTAL'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Efectivo contado'),
        '95',
      );
      await tester.pumpAndSettle();
      expect(find.text(r'Diferencia: -$5.00'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Fondo inicial del nuevo turno'),
        findsNothing,
      );
      await tester.ensureVisible(find.text('Cerrar y abrir nuevo turno'));
      await tester.tap(find.text('Cerrar y abrir nuevo turno'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextField, 'Fondo inicial del nuevo turno'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.text('TURNO ABIERTO'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
