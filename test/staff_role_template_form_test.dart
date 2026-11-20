import 'package:app_integral_complete/features/auth/data/staff_role_template_repository.dart';
import 'package:app_integral_complete/features/auth/domain/staff_access.dart';
import 'package:app_integral_complete/features/auth/presentation/widgets/staff_account_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRoleStore implements StaffRoleTemplateStore {
  final roles = <StaffRoleTemplate>[];
  bool failList = false;

  @override
  Future<List<StaffRoleTemplate>> list() async {
    if (failList) throw StateError('Servicio no disponible');
    return List.of(roles);
  }

  @override
  Future<StaffRoleTemplate> save({
    StaffRoleTemplate? existing,
    required String name,
    required Set<StaffModule> modules,
  }) async {
    final role = StaffRoleTemplate(
      id: existing?.id ?? 'role-${roles.length}',
      billarId: 'A',
      name: name,
      modules: modules,
      revision: existing == null ? 0 : existing.revision + 1,
    );
    if (existing != null) roles.removeWhere((item) => item.id == existing.id);
    roles.add(role);
    return role;
  }

  @override
  Future<void> delete(StaffRoleTemplate template) async {
    roles.removeWhere((item) => item.id == template.id);
  }
}

void main() {
  testWidgets(
    'saved roles copy selections and can be edited without changing the form',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = FakeRoleStore();
      await tester.pumpWidget(
        MaterialApp(
          home: StaffAccountForm(
            roleTemplates: store,
            initial: StaffAccountDraft(
              fullName: 'Ana',
              username: 'ana',
              jobTitle: 'Caja',
              modules: {StaffModule.quickSale},
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('CARGAR ROLES GUARDADOS'));
      await tester.tap(find.text('CARGAR ROLES GUARDADOS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GUARDAR COMO ROL NUEVO'));
      await tester.pumpAndSettle();
      expect(store.roles.single.name, 'Caja');
      expect(store.roles.single.modules, {StaffModule.quickSale});

      final inventory = find.byKey(
        const ValueKey('staff_module_checkbox_inventory'),
      );
      await tester.ensureVisible(inventory);
      await tester.tap(inventory);
      await tester.pumpAndSettle();
      expect(store.roles.single.modules, {StaffModule.quickSale});
      final roleTile = find.widgetWithText(ListTile, 'Caja');
      await tester.ensureVisible(roleTile);
      await tester.tap(
        find.descendant(
          of: roleTile,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actualizar con el formulario'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CONFIRMAR'));
      await tester.pumpAndSettle();
      expect(store.roles.single.modules, {
        StaffModule.quickSale,
        StaffModule.inventory,
      });

      await tester.ensureVisible(inventory);
      await tester.tap(inventory);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(inventory).value, isFalse);
      await tester.ensureVisible(roleTile);
      await tester.tap(
        find.descendant(
          of: roleTile,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Aplicar al formulario'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CONFIRMAR'));
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(inventory).value, isTrue);
      expect(store.roles.single.revision, 1);
    },
  );

  testWidgets('stale or unavailable templates never replace form selections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = FakeRoleStore();
    final role = await store.save(name: 'Mesero', modules: {});
    await tester.pumpWidget(
      MaterialApp(
        home: StaffAccountForm(
          roleTemplates: store,
          initial: StaffAccountDraft(
            fullName: 'Ana',
            username: 'ana',
            jobTitle: 'Caja',
            modules: {StaffModule.quickSale},
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('CARGAR ROLES GUARDADOS'));
    await tester.tap(find.text('CARGAR ROLES GUARDADOS'));
    await tester.pumpAndSettle();
    await store.save(
      existing: role,
      name: 'Mesero',
      modules: {StaffModule.inventory},
    );
    final tile = find.widgetWithText(ListTile, 'Mesero');
    await tester.tap(
      find.descendant(of: tile, matching: find.byType(PopupMenuButton<String>)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aplicar al formulario'));
    await tester.pumpAndSettle();
    expect(
      find.text('La plantilla cambió o ya no existe. Selecciónala nuevamente.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('staff_module_checkbox_quick_sale')),
          )
          .value,
      isTrue,
    );

    store.failList = true;
    await tester.ensureVisible(find.text('CARGAR ROLES GUARDADOS'));
    await tester.tap(find.text('CARGAR ROLES GUARDADOS'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('No se pudieron cargar los roles:'),
      findsOneWidget,
    );
    expect(find.text('CONTINUAR'), findsOneWidget);
  });
}
