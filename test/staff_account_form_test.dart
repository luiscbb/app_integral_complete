import 'package:app_integral_complete/features/auth/domain/staff_access.dart';
import 'package:app_integral_complete/features/auth/presentation/widgets/staff_account_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('requires a module and returns normalized staff details', (
    tester,
  ) async {
    StaffAccountDraft? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder:
                (context) => TextButton(
                  onPressed: () async {
                    result = await showDialog<StaffAccountDraft>(
                      context: context,
                      builder: (_) => const StaffAccountForm(),
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
    expect(
      find.widgetWithText(CheckboxListTile, 'Venta rápida'),
      findsOneWidget,
    );
    expect(find.widgetWithText(CheckboxListTile, 'Inventario'), findsOneWidget);
    expect(find.widgetWithText(CheckboxListTile, 'Compras'), findsOneWidget);
    expect(
      find.widgetWithText(CheckboxListTile, 'Jugadores y torneos'),
      findsNothing,
    );
    expect(find.widgetWithText(CheckboxListTile, 'Informes'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nombre completo'),
      '  Ana López  ',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Usuario'),
      'CAJERO.01',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Puesto o rol'),
      'Cajero',
    );
    await tester.tap(find.text('CONTINUAR'));
    await tester.pumpAndSettle();
    expect(find.text('Selecciona al menos un módulo.'), findsOneWidget);
    expect(result, isNull);

    await tester.ensureVisible(find.text('Venta rápida'));
    await tester.tap(find.text('Venta rápida'));
    await tester.tap(find.text('CONTINUAR'));
    await tester.pumpAndSettle();
    expect(result?.fullName, 'Ana López');
    expect(result?.username, 'cajero.01');
    expect(result?.jobTitle, 'Cajero');
    expect(result?.modules, {StaffModule.quickSale});
  });
}
