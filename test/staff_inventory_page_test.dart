import 'package:app_integral_complete/features/inventory/presentation/pages/staff_inventory_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'standalone staff inventory is disabled without integration or a session',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: StaffInventoryPage()));
      expect(
        find.text('El inventario de personal aún no está habilitado.'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Actualizar inventario'), findsNothing);
    },
  );
}
