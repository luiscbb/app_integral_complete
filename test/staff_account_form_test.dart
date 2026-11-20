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
    for (final module in StaffModule.values) {
      if (module.parent != null) continue;
      expect(find.text(module.label), findsOneWidget);
      final checkbox = tester.widget<Checkbox>(
        find.byKey(ValueKey('staff_module_checkbox_${module.id}')),
      );
      expect(checkbox.value, isFalse);
      expect(checkbox.onChanged != null, module.canAssignWhole);
    }
    await tester.ensureVisible(find.text('Informes'));
    await tester.tap(find.text('Informes'));
    await tester.pumpAndSettle();
    final reports = find.byKey(const ValueKey('staff_module_reports'));
    expect(
      find.descendant(of: reports, matching: find.text('Compras')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: reports, matching: find.byType(Checkbox)),
      findsNWidgets(6),
    );
    await tester.ensureVisible(find.text('Informes'));
    await tester.tap(find.text('Informes'));
    await tester.pumpAndSettle();
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

    final saleCheckbox = find.byKey(
      const ValueKey('staff_module_checkbox_quick_sale'),
    );
    await tester.ensureVisible(saleCheckbox);
    await tester.tap(saleCheckbox);
    await tester.tap(find.text('CONTINUAR'));
    await tester.pumpAndSettle();
    expect(result?.fullName, 'Ana López');
    expect(result?.username, 'cajero.01');
    expect(result?.jobTitle, 'Cajero');
    expect(result?.modules, {StaffModule.quickSale});
  });

  testWidgets(
    'assigns only the purchases report, not operational purchases or all reports',
    (tester) async {
      StaffAccountDraft? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () async {
                  result = await showDialog<StaffAccountDraft>(
                    context: context,
                    builder:
                        (_) => StaffAccountForm(
                          initial: StaffAccountDraft(
                            fullName: 'Ana',
                            username: 'ana',
                            jobTitle: 'Consulta',
                            modules: {StaffModule.reportsPurchases},
                          ),
                        ),
                  );
                },
                child: const Text('Abrir'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      final reports = find.byKey(
        const ValueKey('staff_module_checkbox_reports'),
      );
      expect(tester.widget<Checkbox>(reports).value, isNull);
      expect(tester.widget<Checkbox>(reports).onChanged, isNotNull);
      await tester.ensureVisible(find.text('Informes'));
      await tester.tap(find.text('Informes'));
      await tester.pumpAndSettle();
      final permission = find.byKey(
        const ValueKey('staff_permission_reports_purchases'),
      );
      await tester.ensureVisible(permission);
      expect(tester.widget<CheckboxListTile>(permission).value, isTrue);
      await tester.tap(permission);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(permission).value, isFalse);
      expect(tester.widget<Checkbox>(reports).value, isFalse);
      await tester.tap(permission);
      await tester.pumpAndSettle();
      await tester.tap(find.text('CONTINUAR'));
      await tester.pumpAndSettle();
      expect(result?.modules, {StaffModule.reportsPurchases});
    },
  );

  testWidgets(
    'editing preserves assigned modules while browsing pending sections',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: StaffAccountForm(
            initial: StaffAccountDraft(
              fullName: 'Operador',
              username: 'operador',
              jobTitle: 'Caja',
              modules: {StaffModule.quickSale, StaffModule.purchases},
            ),
          ),
        ),
      );
      final purchases = find.byKey(
        const ValueKey('staff_module_checkbox_purchases'),
      );
      expect(tester.widget<Checkbox>(purchases).value, isTrue);
      await tester.ensureVisible(find.text('Compras'));
      await tester.tap(find.text('Compras'));
      await tester.pumpAndSettle();
      expect(find.text('Gestión de proveedores'), findsOneWidget);
      expect(tester.widget<Checkbox>(purchases).value, isTrue);
      final reports = find.byKey(
        const ValueKey('staff_module_checkbox_reports'),
      );
      await tester.ensureVisible(reports);
      await tester.tap(reports);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(reports).value, isTrue);
      expect(tester.widget<Checkbox>(purchases).value, isTrue);
      await tester.tap(reports);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(reports).value, isFalse);
      expect(tester.widget<Checkbox>(purchases).value, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'operational table permissions are assignable independently and require their parent',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: StaffAccountForm(
            initial: StaffAccountDraft(
              fullName: 'Ana',
              username: 'ana',
              jobTitle: 'Mesero',
              modules: {
                StaffModule.billiardTables,
                StaffModule.billiardTablesOpen,
                StaffModule.billiardTablesConsume,
              },
            ),
          ),
        ),
      );
      final tables = find.byKey(const ValueKey('staff_module_billiard_tables'));
      await tester.ensureVisible(tables);
      await tester.tap(tables);
      await tester.pumpAndSettle();

      final open = find.byKey(
        const ValueKey('staff_permission_billiard_tables_open'),
      );
      final consume = find.byKey(
        const ValueKey('staff_permission_billiard_tables_consume'),
      );
      final charge = find.byKey(
        const ValueKey('staff_permission_billiard_tables_charge'),
      );
      expect(tester.widget<CheckboxListTile>(open).value, isTrue);
      expect(tester.widget<CheckboxListTile>(consume).value, isTrue);
      expect(tester.widget<CheckboxListTile>(charge).value, isFalse);
      expect(tester.widget<CheckboxListTile>(charge).onChanged, isNotNull);

      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(open).value, isFalse);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(
                const ValueKey('staff_module_checkbox_billiard_tables'),
              ),
            )
            .value,
        isTrue,
      );

      await tester.tap(consume);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(
                const ValueKey('staff_module_checkbox_billiard_tables'),
              ),
            )
            .value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('assigning a whole service keeps its parent and all actions', (
    tester,
  ) async {
    StaffAccountDraft? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showDialog<StaffAccountDraft>(
                      context: context,
                      builder:
                          (_) => StaffAccountForm(
                            initial: StaffAccountDraft(
                              fullName: 'Ana',
                              username: 'ana',
                              jobTitle: 'Mesero',
                              modules: const {},
                            ),
                          ),
                    );
                  },
                  child: const Text('OPEN'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    final tables = find.byKey(
      const ValueKey('staff_module_checkbox_billiard_tables'),
    );
    await tester.ensureVisible(tables);
    await tester.tap(tables);
    await tester.ensureVisible(find.text('CONTINUAR'));
    await tester.tap(find.text('CONTINUAR'));
    await tester.pumpAndSettle();
    expect(result?.modules, {
      StaffModule.billiardTables,
      StaffModule.billiardTablesOpen,
      StaffModule.billiardTablesConsume,
      StaffModule.billiardTablesCharge,
      StaffModule.billiardTablesViewAll,
    });
  });

  testWidgets('role recommendations require confirmation and remain editable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StaffAccountForm(
          initial: StaffAccountDraft(
            fullName: 'Ana',
            username: 'ana',
            jobTitle: 'Puesto existente',
            modules: {StaffModule.inventory},
          ),
        ),
      ),
    );
    final selector = find.byKey(const ValueKey('staff_role_recommendation'));
    final inventory = find.byKey(
      const ValueKey('staff_module_checkbox_inventory'),
    );
    final sale = find.byKey(const ValueKey('staff_module_checkbox_quick_sale'));
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cajero').last);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(inventory).value, isTrue);
    expect(tester.widget<Checkbox>(sale).value, isFalse);

    await tester.ensureVisible(find.text('APLICAR RECOMENDACIÓN'));
    await tester.tap(find.text('APLICAR RECOMENDACIÓN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CANCELAR').last);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(inventory).value, isTrue);

    await tester.ensureVisible(find.text('APLICAR RECOMENDACIÓN'));
    await tester.tap(find.text('APLICAR RECOMENDACIÓN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('APLICAR'));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(inventory).value, isFalse);
    expect(tester.widget<Checkbox>(sale).value, isTrue);
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Puesto o rol'),
          )
          .controller!
          .text,
      'Cajero',
    );
    await tester.ensureVisible(inventory);
    await tester.tap(inventory);
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(inventory).value, isTrue);
  });

  testWidgets('waiter recommendation enables opening and consuming only', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StaffAccountForm(
          initial: StaffAccountDraft(
            fullName: 'Ana',
            username: 'ana',
            jobTitle: 'Caja',
            modules: {StaffModule.quickSale},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('staff_role_recommendation')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mesero').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('APLICAR RECOMENDACIÓN'));
    await tester.tap(find.text('APLICAR RECOMENDACIÓN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('APLICAR'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('staff_module_checkbox_quick_sale')),
          )
          .value,
      isFalse,
    );
    final tables = find.byKey(
      const ValueKey('staff_module_checkbox_billiard_tables'),
    );
    expect(tester.widget<Checkbox>(tables).value, isTrue);
    final open = find.byKey(
      const ValueKey('staff_permission_billiard_tables_open'),
    );
    final consume = find.byKey(
      const ValueKey('staff_permission_billiard_tables_consume'),
    );
    final charge = find.byKey(
      const ValueKey('staff_permission_billiard_tables_charge'),
    );
    final viewAll = find.byKey(
      const ValueKey('staff_permission_billiard_tables_view_all'),
    );
    final tablesTile = find.byKey(
      const ValueKey('staff_module_billiard_tables'),
    );
    await tester.ensureVisible(tablesTile);
    await tester.tap(tablesTile);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(open).value, isTrue);
    expect(tester.widget<CheckboxListTile>(consume).value, isTrue);
    expect(tester.widget<CheckboxListTile>(charge).value, isFalse);
    expect(tester.widget<CheckboxListTile>(viewAll).value, isFalse);
  });

  testWidgets(
    'service actions are assignable while unsupported modules stay locked',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: StaffAccountForm()));
      for (final module in [StaffModule.billiardTables, StaffModule.dineIn]) {
        final tile = find.byKey(ValueKey('staff_module_${module.id}'));
        await tester.ensureVisible(tile);
        await tester.tap(
          find.descendant(of: tile, matching: find.text(module.label)),
        );
        await tester.pumpAndSettle();
        for (final action in [
          'Anotar consumos',
          'Cobrar o cerrar',
          'Ver servicios de otros',
          'Traspasar servicio',
        ]) {
          expect(
            find.descendant(of: tile, matching: find.text(action)),
            findsOneWidget,
          );
        }
        expect(
          tester
              .widget<Checkbox>(
                find.byKey(ValueKey('staff_module_checkbox_${module.id}')),
              )
              .onChanged,
          isNotNull,
        );
        await tester.ensureVisible(tile);
        await tester.tap(
          find.descendant(of: tile, matching: find.text(module.label)),
        );
        await tester.pumpAndSettle();
      }
      final personalAccount = find.byKey(
        const ValueKey('staff_module_personal_account'),
      );
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(
                const ValueKey('staff_module_checkbox_personal_account'),
              ),
            )
            .onChanged,
        isNull,
      );
      await tester.ensureVisible(personalAccount);
    },
  );
}
