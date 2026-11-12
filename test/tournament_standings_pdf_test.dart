import 'package:flutter_test/flutter_test.dart';
import 'package:app_integral_complete/features/tournaments/domain/tournament.dart';
import 'package:app_integral_complete/features/tournaments/presentation/tournament_standings_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generates a printable Round Robin standings PDF', () async {
    final entries = const [
      TournamentEntry(id: 'player-1', name: 'ANA'),
      TournamentEntry(id: 'player-2', name: 'LUIS'),
    ];
    final matches =
        TournamentSchedule.createRoundRobin(entries)
            .map(
              (match) =>
                  match.copyWith(winnerEntryId: match.player1Id, sets1: 1),
            )
            .toList();
    final tournament = TournamentEntity(
      id: 'tournament-1',
      billarId: 'billar-1',
      name: 'COPA DE PRUEBA',
      format: 'liga',
      capacity: 2,
      entries: entries,
      matches: matches,
      createdAt: '2026-11-12T10:00:00Z',
      updatedAt: '2026-11-12T10:00:00Z',
    );

    final pdf = await TournamentStandingsPdf.generate(tournament);

    expect(String.fromCharCodes(pdf.take(4)), '%PDF');
    expect(pdf.length, greaterThan(1000));
  });
}
