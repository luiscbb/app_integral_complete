import 'dart:convert';

import 'package:app_integral_complete/features/tournaments/domain/tournament.dart';
import 'package:app_integral_complete/features/tournaments/presentation/tournament_champion_certificate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generates a shareable champion PDF with the trophy artwork', () async {
    const champion = TournamentEntry(id: 'player-1', name: 'Ana');
    final tournament = TournamentEntity(
      id: 'tournament-1',
      billarId: 'billar-1',
      name: 'COPA DE PRUEBA',
      format: 'single',
      capacity: 2,
      entries: const [champion],
      raceTo: 3,
      setsToPlay: 1,
      createdAt: '',
      updatedAt: '2026-11-12T12:00:00Z',
    );

    final pdf = await TournamentChampionCertificate.generatePdf(tournament, champion);

    expect(ascii.decode(pdf.take(4).toList()), '%PDF');
    expect(pdf.length, greaterThan(1000));
  });
}
