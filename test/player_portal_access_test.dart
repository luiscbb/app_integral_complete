import 'package:app_integral_complete/features/players/domain/entities/player_stats.dart';
import 'package:app_integral_complete/features/players/presentation/pages/player_access_pages.dart';
import 'package:app_integral_complete/features/players/presentation/pages/player_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('player portal opens statistics in read-only mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerPortalPage(player: PlayerEntity(name: 'Jugador')),
      ),
    );

    expect(find.text('RETAS / TRAINING'), findsNothing);
    expect(find.text('MIS ESTADÍSTICAS'), findsOneWidget);

    await tester.tap(find.text('MIS ESTADÍSTICAS'));
    await tester.pumpAndSettle();

    final detail = tester.widget<PlayerDetailPage>(
      find.byType(PlayerDetailPage),
    );
    expect(detail.readOnly, isTrue);
  });
}
