import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:app_integral_complete/features/tournaments/domain/tournament.dart';

void main() {
  group('TournamentEntity', () {
    test('formats capped and open enrollment counts', () {
      final capped = TournamentEntity(
        id: 'id-1',
        billarId: 'billar-1',
        name: 'LIGA',
        format: 'liga',
        capacity: 8,
        entries: const [
          TournamentEntry(id: 'entry-1', name: 'Ana'),
          TournamentEntry(id: 'entry-2', name: 'Luis'),
        ],
        createdAt: '',
        updatedAt: '',
      );
      final open = TournamentEntity(
        id: 'id-2',
        billarId: 'billar-1',
        name: 'ABIERTO',
        format: 'single',
        capacity: null,
        entries: capped.entries,
        createdAt: '',
        updatedAt: '',
      );

      expect(capped.enrollmentLabel, '2/8');
      expect(capped.isFull, isFalse);
      expect(open.enrollmentLabel, '2 inscritos · Abierto');
      expect(open.isFull, isFalse);
    });

    test('round trips registered and walk-in entries through local cache', () {
      final tournament = TournamentEntity(
        id: 'id-1',
        billarId: 'billar-1',
        name: 'COPA',
        format: 'liga',
        capacity: 8,
        raceTo: 13,
        setsToPlay: 3,
        entries: const [
          TournamentEntry(
            id: 'entry-1',
            name: 'Ana',
            playerCode: 'JUG-001',
            registeredPlayerId: 'cloud-player-1',
            handicap: 3,
          ),
          TournamentEntry(
            id: 'entry-2',
            name: 'Invitado',
            isGuest: true,
            handicap: 2,
          ),
        ],
        createdAt: '2026-11-12T12:00:00Z',
        updatedAt: '2026-11-12T12:00:00Z',
      );

      final restored = TournamentEntity.fromLocalMap(tournament.toLocalMap());

      expect(restored.name, 'COPA');
      expect(restored.raceTo, 13);
      expect(restored.setsToPlay, 3);
      expect(restored.entries, hasLength(2));
      expect(restored.entries.first.playerCode, 'JUG-001');
      expect(restored.entries.first.registeredPlayerId, 'cloud-player-1');
      expect(restored.entries.last.isGuest, isTrue);
      expect(restored.entries.last.handicap, 2);
      expect(restored.entries.last.name, 'INVITADO');
      expect(restored.entries.last.displayName, 'INVITADO');
    });

    test(
      'calculates and persists tournament entry, prize, and time amounts',
      () {
        final tournament = TournamentEntity(
          id: 'id-1',
          billarId: 'billar-1',
          name: 'COPA',
          format: 'single',
          capacity: 8,
          guaranteedPool: 100,
          entryFee: 25,
          timeFee: 40,
          prizes: const [
            TournamentPrize(place: 1, type: 'percentage', value: 50),
            TournamentPrize(place: 2, type: 'fixed', value: 30),
          ],
          entries: const [
            TournamentEntry(id: 'player-1', name: 'Ana'),
            TournamentEntry(id: 'player-2', name: 'Luis'),
          ],
          matches: const [
            TournamentMatch(
              id: 'complete',
              round: 1,
              matchNumber: 1,
              player1Id: 'player-1',
              player2Id: 'player-2',
              winnerEntryId: 'player-1',
            ),
            TournamentMatch(
              id: 'incomplete',
              round: 1,
              matchNumber: 2,
              player1Id: 'player-1',
              player2Id: 'player-2',
            ),
          ],
          createdAt: '',
          updatedAt: '',
        );

        expect(tournament.entryTotal, 50);
        expect(tournament.prizePool, 150);
        expect(tournament.completedMatches, 1);
        expect(tournament.timeRevenue, 40);
        expect(tournament.prizes.first.amountFor(tournament.prizePool), 75);

        final restored = TournamentEntity.fromLocalMap(tournament.toLocalMap());
        expect(restored.guaranteedPool, 100);
        expect(restored.entryFee, 25);
        expect(restored.timeFee, 40);
        expect(restored.prizes, hasLength(2));
        expect(restored.prizes.last.type, 'fixed');
        expect(restored.prizes.last.value, 30);
      },
    );

    test('creates a shuffled single-elimination bracket for eight players', () {
      final entries = List.generate(
        8,
        (index) => TournamentEntry(id: 'player-$index', name: 'Jugador $index'),
      );

      final matches = TournamentBracket.create(entries, random: Random(21));

      expect(matches, hasLength(7));
      expect(matches.where((match) => match.round == 1), hasLength(4));
      expect(matches.where((match) => match.round == 2), hasLength(2));
      expect(matches.where((match) => match.round == 3), hasLength(1));
      final firstRoundPlayers =
          matches
              .where((match) => match.round == 1)
              .expand((match) => [match.player1Id, match.player2Id])
              .whereType<String>()
              .toList();
      expect(
        firstRoundPlayers.toSet(),
        entries.map((entry) => entry.id).toSet(),
      );
      expect(
        matches
            .where((match) => match.round > 1)
            .every((match) => !match.isReady),
        isTrue,
      );
    });

    test('advances winners and rolls back an unfinished next-round bye', () {
      final entries = List.generate(
        8,
        (index) => TournamentEntry(id: 'player-$index', name: 'Jugador $index'),
      );
      final matches = TournamentBracket.create(entries, random: Random(21));
      final firstQuarter = matches.firstWhere(
        (match) => match.round == 1 && match.matchNumber == 1,
      );
      final secondQuarter = matches.firstWhere(
        (match) => match.round == 1 && match.matchNumber == 2,
      );
      final semifinal = matches.firstWhere(
        (match) => match.round == 2 && match.matchNumber == 1,
      );
      final firstWinner = firstQuarter.player1Id!;
      final secondWinner = secondQuarter.player2Id!;
      final firstResult = firstQuarter.copyWith(
        score1: 3,
        winnerEntryId: firstWinner,
      );
      matches[matches.indexOf(firstQuarter)] = firstResult;
      TournamentBracket.advanceWinner(matches, firstQuarter, firstResult);
      final secondResult = secondQuarter.copyWith(
        score2: 3,
        winnerEntryId: secondWinner,
      );
      matches[matches.indexOf(secondQuarter)] = secondResult;
      TournamentBracket.advanceWinner(matches, secondQuarter, secondResult);

      expect(
        matches.firstWhere((match) => match.id == semifinal.id).isReady,
        isTrue,
      );

      final correctedFirst = firstResult.copyWith(
        score1: 2,
        winnerEntryId: null,
      );
      matches[matches.indexOf(firstResult)] = correctedFirst;
      TournamentBracket.advanceWinner(matches, firstResult, correctedFirst);
      final updatedSemifinal = matches.firstWhere(
        (match) => match.id == semifinal.id,
      );
      final finalMatch = matches.firstWhere((match) => match.round == 3);

      expect(updatedSemifinal.player1Id, isNull);
      expect(updatedSemifinal.player2Id, secondWinner);
      expect(updatedSemifinal.winnerEntryId, isNull);
      expect(finalMatch.player1Id, isNull);
      expect(finalMatch.player2Id, isNull);
    });

    test(
      'uses preliminary rounds and byes to complete a 10-player bracket',
      () {
        final entries = List.generate(
          10,
          (index) =>
              TournamentEntry(id: 'player-$index', name: 'Jugador $index'),
        );

        final matches = TournamentBracket.create(entries, random: Random(9));
        final firstRound = matches.where((match) => match.round == 1).toList();
        final preliminaryMatches =
            firstRound.where((match) => match.isReady).toList();
        final automaticAdvances = firstRound.where((match) => match.isBye);
        final secondRound = matches.where((match) => match.round == 2).toList();

        expect(preliminaryMatches, hasLength(2));
        expect(automaticAdvances, hasLength(6));
        expect(
          automaticAdvances.every((match) => match.winnerEntryId != null),
          isTrue,
        );
        expect(secondRound, hasLength(4));
        expect(secondRound.where((match) => match.isReady), hasLength(3));
        expect(secondRound.where((match) => !match.isReady), hasLength(1));
        for (final match in preliminaryMatches) {
          final result = match.copyWith(winnerEntryId: match.player1Id);
          TournamentBracket.advanceWinner(matches, match, result);
          matches[matches.indexOf(match)] = result;
        }
        expect(
          matches
              .where((match) => match.round == 2)
              .every((match) => match.isReady),
          isTrue,
        );
        expect(
          firstRound
              .expand((match) => [match.player1Id, match.player2Id])
              .whereType<String>()
              .toSet(),
          entries.map((entry) => entry.id).toSet(),
        );
      },
    );

    test('does not strand entrants in a smaller non-power-of-two bracket', () {
      final entries = List.generate(
        5,
        (index) => TournamentEntry(id: 'player-$index', name: 'Jugador $index'),
      );

      final matches = TournamentBracket.create(entries, random: Random(9));
      final firstRound = matches.where((match) => match.round == 1).toList();
      final secondRound = matches.where((match) => match.round == 2).toList();

      expect(firstRound.where((match) => match.isReady), hasLength(1));
      expect(firstRound.where((match) => match.isBye), hasLength(3));
      expect(secondRound, hasLength(2));
      expect(secondRound.where((match) => match.isReady), hasLength(1));
      final preliminary = firstRound.singleWhere((match) => match.isReady);
      final result = preliminary.copyWith(
        winnerEntryId: preliminary.player1Id,
      );
      TournamentBracket.advanceWinner(matches, preliminary, result);
      expect(
        matches
            .where((match) => match.round == 2)
            .every((match) => match.isReady),
        isTrue,
      );
    });

    test('wins a best-of-three match by winning two sets', () {
      var match = const TournamentMatch(
        id: 'match-1',
        round: 1,
        matchNumber: 1,
        player1Id: 'player-1',
        player2Id: 'player-2',
      );
      match = TournamentScoring.recordPoint(
        match,
        entryId: 'player-1',
        method: 'normal',
        raceTo: 1,
        setsToPlay: 3,
      );
      expect(match.sets1, 1);
      expect(match.score1, 0);
      expect(match.winnerEntryId, isNull);

      match = TournamentScoring.recordPoint(
        match,
        entryId: 'player-2',
        method: 'normal',
        raceTo: 1,
        setsToPlay: 3,
      );
      match = TournamentScoring.recordPoint(
        match,
        entryId: 'player-1',
        method: 'golden_break',
        raceTo: 1,
        setsToPlay: 3,
      );

      expect(match.sets1, 2);
      expect(match.sets2, 1);
      expect(match.winnerEntryId, 'player-1');
      expect(match.points.map((point) => point.setNumber).toSet(), {1, 2, 3});
    });

    test('undo restores the prior game and set score', () {
      var match = const TournamentMatch(
        id: 'match-1',
        round: 1,
        matchNumber: 1,
        player1Id: 'player-1',
        player2Id: 'player-2',
      );
      match = TournamentScoring.recordPoint(
        match,
        entryId: 'player-1',
        method: 'normal',
        raceTo: 1,
        setsToPlay: 1,
      );
      final restored = TournamentScoring.undoPoint(
        match,
        entryId: 'player-1',
        raceTo: 1,
        setsToPlay: 1,
      );

      expect(restored.sets1, 0);
      expect(restored.score1, 0);
      expect(restored.winnerEntryId, isNull);
      expect(restored.points, isEmpty);
    });

    test('calculates player tournament stats and placement', () {
      final entries = [
        const TournamentEntry(id: 'player-1', name: 'Ana'),
        const TournamentEntry(id: 'player-2', name: 'Luis'),
      ];
      final completeMatch = TournamentScoring.recordPoint(
        const TournamentMatch(
          id: 'match-1',
          round: 1,
          matchNumber: 1,
          player1Id: 'player-1',
          player2Id: 'player-2',
        ),
        entryId: 'player-1',
        method: 'break_and_run',
        raceTo: 1,
        setsToPlay: 1,
      );
      final tournament = TournamentEntity(
        id: 'tournament-1',
        billarId: 'billar-1',
        name: 'COPA',
        format: 'single',
        capacity: 2,
        entries: entries,
        matches: [completeMatch],
        createdAt: '',
        updatedAt: '',
      );

      final history = TournamentPlayerHistory.fromTournament(
        tournament,
        entries.first,
      );

      expect(history.matchesPlayed, 1);
      expect(history.matchesWon, 1);
      expect(history.gamesWon, 1);
      expect(history.breakAndRuns, 1);
      expect(history.placement, 'CAMPEÓN');
    });

    test(
      'counts individual games and victory methods across tournament rounds',
      () {
        const player1 = TournamentEntry(id: 'player-1', name: 'Ana');
        const player2 = TournamentEntry(id: 'player-2', name: 'Luis');
        final firstMatch = TournamentScoring.rebuild(
          const TournamentMatch(
            id: 'match-1',
            round: 1,
            matchNumber: 1,
            player1Id: 'player-1',
            player2Id: 'player-2',
          ),
          const [
            TournamentPoint(entryId: 'player-1', method: 'normal'),
            TournamentPoint(entryId: 'player-2', method: 'normal'),
            TournamentPoint(entryId: 'player-1', method: 'combination'),
            TournamentPoint(entryId: 'player-1', method: 'fouls'),
          ],
          raceTo: 3,
          setsToPlay: 1,
        );
        final finalMatch = TournamentScoring.rebuild(
          const TournamentMatch(
            id: 'match-2',
            round: 2,
            matchNumber: 1,
            player1Id: 'player-1',
            player2Id: 'player-2',
          ),
          const [
            TournamentPoint(entryId: 'player-1', method: 'golden_break'),
            TournamentPoint(entryId: 'player-2', method: 'normal'),
            TournamentPoint(entryId: 'player-1', method: 'break_and_run'),
            TournamentPoint(entryId: 'player-2', method: 'normal'),
            TournamentPoint(entryId: 'player-1', method: 'run_out'),
          ],
          raceTo: 3,
          setsToPlay: 1,
        );
        final tournament = TournamentEntity(
          id: 'tournament-1',
          billarId: 'billar-1',
          name: 'COPA',
          format: 'single',
          capacity: 2,
          entries: const [player1, player2],
          matches: [firstMatch, finalMatch],
          isActive: false,
          createdAt: '',
          updatedAt: '',
        );

        final history = TournamentPlayerHistory.fromTournament(
          tournament,
          player1,
        );

        expect(history.gamesWon + history.gamesLost, 9);
        expect(history.gamesWon, 6);
        expect(history.gamesLost, 3);
        expect(history.normalWins, 1);
        expect(history.combinations, 1);
        expect(history.winsByFouls, 1);
        expect(history.goldenBreaks, 1);
        expect(history.breakAndRuns, 2);
        expect(
          (history.gamesWon / (history.gamesWon + history.gamesLost) * 100)
              .toStringAsFixed(1),
          '66.7',
        );
      },
    );

    test(
      'creates a complete round-robin calendar that survives local caching',
      () {
        final entries = List.generate(
          4,
          (index) =>
              TournamentEntry(id: 'player-$index', name: 'Jugador $index'),
        );
        final matches = TournamentSchedule.createRoundRobin(entries);

        expect(matches, hasLength(6));
        expect(matches.map((match) => match.round).toSet(), {1, 2, 3});
        expect(
          matches
              .expand((match) => [match.player1Id, match.player2Id])
              .toList(),
          hasLength(12),
        );
        for (final entry in entries) {
          expect(
            matches
                .where(
                  (match) =>
                      match.player1Id == entry.id ||
                      match.player2Id == entry.id,
                )
                .length,
            3,
          );
        }

        for (var index = 0; index < matches.length; index++) {
          final match = matches[index];
          final winnerId =
              match.player1Id!.compareTo(match.player2Id!) < 0
                  ? match.player1Id!
                  : match.player2Id!;
          matches[index] = TournamentScoring.recordPoint(
            match,
            entryId: winnerId,
            method: 'normal',
            raceTo: 1,
            setsToPlay: 1,
          );
        }
        final tournament = TournamentEntity(
          id: 'league-1',
          billarId: 'billar-1',
          name: 'LIGA SEMANAL',
          format: 'liga',
          capacity: 4,
          entries: entries,
          matches: matches,
          createdAt: '',
          updatedAt: '',
        );
        final restored = TournamentEntity.fromLocalMap(tournament.toLocalMap());

        expect(restored.matches, hasLength(6));
        expect(restored.matches.map((match) => match.round).toSet(), {1, 2, 3});
        expect(
          restored.matches.every((match) => match.stage == 'league'),
          isTrue,
        );
        expect(restored.matches.first.winnerEntryId, isNotNull);
        expect(restored.isComplete, isTrue);
        expect(restored.championEntryId, 'player-0');
        expect(restored.standings.first.entry.id, 'player-0');
      },
    );

    test(
      'qualifies the top eight from round robin to finals and third place',
      () {
        final entries = List.generate(
          12,
          (index) =>
              TournamentEntry(id: 'player-$index', name: 'Jugador $index'),
        );
        final leagueMatches =
            TournamentSchedule.createRoundRobin(entries)
                .map(
                  (match) =>
                      match.copyWith(winnerEntryId: match.player1Id, sets1: 1),
                )
                .toList();

        final playoff = TournamentSchedule.createLeaguePlayoff(
          entries,
          leagueMatches,
          qualifiers: 8,
        );
        final bracket = playoff.where((match) => match.stage == 'playoff');
        final thirdPlace = playoff.singleWhere(
          (match) => match.stage == 'third_place',
        );
        final qualifiedIds =
            TournamentStandings.calculate(
              entries,
              leagueMatches,
              stage: 'league',
              entryIds: entries.map((entry) => entry.id),
            ).take(8).map((standing) => standing.entry.id).toSet();
        final firstRoundIds =
            bracket
                .where((match) => match.round == 1)
                .expand((match) => [match.player1Id!, match.player2Id!])
                .toSet();

        expect(bracket, hasLength(7));
        expect(bracket.where((match) => match.round == 1), hasLength(4));
        expect(bracket.where((match) => match.round == 2), hasLength(2));
        expect(bracket.where((match) => match.round == 3), hasLength(1));
        expect(firstRoundIds, qualifiedIds);
        expect(thirdPlace.round, 3);
        expect(thirdPlace.isReady, isFalse);
      },
    );

    test('groups four-player pools and qualifies the top two from each', () {
      final entries = List.generate(
        8,
        (index) => TournamentEntry(id: 'player-$index', name: 'Jugador $index'),
      );
      final matches = TournamentSchedule.createGroups(entries);
      for (var index = 0; index < matches.length; index++) {
        final match = matches[index];
        final winner =
            match.matchNumber.isEven ? match.player2Id! : match.player1Id!;
        matches[index] = TournamentScoring.recordPoint(
          match,
          entryId: winner,
          method: 'normal',
          raceTo: 1,
          setsToPlay: 1,
        );
      }

      final qualifiers = TournamentSchedule.groupQualifiers(entries, matches);

      expect(matches, hasLength(12));
      expect(matches.map((match) => match.groupNumber).toSet(), {1, 2});
      expect(qualifiers, hasLength(4));
      expect(qualifiers.map((entry) => entry.id).toSet(), hasLength(4));
      expect(
        TournamentStandings.calculate(
          entries,
          matches,
          stage: 'groups',
          groupNumber: 1,
        ),
        hasLength(4),
      );
    });

    test('creates Swiss rounds without repeating earlier opponents', () {
      final entries = List.generate(
        8,
        (index) => TournamentEntry(id: 'player-$index', name: 'Jugador $index'),
      );
      final matches = TournamentSchedule.createSwissRound(
        entries,
        const [],
        round: 1,
      );
      for (var round = 1; round <= 3; round++) {
        for (var index = 0; index < matches.length; index++) {
          final match = matches[index];
          if (match.round != round || match.isBye || match.isComplete) continue;
          matches[index] = TournamentScoring.recordPoint(
            match,
            entryId: match.player1Id!,
            method: 'normal',
            raceTo: 1,
            setsToPlay: 1,
          );
        }
        if (round < 3) {
          matches.addAll(
            TournamentSchedule.createSwissRound(
              entries,
              matches,
              round: round + 1,
            ),
          );
        }
      }

      final opponents = <String>{};
      for (final match in matches) {
        if (!match.isReady) continue;
        final pair = [match.player1Id!, match.player2Id!]..sort();
        expect(opponents.add(pair.join('|')), isTrue);
      }
      expect(TournamentSchedule.swissRoundCount(entries.length), 3);
      expect(
        TournamentEntity(
          id: 'swiss-1',
          billarId: 'billar-1',
          name: 'SUIZO',
          format: 'swiss',
          capacity: 8,
          entries: entries,
          matches: matches,
          createdAt: '',
          updatedAt: '',
        ).isComplete,
        isTrue,
      );
    });

    test('double elimination ends in one final without a reset match', () {
      final entries = List.generate(
        8,
        (index) => TournamentEntry(id: 'player-$index', name: 'Jugador $index'),
      );
      final matches = <TournamentMatch>[];
      var round = 1;
      matches.addAll(
        TournamentSchedule.createDoubleRound(
          entries,
          matches,
          round: round,
          random: Random(18),
        ),
      );

      while (!matches.any((match) => match.stage == 'double_final') &&
          round < 20) {
        for (var index = 0; index < matches.length; index++) {
          final match = matches[index];
          if (match.round != round ||
              !match.stage.startsWith('double_') ||
              match.stage == 'double_final' ||
              !match.isReady ||
              match.isComplete) {
            continue;
          }
          matches[index] = TournamentScoring.recordPoint(
            match,
            entryId: match.player1Id!,
            method: 'normal',
            raceTo: 1,
            setsToPlay: 1,
          );
        }
        round++;
        matches.addAll(
          TournamentSchedule.createDoubleRound(
            entries,
            matches,
            round: round,
            random: Random(round),
          ),
        );
      }

      final finals = matches.where((match) => match.stage == 'double_final');
      expect(finals, hasLength(1));
      final finalIndex = matches.indexOf(finals.single);
      matches[finalIndex] = TournamentScoring.recordPoint(
        finals.single,
        entryId: finals.single.player1Id!,
        method: 'normal',
        raceTo: 1,
        setsToPlay: 1,
      );
      final tournament = TournamentEntity(
        id: 'double-1',
        billarId: 'billar-1',
        name: 'DOBLE',
        format: 'double',
        capacity: 8,
        entries: entries,
        matches: matches,
        createdAt: '',
        updatedAt: '',
      );

      expect(tournament.isComplete, isTrue);
      expect(tournament.championEntryId, finals.single.player1Id);
      expect(
        matches.where((match) => match.stage == 'double_final'),
        hasLength(1),
      );
    });
  });
}
