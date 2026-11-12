import 'dart:math';

import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/storage/preferences_service.dart';
import '../domain/tournament.dart';

class TournamentRepository {
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  SupabaseClient get _supabase => Supabase.instance.client;

  Future<List<TournamentEntity>> listActive() async {
    final rows = await _supabase
        .from('billar_tournaments')
        .select()
        .eq('billar_id', _prefs.billarId)
        .eq('is_active', true)
        .order('created_at', ascending: false);
    final tournaments =
        rows
            .map(
              (row) =>
                  TournamentEntity.fromCloudMap(Map<String, dynamic>.from(row)),
            )
            .toList();
    final db = await _db.database;
    await db.transaction((txn) async {
      for (final tournament in tournaments) {
        await txn.insert(
          'tournaments',
          tournament.toLocalMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    return tournaments;
  }

  Future<List<TournamentEntity>> listPlayed() async {
    final rows = await _supabase
        .from('billar_tournaments')
        .select()
        .eq('billar_id', _prefs.billarId)
        .eq('is_active', false)
        .order('updated_at', ascending: false);
    final tournaments =
        rows
            .map(
              (row) =>
                  TournamentEntity.fromCloudMap(Map<String, dynamic>.from(row)),
            )
            .toList();
    await _cacheAll(tournaments);
    return tournaments;
  }

  Future<List<TournamentPlayerHistory>> historyForPlayer({
    required String playerCode,
    required String? cloudId,
  }) async {
    final rows = await _supabase
        .from('billar_tournaments')
        .select()
        .eq('billar_id', _prefs.billarId)
        .order('created_at', ascending: false);
    final tournaments =
        rows
            .map(
              (row) =>
                  TournamentEntity.fromCloudMap(Map<String, dynamic>.from(row)),
            )
            .toList();
    await _cacheAll(tournaments);
    final history = <TournamentPlayerHistory>[];
    for (final tournament in tournaments) {
      for (final entry in tournament.entries) {
        final sameCode =
            playerCode.isNotEmpty && entry.playerCode == playerCode;
        final sameCloudId =
            cloudId != null && entry.registeredPlayerId == cloudId;
        if (!entry.isGuest && (sameCode || sameCloudId)) {
          history.add(
            TournamentPlayerHistory.fromTournament(tournament, entry),
          );
        }
      }
    }
    return history;
  }

  Future<TournamentEntity> create({
    required String name,
    required String format,
    required int? capacity,
    required int raceTo,
    required int setsToPlay,
    required double guaranteedPool,
    required double entryFee,
    required double timeFee,
    required List<TournamentPrize> prizes,
    required String gameType,
    required int playoffQualifiers,
  }) async {
    if (guaranteedPool < 0 || entryFee < 0 || timeFee < 0) {
      throw StateError('Los importes no pueden ser negativos.');
    }
    if (prizes.any((prize) => prize.place < 1 || prize.value < 0)) {
      throw StateError('Revisa los lugares y montos de los premios.');
    }
    if (prizes.map((prize) => prize.place).toSet().length != prizes.length) {
      throw StateError('No puedes asignar premios dos veces al mismo lugar.');
    }
    if (prizes
            .where((prize) => prize.type == 'percentage')
            .fold<double>(0, (total, prize) => total + prize.value) >
        100) {
      throw StateError('Los porcentajes de premios no pueden superar el 100%.');
    }
    if (!const ['Bola 8', 'Bola 9', 'Bola 10'].contains(gameType)) {
      throw StateError('Selecciona Bola 8, Bola 9 o Bola 10.');
    }
    if (playoffQualifiers != 0 && playoffQualifiers != 8) {
      throw StateError(
        'La fase final debe ser por tabla o con los ocho mejores.',
      );
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final row =
        await _supabase
            .from('billar_tournaments')
            .insert({
              'billar_id': _prefs.billarId,
              'name': name.trim().toUpperCase(),
              'tournament_format': format,
              'capacity': capacity,
              'race_to': raceTo,
              'sets_to_play': setsToPlay,
              'guaranteed_pool': guaranteedPool,
              'entry_fee': entryFee,
              'time_fee': timeFee,
              'prizes': prizes.map((prize) => prize.toMap()).toList(),
              'game_type': gameType,
              'playoff_qualifiers': playoffQualifiers,
            })
            .select()
            .single();
    final tournament = TournamentEntity.fromCloudMap(
      Map<String, dynamic>.from(row),
    );
    await _cache(tournament.copyWithTimes(createdAt: now));
    return tournament;
  }

  Future<TournamentEntity> addEntry(
    TournamentEntity tournament,
    TournamentEntry entry,
  ) async {
    if (tournament.matches.isNotEmpty) {
      throw StateError(
        'No se pueden cambiar los inscritos después del sorteo del cuadro.',
      );
    }
    if (tournament.isFull) {
      throw StateError('El torneo ya alcanzó su cupo.');
    }
    if (tournament.entries.any(
      (existing) =>
          entry.playerCode.isNotEmpty &&
          existing.playerCode == entry.playerCode,
    )) {
      throw StateError('Ese jugador ya está inscrito en el torneo.');
    }
    final updated = await _updateEntries(tournament, [
      ...tournament.entries,
      entry,
    ]);
    return updated;
  }

  Future<TournamentEntity> removeEntry(
    TournamentEntity tournament,
    String entryId,
  ) {
    if (tournament.matches.isNotEmpty) {
      throw StateError(
        'No se pueden quitar inscritos después del sorteo del cuadro.',
      );
    }
    return _updateEntries(
      tournament,
      tournament.entries.where((entry) => entry.id != entryId).toList(),
    );
  }

  Future<TournamentEntity> ensureSchedule(TournamentEntity tournament) async {
    if (tournament.matches.isNotEmpty) return tournament;
    if (tournament.entries.length < 2) {
      throw StateError(
        'Inscribe al menos dos jugadores para iniciar el torneo.',
      );
    }
    if ((tournament.format == 'liga' || tournament.format == 'league') &&
        tournament.playoffQualifiers > 0 &&
        tournament.entries.length < tournament.playoffQualifiers) {
      throw StateError(
        'Inscribe al menos ${tournament.playoffQualifiers} jugadores para clasificar a las finales.',
      );
    }
    final matches = switch (tournament.format) {
      'single' => TournamentBracket.create(tournament.entries),
      'double' => TournamentSchedule.createDoubleRound(
        tournament.entries,
        const [],
        round: 1,
      ),
      'liga' ||
      'league' => TournamentSchedule.createRoundRobin(tournament.entries),
      'groups' => TournamentSchedule.createGroups(tournament.entries),
      'swiss' => TournamentSchedule.createSwissRound(
        tournament.entries,
        const [],
        round: 1,
      ),
      _ =>
        throw StateError('Formato de torneo desconocido: ${tournament.format}'),
    };
    return _saveMatches(tournament, matches);
  }

  Future<TournamentEntity> updateMatchSettings(
    TournamentEntity tournament, {
    required int raceTo,
    required int setsToPlay,
  }) async {
    if (raceTo < 1 || raceTo > 99) {
      throw StateError('La cantidad debe ser de 1 a 99 partidas ganadas.');
    }
    if (setsToPlay < 1 || setsToPlay > 99 || setsToPlay.isEven) {
      throw StateError(
        'Los sets deben ser 1, 3, 5 u otro número impar entre 1 y 99.',
      );
    }
    if (tournament.matches.isNotEmpty) {
      throw StateError(
        'No se puede cambiar la duración después de sortear el cuadro.',
      );
    }
    final row =
        await _supabase
            .from('billar_tournaments')
            .update({
              'race_to': raceTo,
              'sets_to_play': setsToPlay,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', tournament.id)
            .eq('billar_id', _prefs.billarId)
            .select()
            .single();
    final updated = TournamentEntity.fromCloudMap(
      Map<String, dynamic>.from(row),
    );
    await _cache(updated);
    return updated;
  }

  Future<TournamentEntity> recordPoint(
    TournamentEntity tournament, {
    required String matchId,
    required String entryId,
    required String method,
  }) async {
    final index = tournament.matches.indexWhere((match) => match.id == matchId);
    if (index < 0) throw StateError('No se encontró el enfrentamiento.');
    final match = tournament.matches[index];
    if (!match.isReady || match.isComplete) {
      throw StateError('Este enfrentamiento no está disponible para marcar.');
    }
    if (entryId != match.player1Id && entryId != match.player2Id) {
      throw StateError('El jugador no pertenece a este enfrentamiento.');
    }
    final updatedMatches = [...tournament.matches];
    updatedMatches[index] = TournamentScoring.recordPoint(
      match,
      entryId: entryId,
      method: method,
      raceTo: tournament.raceTo,
      setsToPlay: tournament.setsToPlay,
    );
    _advanceBracketWinner(
      tournament,
      updatedMatches,
      match,
      updatedMatches[index],
    );
    _appendNextStage(tournament, updatedMatches);
    _syncThirdPlaceMatch(tournament, updatedMatches);
    return _saveMatches(tournament, updatedMatches);
  }

  Future<TournamentEntity> undoPoint(
    TournamentEntity tournament, {
    required String matchId,
    required String entryId,
  }) async {
    final index = tournament.matches.indexWhere((match) => match.id == matchId);
    if (index < 0) throw StateError('No se encontró el enfrentamiento.');
    final match = tournament.matches[index];
    if (match.points.isEmpty || match.points.last.entryId != entryId) {
      throw StateError('Solo se puede deshacer la última partida registrada.');
    }
    final updatedMatches = [...tournament.matches];
    if ((tournament.format == 'liga' || tournament.format == 'league') &&
        match.stage == 'playoff') {
      final thirdPlaceMatch =
          updatedMatches
              .where((candidate) => candidate.stage == 'third_place')
              .firstOrNull;
      if (thirdPlaceMatch?.points.isNotEmpty == true &&
          match.round < thirdPlaceMatch!.round) {
        throw StateError(
          'No se puede corregir la semifinal porque el partido por el tercer lugar ya comenzó.',
        );
      }
    }
    _removeUnstartedNextRounds(tournament, match, updatedMatches);
    updatedMatches[index] = TournamentScoring.undoPoint(
      match,
      entryId: entryId,
      raceTo: tournament.raceTo,
      setsToPlay: tournament.setsToPlay,
    );
    _advanceBracketWinner(
      tournament,
      updatedMatches,
      match,
      updatedMatches[index],
    );
    _syncThirdPlaceMatch(tournament, updatedMatches);
    return _saveMatches(tournament, updatedMatches);
  }

  void _advanceBracketWinner(
    TournamentEntity tournament,
    List<TournamentMatch> matches,
    TournamentMatch previous,
    TournamentMatch updated,
  ) {
    if (tournament.format == 'single' ||
        (tournament.format == 'groups' && updated.stage == 'playoff') ||
        ((tournament.format == 'liga' || tournament.format == 'league') &&
            tournament.playoffQualifiers > 0 &&
            updated.stage == 'playoff')) {
      TournamentBracket.advanceWinner(matches, previous, updated);
    }
  }

  void _syncThirdPlaceMatch(
    TournamentEntity tournament,
    List<TournamentMatch> matches,
  ) {
    if ((tournament.format != 'liga' && tournament.format != 'league') ||
        tournament.playoffQualifiers == 0) {
      return;
    }
    final playoffMatches =
        matches.where((match) => match.stage == 'playoff').toList();
    if (playoffMatches.isEmpty) return;
    final finalRound = playoffMatches.fold<int>(
      0,
      (latest, match) => latest > match.round ? latest : match.round,
    );
    final semifinalRound = finalRound - 1;
    if (semifinalRound < 1) return;
    final semifinals =
        playoffMatches.where((match) => match.round == semifinalRound).toList();
    if (semifinals.length != 2) return;
    final thirdIndex = matches.indexWhere(
      (match) => match.stage == 'third_place',
    );
    if (thirdIndex < 0) return;
    final thirdMatch = matches[thirdIndex];
    String? loserOf(TournamentMatch match) {
      if (!match.isComplete) return null;
      return match.winnerEntryId == match.player1Id
          ? match.player2Id
          : match.player1Id;
    }

    final firstLoser = loserOf(semifinals[0]);
    final secondLoser = loserOf(semifinals[1]);
    if (thirdMatch.player1Id == firstLoser &&
        thirdMatch.player2Id == secondLoser) {
      return;
    }
    if (thirdMatch.points.isNotEmpty) {
      throw StateError(
        'No se pueden cambiar los semifinalistas porque el partido por el tercer lugar ya comenzó.',
      );
    }
    matches[thirdIndex] = thirdMatch.copyWith(
      player1Id: firstLoser,
      player2Id: secondLoser,
      winnerEntryId: null,
      score1: 0,
      score2: 0,
      sets1: 0,
      sets2: 0,
      points: const [],
    );
  }

  void _appendNextStage(
    TournamentEntity tournament,
    List<TournamentMatch> matches,
  ) {
    if (tournament.format == 'liga' || tournament.format == 'league') {
      if (tournament.playoffQualifiers == 0 ||
          matches.any((match) => match.stage == 'playoff')) {
        return;
      }
      final leagueMatches =
          matches.where((match) => match.stage == 'league').toList();
      if (leagueMatches.isNotEmpty &&
          leagueMatches.every((match) => match.isBye || match.isComplete)) {
        matches.addAll(
          TournamentSchedule.createLeaguePlayoff(
            tournament.entries,
            leagueMatches,
            qualifiers: tournament.playoffQualifiers,
          ),
        );
      }
      return;
    }

    if (tournament.format == 'groups') {
      final groupMatches = matches.where((match) => match.stage == 'groups');
      final hasPlayoffs = matches.any((match) => match.stage == 'playoff');
      if (!hasPlayoffs &&
          groupMatches.isNotEmpty &&
          groupMatches.every((match) => match.isBye || match.isComplete)) {
        final qualifiers = TournamentSchedule.groupQualifiers(
          tournament.entries,
          matches,
        );
        if (qualifiers.length >= 2) {
          matches.addAll(
            TournamentBracket.create(
              qualifiers,
              shuffle: false,
              stage: 'playoff',
              idPrefix: 'playoff',
            ),
          );
        }
      }
      return;
    }

    if (tournament.format == 'double') {
      final latestRound = matches
          .where((match) => match.stage.startsWith('double_'))
          .fold<int>(
            0,
            (round, match) => round > match.round ? round : match.round,
          );
      if (latestRound == 0 ||
          matches.any((match) => match.stage == 'double_final') ||
          matches
              .where(
                (match) =>
                    match.round == latestRound && match.stage != 'double_final',
              )
              .any((match) => !match.isBye && !match.isComplete)) {
        return;
      }
      matches.addAll(
        TournamentSchedule.createDoubleRound(
          tournament.entries,
          matches,
          round: latestRound + 1,
        ),
      );
      return;
    }

    if (tournament.format == 'swiss') {
      final latestRound = matches
          .where((match) => match.stage == 'swiss')
          .fold<int>(
            0,
            (round, match) => round > match.round ? round : match.round,
          );
      if (latestRound == 0 ||
          latestRound >=
              TournamentSchedule.swissRoundCount(tournament.entries.length) ||
          matches
              .where(
                (match) => match.stage == 'swiss' && match.round == latestRound,
              )
              .any((match) => !match.isBye && !match.isComplete)) {
        return;
      }
      matches.addAll(
        TournamentSchedule.createSwissRound(
          tournament.entries,
          matches,
          round: latestRound + 1,
        ),
      );
    }
  }

  void _removeUnstartedNextRounds(
    TournamentEntity tournament,
    TournamentMatch match,
    List<TournamentMatch> matches,
  ) {
    final shouldRebuildDynamicRounds =
        tournament.format == 'double' ||
        tournament.format == 'swiss' ||
        (tournament.format == 'groups' && match.stage == 'groups');
    if (!shouldRebuildDynamicRounds) return;
    final laterMatches =
        tournament.format == 'groups' && match.stage == 'groups'
            ? matches
                .where((candidate) => candidate.stage == 'playoff')
                .toList()
            : matches
                .where(
                  (candidate) =>
                      candidate.round > match.round &&
                      (tournament.format == 'double'
                          ? candidate.stage.startsWith('double_')
                          : candidate.stage == match.stage),
                )
                .toList();
    if (laterMatches.any((candidate) => candidate.points.isNotEmpty)) {
      throw StateError(
        'No se puede corregir este marcador porque una ronda posterior ya comenzó.',
      );
    }
    matches.removeWhere((candidate) => laterMatches.contains(candidate));
  }

  Future<TournamentEntity> _saveMatches(
    TournamentEntity tournament,
    List<TournamentMatch> matches,
  ) async {
    final row =
        await _supabase
            .from('billar_tournaments')
            .update({
              'matches': matches.map((match) => match.toMap()).toList(),
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', tournament.id)
            .eq('billar_id', _prefs.billarId)
            .select()
            .single();
    final updated = TournamentEntity.fromCloudMap(
      Map<String, dynamic>.from(row),
    );
    await _cache(updated);
    return updated;
  }

  Future<TournamentEntity> archive(TournamentEntity tournament) async {
    if (!tournament.hasChampion) {
      throw StateError(
        'El torneo debe terminar su final antes de guardarlo en el historial.',
      );
    }
    final row =
        await _supabase
            .from('billar_tournaments')
            .update({
              'is_active': false,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', tournament.id)
            .eq('billar_id', _prefs.billarId)
            .select()
            .single();
    final updated = TournamentEntity.fromCloudMap(
      Map<String, dynamic>.from(row),
    );
    await _cache(updated);
    return updated;
  }

  Future<TournamentEntity> _updateEntries(
    TournamentEntity tournament,
    List<TournamentEntry> entries,
  ) async {
    final row =
        await _supabase
            .from('billar_tournaments')
            .update({
              'entries': entries.map((entry) => entry.toMap()).toList(),
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', tournament.id)
            .eq('billar_id', _prefs.billarId)
            .select()
            .single();
    final updated = TournamentEntity.fromCloudMap(
      Map<String, dynamic>.from(row),
    );
    await _cache(updated);
    return updated;
  }

  Future<void> _cache(TournamentEntity tournament) async {
    final db = await _db.database;
    await db.insert(
      'tournaments',
      tournament.toLocalMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _cacheAll(List<TournamentEntity> tournaments) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      for (final tournament in tournaments) {
        await txn.insert(
          'tournaments',
          tournament.toLocalMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  static String newEntryId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

extension on TournamentEntity {
  TournamentEntity copyWithTimes({String? createdAt}) => TournamentEntity(
    id: id,
    billarId: billarId,
    name: name,
    format: format,
    capacity: capacity,
    entries: entries,
    raceTo: raceTo,
    setsToPlay: setsToPlay,
    gameType: gameType,
    playoffQualifiers: playoffQualifiers,
    guaranteedPool: guaranteedPool,
    entryFee: entryFee,
    timeFee: timeFee,
    prizes: prizes,
    matches: matches,
    isActive: isActive,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt,
  );
}
