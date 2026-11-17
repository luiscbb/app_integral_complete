import 'package:app_integral_complete/features/purchases/domain/entities/provider_entity.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/purchase_payment_terms.dart';
import 'package:app_integral_complete/features/purchases/presentation/widgets/purchase_payment_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> open(
    WidgetTester tester, {
    ProviderEntity? provider,
    required ValueChanged<PurchasePaymentTerms?> onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder:
                (context) => TextButton(
                  onPressed: () async {
                    onResult(
                      await showDialog<PurchasePaymentTerms>(
                        context: context,
                        builder:
                            (_) => PurchasePaymentDialog(
                              provider: provider,
                              total: 250,
                            ),
                      ),
                    );
                  },
                  child: const Text('Abrir'),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
  }

  Future<void> option(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'prefills credit and lets this purchase override days without changing provider',
    (tester) async {
      const provider = ProviderEntity(
        id: 1,
        name: 'Proveedor',
        creditDays: 30,
        preferredPaymentMethod: 'credito',
      );
      PurchasePaymentTerms? result;
      await open(
        tester,
        provider: provider,
        onResult: (value) => result = value,
      );
      expect(find.text('Crédito'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(find.text('Pagado: \$0.00 · Saldo: \$250.00'), findsOneWidget);
      expect(find.text('Origen del efectivo'), findsNothing);
      await tester.enterText(find.byType(TextFormField), '45');
      await tester.tap(find.text('CONFIRMAR Y REGISTRAR'));
      await tester.pumpAndSettle();
      expect(result!.isCredit, true);
      expect(result!.creditDays, 45);
      expect(result!.legacyCashSource, isNull);
      expect(provider.creditDays, 30);
      expect(provider.preferredPaymentMethod, 'credito');
    },
  );

  testWidgets(
    'prefills transfer and keeps an exceptional cash source only in its result',
    (tester) async {
      const provider = ProviderEntity(
        id: 1,
        name: 'Proveedor',
        preferredPaymentMethod: 'transferencia',
      );
      PurchasePaymentTerms? result;
      await open(
        tester,
        provider: provider,
        onResult: (value) => result = value,
      );
      expect(find.text('Transferencia'), findsOneWidget);
      expect(find.text('Origen del efectivo'), findsNothing);
      await option(tester, 'Efectivo');
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cajero (directo)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('CONFIRMAR Y REGISTRAR'));
      await tester.pumpAndSettle();
      expect(result!.option, 'efectivo');
      expect(result!.cashSource, 'cajero');
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      expect(find.text('Transferencia'), findsOneWidget);
      expect(find.text('Origen del efectivo'), findsNothing);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(provider.preferredPaymentMethod, 'transferencia');
    },
  );

  testWidgets(
    'requires valid days and a provider for credit but permits card without a provider',
    (tester) async {
      PurchasePaymentTerms? result;
      await open(tester, onResult: (value) => result = value);
      await option(tester, 'Crédito');
      for (final invalid in ['', '-1', '1.5', '2147483648']) {
        await tester.enterText(find.byType(TextFormField), invalid);
        await tester.tap(find.text('CONFIRMAR Y REGISTRAR'));
        await tester.pumpAndSettle();
        expect(find.text('Ingresa días enteros no negativos.'), findsOneWidget);
        expect(result, isNull);
      }
      await tester.enterText(find.byType(TextFormField), '0');
      await tester.tap(find.text('CONFIRMAR Y REGISTRAR'));
      await tester.pumpAndSettle();
      expect(
        find.text('Selecciona un proveedor para comprar a crédito.'),
        findsOneWidget,
      );
      await option(tester, 'Tarjeta');
      await tester.tap(find.text('CONFIRMAR Y REGISTRAR'));
      await tester.pumpAndSettle();
      expect(result!.option, 'tarjeta');
      expect(result!.creditDays, isNull);
      expect(result!.cashSource, isNull);
    },
  );

  test(
    'financial snapshots use the registration UTC day and calendar arithmetic',
    () {
      final credit = PurchasePaymentTerms(option: 'credito', creditDays: 2);
      expect(
        credit.snapshot(total: 250, recordedAt: DateTime.utc(2028, 2, 28)),
        {
          'payment_condition': 'credito',
          'payment_method': null,
          'credit_days': 2,
          'due_date': '2028-03-01',
          'paid_amount': 0.0,
          'balance_due': 250.0,
        },
      );
      final zeroDays = PurchasePaymentTerms(option: 'credito', creditDays: 0);
      expect(
        zeroDays.snapshot(
          total: 250,
          recordedAt: DateTime.parse('2026-11-16T23:00:00-06:00'),
        )['due_date'],
        '2026-11-17',
      );
      final paid = PurchasePaymentTerms(option: 'efectivo', cashSource: 'caja');
      final snapshot = paid.snapshot(
        total: 250,
        recordedAt: DateTime.utc(2026, 11, 16),
      );
      expect(snapshot['paid_amount'], 250);
      expect(snapshot['balance_due'], 0);
      expect(snapshot['due_date'], isNull);
      expect(
        () => paid.snapshot(total: double.infinity, recordedAt: DateTime.now()),
        throwsArgumentError,
      );
      for (final days in [2147483647, 213503983]) {
        expect(
          () => PurchasePaymentTerms(
            option: 'credito',
            creditDays: days,
          ).snapshot(total: 250, recordedAt: DateTime.utc(2026, 11, 16)),
          throwsArgumentError,
        );
      }
    },
  );
}
