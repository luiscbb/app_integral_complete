import 'dart:convert';
import 'dart:math';

import 'package:intl/intl.dart';

String formatTournamentMoney(num amount) =>
    '${NumberFormat.currency(locale: 'es_MX', symbol: '\$').format(amount)} MXN';

class TournamentEntry {
  final String id;
  final String name;
  final String nickname;
  final String avatar;
  final String playerCode;
  final String? registeredPlayerId;
  final int handicap;
  final bool isGuest;

  const TournamentEntry({
    required this.id,
    required this.name,
    this.nickname = '',
    this.avatar = '',
    this.playerCode = '',
    this.registeredPlayerId,
    this.handicap = 1,
    this.isGuest = false,
  });

  String get displayName => (nickname.isEmpty ? name : nickname).toUpperCase();

  TournamentEntry copyWith({String? avatar}) => TournamentEntry(
    id: id,
    name: name,
    nickname: nickname,
    avatar: avatar ?? this.avatar,
    playerCode: playerCode,
    registeredPlayerId: registeredPlayerId,
    handicap: handicap,
    isGuest: isGuest,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name.toUpperCase(),
    'nickname': nickname.toUpperCase(),
    'avatar': avatar,
    'player_code': playerCode,
    'registered_player_id': registeredPlayerId,
    'handicap': handicap,
    'is_guest': isGuest,
  };

  factory TournamentEntry.fromMap(Map<String, dynamic> map) => TournamentEntry(
    id: map['id']?.toString() ?? '',
    name: (map['name']?.toString() ?? '').toUpperCase(),
    nickname: (map['nickname']?.toString() ?? '').toUpperCase(),
    avatar: map['avatar']?.toString() ?? '',
    playerCode: map['player_code']?.toString() ?? '',
    registeredPlayerId: map['registered_player_id']?.toString(),
    handicap: (map['handicap'] as num?)?.toInt() ?? 1,
    isGuest: map['is_guest'] == true || map['is_guest'] == 1,
  );
}

class TournamentPoint {
  final String entryId;
  final String method;
  final int setNumber;

  const TournamentPoint({
    required this.entryId,
    required this.method,
    this.setNumber = 1,
  });

  Map<String, dynamic> toMap() => {
    'entry_id': entryId,
    'method': method,
    'set_number': setNumber,
  };

  factory TournamentPoint.fromMap(Map<String, dynamic> map) => TournamentPoint(
    entryId: map['entry_id']?.toString() ?? '',
    method: map['method']?.toString() ?? 'normal',
    setNumber: (map['set_number'] as num?)?.toInt() ?? 1,
  );
}

class TournamentScoring {
  static TournamentMatch recordPoint(
    TournamentMatch match, {
    required String entryId,
    required String method,
    required int raceTo,
    required int setsToPlay,
  }) {
    final points = [
      ...match.points,
      TournamentPoint(
        entryId: entryId,
        method: method,
        setNumber: match.sets1 + match.sets2 + 1,
      ),
    ];
    return rebuild(match, points, raceTo: raceTo, setsToPlay: setsToPlay);
  }

  static TournamentMatch undoPoint(
    TournamentMatch match, {
    required String entryId,
    required int raceTo,
    required int setsToPlay,
  }) {
    final index = match.points.lastIndexWhere(
      (point) => point.entryId == entryId,
    );
    if (index < 0) {
      throw StateError('No hay una partida de ese jugador para deshacer.');
    }
    final points = [...match.points]..removeAt(index);
    return rebuild(match, points, raceTo: raceTo, setsToPlay: setsToPlay);
  }

  static TournamentMatch rebuild(
    TournamentMatch match,
    List<TournamentPoint> points, {
    required int raceTo,
    required int setsToPlay,
  }) {
    var score1 = 0;
    var score2 = 0;
    var sets1 = 0;
    var sets2 = 0;
    String? winner;
    final normalizedPoints = <TournamentPoint>[];

    for (final point in points) {
      if (winner != null) {
        throw StateError(
          'No se puede registrar una partida después de terminar el enfrentamiento.',
        );
      }
      if (point.entryId != match.player1Id &&
          point.entryId != match.player2Id) {
        throw StateError('El jugador no pertenece a este enfrentamiento.');
      }
      final setNumber = sets1 + sets2 + 1;
      normalizedPoints.add(
        TournamentPoint(
          entryId: point.entryId,
          method: point.method,
          setNumber: setNumber,
        ),
      );
      if (match.player1Id == point.entryId) {
        score1++;
      } else {
        score2++;
      }
      if (score1 >= raceTo) {
        sets1++;
        score1 = 0;
        score2 = 0;
      } else if (score2 >= raceTo) {
        sets2++;
        score1 = 0;
        score2 = 0;
      }
      final setsNeeded = (setsToPlay ~/ 2) + 1;
      if (sets1 >= setsNeeded) {
        winner = match.player1Id;
      } else if (sets2 >= setsNeeded) {
        winner = match.player2Id;
      }
    }

    return match.copyWith(
      score1: score1,
      score2: score2,
      sets1: sets1,
      sets2: sets2,
      winnerEntryId: winner,
      points: normalizedPoints,
    );
  }
}

class TournamentMatch {
  final String id;
  final int round;
  final int matchNumber;
  final String stage;
  final int? groupNumber;
  final String? player1Id;
  final String? player2Id;
  final int score1;
  final int score2;
  final int sets1;
  final int sets2;
  final String? winnerEntryId;
  final List<TournamentPoint> points;

  const TournamentMatch({
    required this.id,
    required this.round,
    required this.matchNumber,
    this.stage = 'bracket',
    this.groupNumber,
    this.player1Id,
    this.player2Id,
    this.score1 = 0,
    this.score2 = 0,
    this.sets1 = 0,
    this.sets2 = 0,
    this.winnerEntryId,
    this.points = const [],
  });

  bool get isBye => (player1Id == null) != (player2Id == null);
  bool get isReady => player1Id != null && player2Id != null;
  bool get isComplete => winnerEntryId != null;

  int? scoreFor(String entryId) {
    if (player1Id == entryId) return score1;
    if (player2Id == entryId) return score2;
    return null;
  }

  int? setsFor(String entryId) {
    if (player1Id == entryId) return sets1;
    if (player2Id == entryId) return sets2;
    return null;
  }

  TournamentMatch copyWith({
    Object? player1Id = _unset,
    Object? player2Id = _unset,
    Object? winnerEntryId = _unset,
    int? groupNumber,
    String? stage,
    int? score1,
    int? score2,
    int? sets1,
    int? sets2,
    List<TournamentPoint>? points,
  }) => TournamentMatch(
    id: id,
    round: round,
    matchNumber: matchNumber,
    stage: stage ?? this.stage,
    groupNumber: groupNumber ?? this.groupNumber,
    player1Id:
        identical(player1Id, _unset) ? this.player1Id : player1Id as String?,
    player2Id:
        identical(player2Id, _unset) ? this.player2Id : player2Id as String?,
    score1: score1 ?? this.score1,
    score2: score2 ?? this.score2,
    sets1: sets1 ?? this.sets1,
    sets2: sets2 ?? this.sets2,
    winnerEntryId:
        identical(winnerEntryId, _unset)
            ? this.winnerEntryId
            : winnerEntryId as String?,
    points: points ?? this.points,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'round': round,
    'match_number': matchNumber,
    'stage': stage,
    'group_number': groupNumber,
    'player1_id': player1Id,
    'player2_id': player2Id,
    'score1': score1,
    'score2': score2,
    'sets1': sets1,
    'sets2': sets2,
    'winner_entry_id': winnerEntryId,
    'points': points.map((point) => point.toMap()).toList(),
  };

  factory TournamentMatch.fromMap(Map<String, dynamic> map) {
    final rawPoints = map['points'];
    return TournamentMatch(
      id: map['id']?.toString() ?? '',
      round: (map['round'] as num?)?.toInt() ?? 1,
      matchNumber: (map['match_number'] as num?)?.toInt() ?? 1,
      stage: map['stage']?.toString() ?? 'bracket',
      groupNumber: (map['group_number'] as num?)?.toInt(),
      player1Id: map['player1_id']?.toString(),
      player2Id: map['player2_id']?.toString(),
      score1: (map['score1'] as num?)?.toInt() ?? 0,
      score2: (map['score2'] as num?)?.toInt() ?? 0,
      sets1: (map['sets1'] as num?)?.toInt() ?? 0,
      sets2: (map['sets2'] as num?)?.toInt() ?? 0,
      winnerEntryId: map['winner_entry_id']?.toString(),
      points:
          rawPoints is List
              ? rawPoints
                  .whereType<Map>()
                  .map(
                    (point) => TournamentPoint.fromMap(
                      Map<String, dynamic>.from(point),
                    ),
                  )
                  .toList()
              : const [],
    );
  }
}

class TournamentBracket {
  static List<TournamentMatch> create(
    List<TournamentEntry> entries, {
    Random? random,
    bool shuffle = true,
    String stage = 'bracket',
    String idPrefix = 'match',
  }) {
    if (entries.length < 2) {
      throw StateError(
        'Se necesitan al menos dos jugadores para generar el cuadro.',
      );
    }

    final seeded = entries.toList();
    if (shuffle) seeded.shuffle(random ?? Random.secure());
    var bracketSize = 1;
    while (bracketSize < seeded.length) {
      bracketSize *= 2;
    }
    final roundCount = bracketSize.bitLength - 1;
    final matches = <TournamentMatch>[];
    var id = 0;

    for (var round = 1; round <= roundCount; round++) {
      final matchCount = bracketSize >> round;
      for (var matchNumber = 1; matchNumber <= matchCount; matchNumber++) {
        String? player1Id;
        String? player2Id;
        if (round == 1) {
          final index = (matchNumber - 1) * 2;
          player1Id = index < seeded.length ? seeded[index].id : null;
          player2Id = index + 1 < seeded.length ? seeded[index + 1].id : null;
        }
        final winnerId =
            player1Id == null
                ? player2Id
                : player2Id == null
                ? player1Id
                : null;
        matches.add(
          TournamentMatch(
            id: '$idPrefix-${++id}',
            round: round,
            matchNumber: matchNumber,
            stage: stage,
            player1Id: player1Id,
            player2Id: player2Id,
            winnerEntryId: winnerId,
          ),
        );
      }
    }

    for (var round = 1; round < roundCount; round++) {
      final currentIndexes =
          List.generate(
            matches.length,
            (index) => index,
          ).where((index) => matches[index].round == round).toList();
      for (final index in currentIndexes) {
        var match = matches[index];
        if (match.isBye && match.winnerEntryId == null) {
          match = match.copyWith(
            winnerEntryId: match.player1Id ?? match.player2Id,
          );
          matches[index] = match;
        }
        final winnerId = match.winnerEntryId;
        if (winnerId == null) continue;
        final nextIndex = matches.indexWhere(
          (next) =>
              next.round == round + 1 &&
              next.matchNumber == ((match.matchNumber + 1) ~/ 2),
        );
        if (nextIndex == -1) continue;
        final next = matches[nextIndex];
        matches[nextIndex] =
            match.matchNumber.isOdd
                ? next.copyWith(player1Id: winnerId)
                : next.copyWith(player2Id: winnerId);
      }
    }
    return matches;
  }

  static void advanceWinner(
    List<TournamentMatch> matches,
    TournamentMatch previous,
    TournamentMatch updated,
  ) {
    if (previous.winnerEntryId == updated.winnerEntryId) return;
    final nextIndex = matches.indexWhere(
      (match) =>
          match.stage == updated.stage &&
          match.round == updated.round + 1 &&
          match.matchNumber == (updated.matchNumber + 1) ~/ 2,
    );
    if (nextIndex < 0) return;

    final next = matches[nextIndex];
    final firstSlot = updated.matchNumber.isOdd;
    final currentSlot = firstSlot ? next.player1Id : next.player2Id;
    if (currentSlot != previous.winnerEntryId) {
      throw StateError(
        'No se pudo actualizar la llave. Actualiza el torneo e inténtalo de nuevo.',
      );
    }
    if ((next.score1 != 0 || next.score2 != 0 || next.points.isNotEmpty) &&
        previous.winnerEntryId != updated.winnerEntryId) {
      throw StateError(
        'No se puede corregir este marcador porque la siguiente ronda ya comenzó.',
      );
    }

    final player1Id = firstSlot ? updated.winnerEntryId : next.player1Id;
    final player2Id = firstSlot ? next.player2Id : updated.winnerEntryId;
    final replacement = next.copyWith(
      player1Id: player1Id,
      player2Id: player2Id,
      winnerEntryId: null,
    );
    matches[nextIndex] = replacement;
    advanceWinner(matches, next, replacement);
  }
}

class TournamentStanding {
  final TournamentEntry entry;
  final int matchesPlayed;
  final int matchesWon;
  final int matchesLost;
  final int gamesWon;
  final int gamesLost;
  final int setsWon;
  final int setsLost;

  const TournamentStanding({
    required this.entry,
    required this.matchesPlayed,
    required this.matchesWon,
    required this.matchesLost,
    required this.gamesWon,
    required this.gamesLost,
    required this.setsWon,
    required this.setsLost,
  });

  int get gameDifference => gamesWon - gamesLost;
  int get setDifference => setsWon - setsLost;
  int get points => matchesWon * 3;
}

class TournamentStandings {
  static List<TournamentStanding> calculate(
    List<TournamentEntry> entries,
    List<TournamentMatch> matches, {
    String? stage,
    int? groupNumber,
    Iterable<String>? entryIds,
  }) {
    final relevantMatches = matches.where(
      (match) =>
          (stage == null || match.stage == stage) &&
          (groupNumber == null || match.groupNumber == groupNumber),
    );
    final ids =
        entryIds?.toSet() ??
        relevantMatches
            .expand((match) => [match.player1Id, match.player2Id])
            .whereType<String>()
            .toSet();
    final standings = [
      for (final entry in entries.where((entry) => ids.contains(entry.id)))
        _standingFor(entry, relevantMatches),
    ];
    standings.sort((left, right) {
      var result = right.points.compareTo(left.points);
      if (result != 0) return result;
      result = right.gameDifference.compareTo(left.gameDifference);
      if (result != 0) return result;
      result = _headToHead(right.entry.id, left.entry.id, relevantMatches);
      if (result != 0) return result;
      result = right.setDifference.compareTo(left.setDifference);
      if (result != 0) return result;
      return left.entry.displayName.compareTo(right.entry.displayName);
    });
    return standings;
  }

  static TournamentStanding _standingFor(
    TournamentEntry entry,
    Iterable<TournamentMatch> matches,
  ) {
    var matchesPlayed = 0;
    var matchesWon = 0;
    var matchesLost = 0;
    var gamesWon = 0;
    var gamesLost = 0;
    var setsWon = 0;
    var setsLost = 0;
    for (final match in matches) {
      if (match.winnerEntryId == null ||
          (match.player1Id != entry.id && match.player2Id != entry.id)) {
        continue;
      }
      if (match.isBye) {
        if (match.winnerEntryId == entry.id) {
          matchesPlayed++;
          matchesWon++;
        }
        continue;
      }
      if (!match.isReady) continue;
      matchesPlayed++;
      if (match.winnerEntryId == entry.id) {
        matchesWon++;
      } else {
        matchesLost++;
      }
      if (match.player1Id == entry.id) {
        gamesWon +=
            match.points.where((point) => point.entryId == entry.id).length;
        gamesLost +=
            match.points
                .where((point) => point.entryId == match.player2Id)
                .length;
        setsWon += match.sets1;
        setsLost += match.sets2;
      } else {
        gamesWon +=
            match.points.where((point) => point.entryId == entry.id).length;
        gamesLost +=
            match.points
                .where((point) => point.entryId == match.player1Id)
                .length;
        setsWon += match.sets2;
        setsLost += match.sets1;
      }
    }
    return TournamentStanding(
      entry: entry,
      matchesPlayed: matchesPlayed,
      matchesWon: matchesWon,
      matchesLost: matchesLost,
      gamesWon: gamesWon,
      gamesLost: gamesLost,
      setsWon: setsWon,
      setsLost: setsLost,
    );
  }

  static int _headToHead(
    String firstId,
    String secondId,
    Iterable<TournamentMatch> matches,
  ) {
    for (final match in matches) {
      if (match.winnerEntryId == null ||
          !((match.player1Id == firstId && match.player2Id == secondId) ||
              (match.player1Id == secondId && match.player2Id == firstId))) {
        continue;
      }
      if (match.winnerEntryId == firstId) return 1;
      if (match.winnerEntryId == secondId) return -1;
    }
    return 0;
  }

  static int compareHeadToHead(
    String firstId,
    String secondId,
    Iterable<TournamentMatch> matches,
  ) => _headToHead(firstId, secondId, matches);

  static int groupForEntry(String entryId, List<TournamentMatch> matches) {
    for (final match in matches) {
      if (match.stage == 'groups' &&
          match.groupNumber != null &&
          (match.player1Id == entryId || match.player2Id == entryId)) {
        return match.groupNumber!;
      }
    }
    return 0;
  }
}

class TournamentSchedule {
  static List<TournamentMatch> createRoundRobin(
    List<TournamentEntry> entries, {
    String stage = 'league',
    int? groupNumber,
    String idPrefix = 'league',
    int roundOffset = 0,
  }) {
    if (entries.length < 2) {
      throw StateError(
        'Se necesitan al menos dos jugadores para generar jornadas.',
      );
    }
    final rotation = <TournamentEntry?>[...entries];
    if (rotation.length.isOdd) rotation.add(null);
    final matches = <TournamentMatch>[];
    final roundCount = rotation.length - 1;
    for (var round = 1; round <= roundCount; round++) {
      for (var index = 0; index < rotation.length ~/ 2; index++) {
        final first = rotation[index];
        final second = rotation[rotation.length - 1 - index];
        if (first == null || second == null) continue;
        final player1 = (round + index).isOdd ? first : second;
        final player2 = identical(player1, first) ? second : first;
        matches.add(
          TournamentMatch(
            id: '$idPrefix-r${round + roundOffset}-m${index + 1}',
            round: round + roundOffset,
            matchNumber: index + 1,
            stage: stage,
            groupNumber: groupNumber,
            player1Id: player1.id,
            player2Id: player2.id,
          ),
        );
      }
      final fixed = rotation.first;
      final rest = rotation.skip(1).toList();
      rest.insert(0, rest.removeLast());
      rotation
        ..clear()
        ..add(fixed)
        ..addAll(rest);
    }
    return matches;
  }

  static List<TournamentMatch> createGroups(List<TournamentEntry> entries) {
    if (entries.length < 3) {
      throw StateError(
        'El formato de grupos requiere al menos tres jugadores.',
      );
    }
    final groupCount = (entries.length / 4).ceil();
    final baseSize = entries.length ~/ groupCount;
    final largerGroupCount = entries.length % groupCount;
    final groups = <List<TournamentEntry>>[];
    var offset = 0;
    for (var index = 0; index < groupCount; index++) {
      final size = baseSize + (index < largerGroupCount ? 1 : 0);
      groups.add(entries.sublist(offset, offset + size));
      offset += size;
    }
    return [
      for (var index = 0; index < groups.length; index++)
        ...createRoundRobin(
          groups[index],
          stage: 'groups',
          groupNumber: index + 1,
          idPrefix: 'group-${index + 1}',
        ),
    ];
  }

  static List<TournamentMatch> createLeaguePlayoff(
    List<TournamentEntry> entries,
    List<TournamentMatch> leagueMatches, {
    required int qualifiers,
  }) {
    if (entries.length < qualifiers) {
      throw StateError(
        'Se requieren al menos $qualifiers jugadores inscritos para clasificar a finales.',
      );
    }
    if (leagueMatches.isEmpty ||
        leagueMatches.any((match) => !match.isComplete)) {
      throw StateError(
        'Completa todas las jornadas antes de sortear las finales.',
      );
    }
    final ordered = TournamentStandings.calculate(
      entries,
      leagueMatches,
      stage: 'league',
      entryIds: entries.map((entry) => entry.id),
    );
    final qualifiedEntries =
        ordered.take(qualifiers).map((standing) => standing.entry).toList();
    final bracket = TournamentBracket.create(
      qualifiedEntries,
      stage: 'playoff',
      idPrefix: 'playoff',
    );
    final finalRound = bracket.fold<int>(
      0,
      (latest, match) => latest > match.round ? latest : match.round,
    );
    bracket.add(
      TournamentMatch(
        id: 'playoff-third-place',
        round: finalRound,
        matchNumber: 1,
        stage: 'third_place',
      ),
    );
    return bracket;
  }

  static List<TournamentEntry> groupQualifiers(
    List<TournamentEntry> entries,
    List<TournamentMatch> matches,
  ) {
    final groupNumbers =
        matches
            .where((match) => match.stage == 'groups')
            .map((match) => match.groupNumber)
            .whereType<int>()
            .toSet()
            .toList()
          ..sort();
    final standingsByGroup = {
      for (final group in groupNumbers)
        group: TournamentStandings.calculate(
          entries,
          matches,
          stage: 'groups',
          groupNumber: group,
        ),
    };
    final ordered = <TournamentEntry>[];
    for (final group in groupNumbers) {
      final standings = standingsByGroup[group]!;
      if (standings.isNotEmpty) ordered.add(standings.first.entry);
      if (standings.length > 1) ordered.add(standings[1].entry);
    }
    if (groupNumbers.length > 1) {
      final crossGroupOrder = <TournamentEntry>[];
      for (var index = 0; index < groupNumbers.length; index++) {
        final current = standingsByGroup[groupNumbers[index]]!;
        final next =
            standingsByGroup[groupNumbers[(index + 1) % groupNumbers.length]]!;
        if (current.isNotEmpty) crossGroupOrder.add(current.first.entry);
        if (next.length > 1) crossGroupOrder.add(next[1].entry);
      }
      return crossGroupOrder.toSet().length == crossGroupOrder.length
          ? crossGroupOrder
          : ordered;
    }
    return ordered;
  }

  static List<TournamentMatch> createSwissRound(
    List<TournamentEntry> entries,
    List<TournamentMatch> previousMatches, {
    required int round,
  }) {
    final standings = TournamentStandings.calculate(
      entries,
      previousMatches,
      stage: 'swiss',
      entryIds: entries.map((entry) => entry.id),
    );
    final remaining = standings.map((standing) => standing.entry).toList();
    final matches = <TournamentMatch>[];
    var matchNumber = 0;
    while (remaining.length > 1) {
      final first = remaining.removeAt(0);
      var opponentIndex = remaining.indexWhere(
        (candidate) => !_havePlayed(first.id, candidate.id, previousMatches),
      );
      if (opponentIndex < 0) opponentIndex = 0;
      final second = remaining.removeAt(opponentIndex);
      matchNumber++;
      matches.add(
        TournamentMatch(
          id: 'swiss-r$round-m$matchNumber',
          round: round,
          matchNumber: matchNumber,
          stage: 'swiss',
          player1Id: first.id,
          player2Id: second.id,
        ),
      );
    }
    if (remaining.isNotEmpty) {
      final byeEntry = remaining.single;
      matchNumber++;
      matches.add(
        TournamentMatch(
          id: 'swiss-r$round-bye',
          round: round,
          matchNumber: matchNumber,
          stage: 'swiss',
          player1Id: byeEntry.id,
          winnerEntryId: byeEntry.id,
        ),
      );
    }
    return matches;
  }

  static List<TournamentMatch> createDoubleRound(
    List<TournamentEntry> entries,
    List<TournamentMatch> previousMatches, {
    required int round,
    Random? random,
  }) {
    final losses = <String, int>{for (final entry in entries) entry.id: 0};
    for (final match in previousMatches.where(
      (match) =>
          match.stage.startsWith('double_') &&
          match.stage != 'double_final' &&
          match.isReady &&
          match.winnerEntryId != null,
    )) {
      final loserId =
          match.winnerEntryId == match.player1Id
              ? match.player2Id
              : match.player1Id;
      if (loserId != null) losses.update(loserId, (value) => value + 1);
    }
    final undefeated =
        entries.where((entry) => losses[entry.id] == 0).toList()
          ..shuffle(random);
    final oneLoss =
        entries.where((entry) => losses[entry.id] == 1).toList()
          ..shuffle(random);
    if (undefeated.length == 1 && oneLoss.length == 1) {
      return [
        TournamentMatch(
          id: 'double-final-r$round',
          round: round,
          matchNumber: 1,
          stage: 'double_final',
          player1Id: undefeated.single.id,
          player2Id: oneLoss.single.id,
        ),
      ];
    }

    final matches = <TournamentMatch>[];
    void addPairings(List<TournamentEntry> pool, String stage) {
      for (var index = 0; index < pool.length; index += 2) {
        final first = pool[index];
        final second = index + 1 < pool.length ? pool[index + 1] : null;
        final number = matches.length + 1;
        matches.add(
          TournamentMatch(
            id: 'double-r$round-m$number',
            round: round,
            matchNumber: number,
            stage: stage,
            player1Id: first.id,
            player2Id: second?.id,
            winnerEntryId: second == null ? first.id : null,
          ),
        );
      }
    }

    addPairings(undefeated, 'double_winners');
    addPairings(oneLoss, 'double_losers');
    return matches;
  }

  static int swissRoundCount(int entryCount) {
    if (entryCount < 2) return 0;
    var count = 1;
    var bracketSize = 2;
    while (bracketSize < entryCount) {
      bracketSize <<= 1;
      count++;
    }
    return count;
  }

  static bool _havePlayed(
    String firstId,
    String secondId,
    List<TournamentMatch> matches,
  ) => matches.any(
    (match) =>
        match.stage == 'swiss' &&
        ((match.player1Id == firstId && match.player2Id == secondId) ||
            (match.player1Id == secondId && match.player2Id == firstId)),
  );
}

const Object _unset = Object();

class TournamentPrize {
  final int place;
  final String type;
  final double value;

  const TournamentPrize({
    required this.place,
    required this.type,
    required this.value,
  });

  double amountFor(double prizePool) =>
      type == 'percentage' ? prizePool * value / 100 : value;

  Map<String, dynamic> toMap() => {
    'place': place,
    'type': type,
    'value': value,
  };

  factory TournamentPrize.fromMap(Map<String, dynamic> map) => TournamentPrize(
    place: (map['place'] as num?)?.toInt() ?? 1,
    type: map['type']?.toString() == 'percentage' ? 'percentage' : 'fixed',
    value: (map['value'] as num?)?.toDouble() ?? 0,
  );
}

class TournamentEntity {
  final String id;
  final String billarId;
  final String name;
  final String format;
  final int? capacity;
  final List<TournamentEntry> entries;
  final int raceTo;
  final int setsToPlay;
  final String gameType;
  final int playoffQualifiers;
  final double guaranteedPool;
  final double entryFee;
  final double timeFee;
  final List<TournamentPrize> prizes;
  final List<TournamentMatch> matches;
  final bool isActive;
  final String createdAt;
  final String updatedAt;

  const TournamentEntity({
    required this.id,
    required this.billarId,
    required this.name,
    required this.format,
    required this.capacity,
    required this.entries,
    this.raceTo = 3,
    this.setsToPlay = 1,
    this.gameType = 'Bola 9',
    this.playoffQualifiers = 0,
    this.guaranteedPool = 0,
    this.entryFee = 0,
    this.timeFee = 0,
    this.prizes = const [],
    this.matches = const [],
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isFull => capacity != null && entries.length >= capacity!;
  double get entryTotal => entryFee * entries.length;
  double get prizePool => guaranteedPool + entryTotal;
  int get completedMatches =>
      matches.where((match) => !match.isBye && match.isComplete).length;
  double get timeRevenue => completedMatches * timeFee;
  List<TournamentStanding> get standings => TournamentStandings.calculate(
    entries,
    matches,
    stage: format == 'liga' || format == 'league' ? 'league' : null,
  );

  TournamentMatch? get finalMatch {
    final isLeaguePlayoff =
        (format == 'liga' || format == 'league') && playoffQualifiers > 0;
    final finalStage =
        isLeaguePlayoff
            ? 'playoff'
            : switch (format) {
              'double' => 'double_final',
              'groups' => 'playoff',
              _ => 'bracket',
            };
    final candidates = matches.where((match) => match.stage == finalStage);
    if (candidates.isEmpty) return null;
    return candidates.reduce(
      (left, right) => left.round > right.round ? left : right,
    );
  }

  bool get isComplete {
    switch (format) {
      case 'league':
      case 'liga':
        final leagueMatches = matches.where((match) => match.stage == 'league');
        final leagueComplete =
            leagueMatches.isNotEmpty &&
            leagueMatches.every((match) => match.isBye || match.isComplete);
        if (!leagueComplete) return false;
        if (playoffQualifiers == 0) return true;
        final thirdPlaceMatch =
            matches.where((match) => match.stage == 'third_place').firstOrNull;
        return (finalMatch?.isComplete ?? false) &&
            (thirdPlaceMatch?.isComplete ?? false);
      case 'swiss':
        final expectedRounds = TournamentSchedule.swissRoundCount(
          entries.length,
        );
        final swissMatches = matches.where((match) => match.stage == 'swiss');
        final lastRound = swissMatches.fold<int>(
          0,
          (maxRound, match) => maxRound > match.round ? maxRound : match.round,
        );
        final finalRoundMatches = swissMatches.where(
          (match) => match.round == expectedRounds,
        );
        return expectedRounds > 0 &&
            lastRound == expectedRounds &&
            finalRoundMatches.isNotEmpty &&
            finalRoundMatches.every((match) => match.isBye || match.isComplete);
      case 'double':
      case 'groups':
      case 'single':
      default:
        return finalMatch?.isComplete ?? false;
    }
  }

  String? get championEntryId {
    if ((format == 'league' || format == 'liga') && playoffQualifiers > 0) {
      return isComplete ? finalMatch?.winnerEntryId : null;
    }
    if (format == 'league' || format == 'liga' || format == 'swiss') {
      if (!isComplete) return null;
      final ordered = standings;
      if (ordered.isEmpty) return null;
      return ordered.first.entry.id;
    }
    return finalMatch?.winnerEntryId;
  }

  String? get thirdPlaceEntryId =>
      matches
          .where((match) => match.stage == 'third_place')
          .firstOrNull
          ?.winnerEntryId;

  bool get hasChampion => championEntryId != null;

  String get enrollmentLabel =>
      capacity == null
          ? '${entries.length} inscritos · Abierto'
          : '${entries.length}/${capacity!}';

  Map<String, dynamic> toCloudMap() => {
    'billar_id': billarId,
    'name': name.toUpperCase(),
    'tournament_format': format,
    'capacity': capacity,
    'entries': entries.map((entry) => entry.toMap()).toList(),
    'race_to': raceTo,
    'sets_to_play': setsToPlay,
    'game_type': gameType,
    'playoff_qualifiers': playoffQualifiers,
    'guaranteed_pool': guaranteedPool,
    'entry_fee': entryFee,
    'time_fee': timeFee,
    'prizes': prizes.map((prize) => prize.toMap()).toList(),
    'matches': matches.map((match) => match.toMap()).toList(),
    'is_active': isActive,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  };

  Map<String, Object?> toLocalMap() => {
    'id': id,
    'billar_id': billarId,
    'name': name.toUpperCase(),
    'tournament_format': format,
    'capacity': capacity,
    'entries_json': jsonEncode(entries.map((entry) => entry.toMap()).toList()),
    'race_to': raceTo,
    'sets_to_play': setsToPlay,
    'game_type': gameType,
    'playoff_qualifiers': playoffQualifiers,
    'guaranteed_pool': guaranteedPool,
    'entry_fee': entryFee,
    'time_fee': timeFee,
    'prizes_json': jsonEncode(prizes.map((prize) => prize.toMap()).toList()),
    'matches_json': jsonEncode(matches.map((match) => match.toMap()).toList()),
    'is_active': isActive ? 1 : 0,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  factory TournamentEntity.fromCloudMap(Map<String, dynamic> map) {
    final rawEntries = map['entries'];
    final entries =
        rawEntries is List
            ? rawEntries
                .whereType<Map>()
                .map(
                  (entry) =>
                      TournamentEntry.fromMap(Map<String, dynamic>.from(entry)),
                )
                .toList()
            : <TournamentEntry>[];
    final rawMatches = map['matches'];
    final matches =
        rawMatches is List
            ? rawMatches
                .whereType<Map>()
                .map(
                  (match) =>
                      TournamentMatch.fromMap(Map<String, dynamic>.from(match)),
                )
                .toList()
            : <TournamentMatch>[];
    final rawPrizes = map['prizes'];
    final prizes =
        rawPrizes is List
            ? rawPrizes
                .whereType<Map>()
                .map(
                  (prize) =>
                      TournamentPrize.fromMap(Map<String, dynamic>.from(prize)),
                )
                .toList()
            : <TournamentPrize>[];
    return TournamentEntity(
      id: map['id']?.toString() ?? '',
      billarId: map['billar_id']?.toString() ?? '',
      name: (map['name']?.toString() ?? '').toUpperCase(),
      format: map['tournament_format']?.toString() ?? 'liga',
      capacity: (map['capacity'] as num?)?.toInt(),
      entries: entries,
      raceTo: (map['race_to'] as num?)?.toInt() ?? 3,
      setsToPlay: (map['sets_to_play'] as num?)?.toInt() ?? 1,
      gameType: map['game_type']?.toString() ?? 'Bola 9',
      playoffQualifiers: (map['playoff_qualifiers'] as num?)?.toInt() ?? 0,
      guaranteedPool: (map['guaranteed_pool'] as num?)?.toDouble() ?? 0,
      entryFee: (map['entry_fee'] as num?)?.toDouble() ?? 0,
      timeFee: (map['time_fee'] as num?)?.toDouble() ?? 0,
      prizes: prizes,
      matches: matches,
      isActive: map['is_active'] == true || map['is_active'] == 1,
      createdAt: map['created_at']?.toString() ?? '',
      updatedAt: map['updated_at']?.toString() ?? '',
    );
  }

  factory TournamentEntity.fromLocalMap(Map<String, Object?> map) {
    final decoded = jsonDecode(map['entries_json'] as String? ?? '[]');
    final entries =
        decoded is List
            ? decoded
                .whereType<Map>()
                .map(
                  (entry) =>
                      TournamentEntry.fromMap(Map<String, dynamic>.from(entry)),
                )
                .toList()
            : <TournamentEntry>[];
    final decodedMatches = jsonDecode(map['matches_json'] as String? ?? '[]');
    final matches =
        decodedMatches is List
            ? decodedMatches
                .whereType<Map>()
                .map(
                  (match) =>
                      TournamentMatch.fromMap(Map<String, dynamic>.from(match)),
                )
                .toList()
            : <TournamentMatch>[];
    final decodedPrizes = jsonDecode(map['prizes_json'] as String? ?? '[]');
    final prizes =
        decodedPrizes is List
            ? decodedPrizes
                .whereType<Map>()
                .map(
                  (prize) =>
                      TournamentPrize.fromMap(Map<String, dynamic>.from(prize)),
                )
                .toList()
            : <TournamentPrize>[];
    return TournamentEntity(
      id: map['id']?.toString() ?? '',
      billarId: map['billar_id']?.toString() ?? '',
      name: (map['name']?.toString() ?? '').toUpperCase(),
      format: map['tournament_format']?.toString() ?? 'liga',
      capacity: (map['capacity'] as num?)?.toInt(),
      entries: entries,
      raceTo: (map['race_to'] as num?)?.toInt() ?? 3,
      setsToPlay: (map['sets_to_play'] as num?)?.toInt() ?? 1,
      gameType: map['game_type']?.toString() ?? 'Bola 9',
      playoffQualifiers: (map['playoff_qualifiers'] as num?)?.toInt() ?? 0,
      guaranteedPool: (map['guaranteed_pool'] as num?)?.toDouble() ?? 0,
      entryFee: (map['entry_fee'] as num?)?.toDouble() ?? 0,
      timeFee: (map['time_fee'] as num?)?.toDouble() ?? 0,
      prizes: prizes,
      matches: matches,
      isActive: map['is_active'] == 1,
      createdAt: map['created_at']?.toString() ?? '',
      updatedAt: map['updated_at']?.toString() ?? '',
    );
  }

  TournamentEntity copyWith({
    List<TournamentEntry>? entries,
    int? raceTo,
    int? setsToPlay,
    String? gameType,
    int? playoffQualifiers,
    double? guaranteedPool,
    double? entryFee,
    double? timeFee,
    List<TournamentPrize>? prizes,
    List<TournamentMatch>? matches,
    bool? isActive,
  }) => TournamentEntity(
    id: id,
    billarId: billarId,
    name: name,
    format: format,
    capacity: capacity,
    entries: entries ?? this.entries,
    raceTo: raceTo ?? this.raceTo,
    setsToPlay: setsToPlay ?? this.setsToPlay,
    gameType: gameType ?? this.gameType,
    playoffQualifiers: playoffQualifiers ?? this.playoffQualifiers,
    guaranteedPool: guaranteedPool ?? this.guaranteedPool,
    entryFee: entryFee ?? this.entryFee,
    timeFee: timeFee ?? this.timeFee,
    prizes: prizes ?? this.prizes,
    matches: matches ?? this.matches,
    isActive: isActive ?? this.isActive,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

class TournamentPlayerHistory {
  final TournamentEntity tournament;
  final TournamentEntry entry;
  final int matchesPlayed;
  final int matchesWon;
  final int matchesLost;
  final int gamesWon;
  final int gamesLost;
  final int normalWins;
  final int setsWon;
  final int goldenBreaks;
  final int breakAndRuns;
  final int combinations;
  final int winsByFouls;
  final int furthestRound;
  final String placement;

  const TournamentPlayerHistory({
    required this.tournament,
    required this.entry,
    required this.matchesPlayed,
    required this.matchesWon,
    required this.matchesLost,
    required this.gamesWon,
    required this.gamesLost,
    required this.normalWins,
    required this.setsWon,
    required this.goldenBreaks,
    required this.breakAndRuns,
    required this.combinations,
    required this.winsByFouls,
    required this.furthestRound,
    required this.placement,
  });

  factory TournamentPlayerHistory.fromTournament(
    TournamentEntity tournament,
    TournamentEntry entry,
  ) {
    final gamesByMethod = <String, int>{};
    var matchesPlayed = 0;
    var matchesWon = 0;
    var matchesLost = 0;
    var gamesWon = 0;
    var gamesLost = 0;
    var setsWon = 0;
    var furthestRound = 0;
    var eliminatedRound = 0;
    var doubleLosses = 0;
    var doubleLossRound = 0;
    for (final match in tournament.matches) {
      if (!match.isReady ||
          (match.player1Id != entry.id && match.player2Id != entry.id)) {
        continue;
      }
      final isFirst = match.player1Id == entry.id;
      final ownPoints =
          match.points.where((point) => point.entryId == entry.id).toList();
      final otherId = isFirst ? match.player2Id : match.player1Id;
      final otherPoints =
          match.points.where((point) => point.entryId == otherId).length;
      if (ownPoints.isNotEmpty || match.winnerEntryId != null) matchesPlayed++;
      gamesWon += ownPoints.length;
      gamesLost += otherPoints;
      setsWon += isFirst ? match.sets1 : match.sets2;
      furthestRound = match.round > furthestRound ? match.round : furthestRound;
      if (match.winnerEntryId == entry.id) {
        matchesWon++;
      } else if (match.winnerEntryId != null) {
        matchesLost++;
        if (match.stage.startsWith('double_')) {
          doubleLosses++;
          doubleLossRound = match.round;
        } else if (match.stage == 'bracket' || match.stage == 'playoff') {
          eliminatedRound = match.round;
        }
      }
      for (final point in ownPoints) {
        gamesByMethod.update(
          point.method,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
      }
    }
    if (tournament.format == 'double' && doubleLosses >= 2) {
      eliminatedRound = doubleLossRound;
    }

    final finalRound = tournament.finalMatch?.round ?? furthestRound;
    String placement;
    if (tournament.championEntryId == entry.id) {
      placement = 'CAMPEÓN';
    } else if (tournament.thirdPlaceEntryId == entry.id) {
      placement = 'TERCER LUGAR';
    } else if ((tournament.format == 'league' || tournament.format == 'liga') &&
        tournament.playoffQualifiers > 0 &&
        eliminatedRound > 0) {
      final playoffFinalRound = tournament.finalMatch?.round ?? 4;
      placement = switch (eliminatedRound) {
        _ when eliminatedRound == playoffFinalRound => 'SUBCAMPEÓN',
        _ when eliminatedRound == playoffFinalRound - 1 => 'CUARTO LUGAR',
        2 => 'ELIMINADO EN CUARTOS',
        _ => 'ELIMINADO EN OCTAVOS',
      };
    } else if (tournament.format == 'league' ||
        tournament.format == 'liga' ||
        tournament.format == 'swiss') {
      final ordered = TournamentStandings.calculate(
        tournament.entries,
        tournament.matches,
        stage: tournament.format == 'swiss' ? 'swiss' : 'league',
        entryIds: tournament.entries.map((item) => item.id),
      );
      final position = ordered.indexWhere(
        (standing) => standing.entry.id == entry.id,
      );
      placement =
          tournament.isComplete
              ? 'LUGAR ${position + 1}'
              : 'EN CURSO · POSICIÓN ${position + 1}';
    } else if (tournament.format == 'groups' && eliminatedRound == 0) {
      final groupNumber = TournamentStandings.groupForEntry(
        entry.id,
        tournament.matches,
      );
      final groupStandings = TournamentStandings.calculate(
        tournament.entries,
        tournament.matches,
        stage: 'groups',
        groupNumber: groupNumber,
      );
      final groupPosition = groupStandings.indexWhere(
        (standing) => standing.entry.id == entry.id,
      );
      final reachedPlayoffs = tournament.matches.any(
        (match) =>
            match.stage == 'playoff' &&
            (match.player1Id == entry.id || match.player2Id == entry.id),
      );
      final groupIsComplete = tournament.matches
          .where(
            (match) =>
                match.stage == 'groups' && match.groupNumber == groupNumber,
          )
          .every((match) => match.isBye || match.isComplete);
      placement =
          reachedPlayoffs
              ? 'FASE FINAL · EN CURSO'
              : groupIsComplete
              ? 'ELIMINADO EN GRUPOS · LUGAR ${groupPosition + 1}'
              : 'GRUPO $groupNumber · LUGAR ${groupPosition + 1}';
    } else if (eliminatedRound > 0) {
      final roundsRemaining = finalRound - eliminatedRound;
      final lowerPlace = (1 << roundsRemaining) + 1;
      final upperPlace = (lowerPlace + (1 << roundsRemaining) - 1).clamp(
        lowerPlace,
        tournament.entries.length,
      );
      placement =
          roundsRemaining == 0
              ? 'SUBCAMPEÓN (2.º)'
              : 'ELIMINADO · ${_roundName(eliminatedRound, finalRound)} '
                  '($lowerPlace.º–$upperPlace.º)';
    } else if (tournament.isActive && furthestRound > 0) {
      placement = 'EN CURSO · ${_roundName(furthestRound, finalRound)}';
    } else {
      placement = 'SIN RESULTADO';
    }

    return TournamentPlayerHistory(
      tournament: tournament,
      entry: entry,
      matchesPlayed: matchesPlayed,
      matchesWon: matchesWon,
      matchesLost: matchesLost,
      gamesWon: gamesWon,
      gamesLost: gamesLost,
      normalWins: gamesByMethod['normal'] ?? 0,
      setsWon: setsWon,
      goldenBreaks: gamesByMethod['golden_break'] ?? 0,
      breakAndRuns:
          (gamesByMethod['break_and_run'] ?? 0) +
          (gamesByMethod['run_out'] ?? 0),
      combinations: gamesByMethod['combination'] ?? 0,
      winsByFouls: gamesByMethod['fouls'] ?? 0,
      furthestRound: furthestRound,
      placement: placement,
    );
  }
}

String _roundName(int round, int finalRound) => switch (finalRound - round) {
  0 => 'FINAL',
  1 => 'SEMIFINAL',
  2 => 'CUARTOS DE FINAL',
  3 => 'OCTAVOS DE FINAL',
  _ => 'RONDA $round',
};
