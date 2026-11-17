import 'package:app_integral_complete/features/config/presentation/widgets/config_tables_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget page(
    List<Map<String, dynamic>> tables, {
    void Function(int, String)? onEdit,
    ValueChanged<int>? onRemove,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ConfigTablesList(
            tables: tables,
            primaryColor: Colors.blue,
            onEdit: onEdit ?? (_, _) {},
            onRemove: onRemove ?? (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('separates mixed tables and preserves order and action targets', (
    tester,
  ) async {
    final edits = <(int, String)>[];
    final removals = <int>[];
    await tester.pumpWidget(
      page(
        [
          {'id': 8, 'name': 'Terraza', 'table_type': 'Comanda'},
          {'id': 3, 'name': 'Pool', 'table_type': 'Pool'},
          {'id': 5},
          {'id': 9, 'name': 'Barra', 'table_type': 'Comanda'},
        ],
        onEdit: (id, name) => edits.add((id, name)),
        onRemove: removals.add,
      ),
    );

    final lists = find.byType(ListView);
    expect(lists, findsNWidgets(2));
    expect(
      find.descendant(of: lists.at(0), matching: find.text('Pool')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: lists.at(0), matching: find.text('Mesa 5')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: lists.at(0), matching: find.text('Terraza')),
      findsNothing,
    );
    expect(
      find.descendant(of: lists.at(1), matching: find.text('Terraza')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: lists.at(1), matching: find.text('Barra')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('Pool')).dy,
      lessThan(tester.getTopLeft(find.text('Mesa 5')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Terraza')).dy,
      lessThan(tester.getTopLeft(find.text('Barra')).dy),
    );

    final editButtons = find.byTooltip('Editar nombre');
    final removeButtons = find.byTooltip('Eliminar mesa');
    for (var index = 0; index < 4; index++) {
      await tester.ensureVisible(editButtons.at(index));
      await tester.tap(editButtons.at(index));
      await tester.ensureVisible(removeButtons.at(index));
      await tester.tap(removeButtons.at(index));
    }
    expect(edits, [(3, 'Pool'), (5, 'Mesa 5'), (8, 'Terraza'), (9, 'Barra')]);
    expect(removals, [3, 5, 8, 9]);
  });

  testWidgets('shows an explicit empty group when only one type exists', (
    tester,
  ) async {
    await tester.pumpWidget(
      page([
        {'id': 1, 'name': 'Pool', 'table_type': 'Billar'},
      ]),
    );
    expect(find.text('MESAS DE JUEGO'), findsOneWidget);
    expect(find.text('MESAS DE COMANDA'), findsOneWidget);
    expect(find.text('No hay mesas de comanda.'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);

    await tester.pumpWidget(
      page([
        {'id': 2, 'name': 'Barra', 'table_type': 'Comanda'},
      ]),
    );
    expect(find.text('No hay mesas de juego.'), findsOneWidget);
    expect(find.text('Barra'), findsOneWidget);
    expect(find.text('Pool'), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('keeps the existing empty state when there are no tables', (
    tester,
  ) async {
    await tester.pumpWidget(page([]));
    expect(
      find.text(
        'No hay mesas. Usa el formulario de arriba para crear la primera.',
      ),
      findsOneWidget,
    );
    expect(find.byType(ListView), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });
}
