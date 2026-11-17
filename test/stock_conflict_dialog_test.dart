import 'package:app_integral_complete/features/inventory/presentation/widgets/stock_conflict_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('requires a valid final stock and shows both values', (
    tester,
  ) async {
    double? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    chosen = await showDialog<double>(
                      context: context,
                      builder:
                          (_) => const StockConflictDialog(
                            productName: 'AGUA',
                            localStock: 8,
                            remoteStock: 7,
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
    expect(find.text('Existencia en este dispositivo: 8.0'), findsOneWidget);
    expect(find.text('Existencia en el servidor: 7.0'), findsOneWidget);
    await tester.tap(find.text('Guardar existencia'));
    await tester.pumpAndSettle();
    expect(find.text('Ingresa una cantidad válida'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '6,5');
    await tester.tap(find.text('Guardar existencia'));
    await tester.pumpAndSettle();
    expect(chosen, 6.5);
  });
}
