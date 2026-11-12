import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../players/data/repositories/player_repository.dart';
import '../../data/tournament_repository.dart';
import '../../domain/tournament.dart';
import '../tournament_champion_certificate.dart';
import '../tournament_standings_pdf.dart';

class TournamentDetailPage extends StatefulWidget {
  final TournamentEntity tournament;

  const TournamentDetailPage({super.key, required this.tournament});

  @override
  State<TournamentDetailPage> createState() => _TournamentDetailPageState();
}

class _TournamentDetailPageState extends State<TournamentDetailPage> {
  final _repository = TournamentRepository();
  final _playerRepository = PlayerRepository();
  late TournamentEntity _tournament;
  bool _loading = true;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tournament = widget.tournament;
    _loadBracket();
  }

  Future<void> _loadBracket() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final players = await _playerRepository.getAll();
      final tournamentWithAvatars = _tournament.copyWith(
        entries:
            _tournament.entries.map((entry) {
              if (entry.avatar.isNotEmpty) return entry;
              final player =
                  players.where((player) {
                    final matchesCode =
                        entry.playerCode.isNotEmpty &&
                        player.playerCode == entry.playerCode;
                    final matchesCloudId =
                        entry.registeredPlayerId != null &&
                        player.cloudId == entry.registeredPlayerId;
                    return matchesCode || matchesCloudId;
                  }).firstOrNull;
              return player == null
                  ? entry
                  : entry.copyWith(avatar: player.avatar);
            }).toList(),
      );
      final tournament = await _repository.ensureSchedule(
        tournamentWithAvatars,
      );
      if (!mounted) return;
      setState(
        () =>
            _tournament = tournament.copyWith(
              entries: tournamentWithAvatars.entries,
            ),
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[TournamentDetailPage] Could not load bracket: $error\n$stackTrace',
      );
      if (mounted) setState(() => _error = _bracketErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _bracketErrorMessage(Object error) {
    if (error is PostgrestException &&
        error.code == 'PGRST204' &&
        (error.message.contains("'matches'") ||
            error.message.contains("'race_to'") ||
            error.message.contains("'sets_to_play'") ||
            error.message.contains("'guaranteed_pool'") ||
            error.message.contains("'entry_fee'") ||
            error.message.contains("'time_fee'") ||
            error.message.contains("'prizes'") ||
            error.message.contains("'game_type'") ||
            error.message.contains("'playoff_qualifiers'"))) {
      return 'Falta actualizar la base de datos de Supabase. Ejecuta '
          'supabase/add_tournaments.sql en el SQL Editor y vuelve a abrir el torneo.';
    }
    return error.toString();
  }

  Future<void> _recordPoint(
    TournamentMatch match,
    TournamentEntry entry,
  ) async {
    final method = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder:
          (context) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const ListTile(
                  title: Text('REGISTRAR PARTIDA GANADA'),
                  subtitle: Text('Selecciona cómo se ganó esta partida.'),
                ),
                for (final item in _winMethods.entries)
                  if (item.key != 'early_eight' ||
                      _tournament.gameType == 'Bola 8')
                    ListTile(
                      leading: Icon(item.value.$2),
                      title: Text(item.value.$1),
                      onTap: () => Navigator.pop(context, item.key),
                    ),
              ],
            ),
          ),
    );
    if (method == null || !mounted) return;
    await _runScoreAction(
      () => _repository.recordPoint(
        _tournament,
        matchId: match.id,
        entryId: entry.id,
        method: method,
      ),
    );
  }

  Future<void> _undoPoint(TournamentMatch match, TournamentEntry entry) async {
    await _runScoreAction(
      () => _repository.undoPoint(
        _tournament,
        matchId: match.id,
        entryId: entry.id,
      ),
    );
  }

  Future<void> _runScoreAction(
    Future<TournamentEntity> Function() action,
  ) async {
    setState(() => _saving = true);
    try {
      final updated = await action();
      if (mounted) {
        setState(
          () => _tournament = updated.copyWith(entries: _tournament.entries),
        );
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[TournamentDetailPage] Could not update score: $error\n$stackTrace',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo actualizar el marcador: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Map<String, TournamentEntry> get _entriesById => {
    for (final entry in _tournament.entries) entry.id: entry,
  };

  Map<String, int> get _matchWins {
    final wins = <String, int>{};
    for (final match in _tournament.matches) {
      if (!match.isBye && match.winnerEntryId != null) {
        wins.update(
          match.winnerEntryId!,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
      }
    }
    return wins;
  }

  @override
  Widget build(BuildContext context) {
    final sections = <(String, int?, int), List<TournamentMatch>>{};
    for (final match in _tournament.matches) {
      sections
          .putIfAbsent((match.stage, match.groupNumber, match.round), () => [])
          .add(match);
    }
    final sectionKeys =
        sections.keys.toList()..sort((left, right) {
          final stageOrder = _stageOrder(
            left.$1,
          ).compareTo(_stageOrder(right.$1));
          if (stageOrder != 0) return stageOrder;
          final groupOrder = (left.$2 ?? 0).compareTo(right.$2 ?? 0);
          if (groupOrder != 0) return groupOrder;
          return left.$3.compareTo(right.$3);
        });
    final championId = _tournament.championEntryId;
    final champion = championId == null ? null : _entriesById[championId];

    return Scaffold(
      appBar: AppBar(
        title: Text(_tournament.name),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _loading || _saving ? null : _loadBracket,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body:
          _loading && _tournament.matches.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _ErrorState(message: _error!, onRetry: _loadBracket)
              : _tournament.entries.length < 2
              ? const _ErrorState(
                message:
                    'Inscribe al menos dos jugadores para generar el cuadro.',
              )
              : Stack(
                children: [
                  ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.sports_score),
                          title: Text(
                            '${_formatTitle(_tournament.format)} · ${_tournament.gameType.toUpperCase()}',
                          ),
                          subtitle: Text(
                            _formatDescription(_tournament.format),
                          ),
                        ),
                      ),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'INSCRIPCIÓN, PREMIOS Y TIEMPO',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Inscripción: ${formatTournamentMoney(_tournament.entryFee)} por jugador '
                                '· Total: ${formatTournamentMoney(_tournament.entryTotal)}',
                              ),
                              Text(
                                'Bolsa garantizada: ${formatTournamentMoney(_tournament.guaranteedPool)} '
                                '· Bolsa total: ${formatTournamentMoney(_tournament.prizePool)}',
                              ),
                              Text(
                                'Tiempo de mesa: ${_tournament.completedMatches} enfrentamientos '
                                '× ${formatTournamentMoney(_tournament.timeFee)} '
                                '= ${formatTournamentMoney(_tournament.timeRevenue)}',
                              ),
                              if (_tournament.prizes.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                const Text('LUGARES PREMIADOS'),
                                for (final prize in [..._tournament.prizes]
                                  ..sort(
                                    (left, right) =>
                                        left.place.compareTo(right.place),
                                  ))
                                  Text(
                                    'Lugar ${prize.place}: '
                                    '${prize.type == 'percentage' ? '${prize.value.toStringAsFixed(2)}%' : formatTournamentMoney(prize.value)}'
                                    ' · Premio estimado ${formatTournamentMoney(prize.amountFor(_tournament.prizePool))}',
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (_tournament.format == 'league' ||
                          _tournament.format == 'liga') ...[
                        _buildStandings(
                          title: 'TABLA DE POSICIONES · ROUND ROBIN',
                          stage: 'league',
                          entryIds: _tournament.entries.map(
                            (entry) => entry.id,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: OutlinedButton.icon(
                            onPressed: _openStandingsPdfPreview,
                            icon: const Icon(Icons.picture_as_pdf),
                            label: const Text('VISTA PREVIA PDF DE POSICIONES'),
                          ),
                        ),
                      ],
                      if (_tournament.format == 'swiss')
                        _buildStandings(
                          title: 'TABLA SUIZA',
                          stage: 'swiss',
                          entryIds: _tournament.entries.map(
                            (entry) => entry.id,
                          ),
                        ),
                      if (_tournament.format == 'groups')
                        for (final group
                            in _tournament.matches
                                .where((match) => match.stage == 'groups')
                                .map((match) => match.groupNumber)
                                .whereType<int>()
                                .toSet()
                                .toList()
                              ..sort())
                          _buildStandings(
                            title: 'GRUPO $group',
                            stage: 'groups',
                            groupNumber: group,
                          ),
                      if (champion != null)
                        Card(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.18),
                          child: ListTile(
                            leading: const Icon(
                              Icons.emoji_events,
                              color: Colors.amber,
                              size: 32,
                            ),
                            title: const Text('CAMPEÓN'),
                            subtitle: Text(champion.displayName),
                          ),
                        ),
                      for (final key in sectionKeys)
                        _buildRound(
                          key.$3,
                          sections[key]!,
                          _tournament.matches
                              .where(
                                (match) =>
                                    match.stage == key.$1 &&
                                    match.groupNumber == key.$2,
                              )
                              .map((match) => match.round)
                              .toSet()
                              .length,
                          stage: key.$1,
                          groupNumber: key.$2,
                        ),
                      if (champion != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: FilledButton.icon(
                            onPressed: _saving ? null : _shareChampion,
                            icon: const Icon(Icons.share),
                            label: const Text('COMPARTIR CAMPEÓN POR WHATSAPP'),
                          ),
                        ),
                      if (champion != null && _tournament.isActive)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 24),
                          child: OutlinedButton.icon(
                            onPressed: _saving ? null : _finishTournament,
                            icon: const Icon(Icons.emoji_events_outlined),
                            label: const Text(
                              'FINALIZAR Y GUARDAR EN HISTORIAL',
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (_saving)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Color(0x55000000),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                ],
              ),
    );
  }

  Future<void> _shareChampion() async {
    try {
      await TournamentChampionCertificate.share(
        _tournament,
        _entriesById[_tournament.championEntryId],
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[TournamentDetailPage] Could not share champion: $error\n$stackTrace',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No se pudo compartir el reconocimiento: $error'),
          ),
        );
      }
    }
  }

  Future<void> _finishTournament() async {
    try {
      final finished = await _repository.archive(_tournament);
      if (!mounted) return;
      setState(
        () => _tournament = finished.copyWith(entries: _tournament.entries),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Torneo finalizado y agregado al historial.'),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[TournamentDetailPage] Could not finish tournament: $error\n$stackTrace',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo finalizar el torneo: $error')),
        );
      }
    }
  }

  Future<void> _openStandingsPdfPreview() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TournamentStandingsPdfPage(tournament: _tournament),
      ),
    );
  }

  int _stageOrder(String stage) => switch (stage) {
    'league' || 'groups' || 'swiss' || 'bracket' || 'double_winners' => 0,
    'double_losers' || 'playoff' => 1,
    'third_place' => 2,
    'double_final' => 3,
    _ => 3,
  };

  String _formatTitle(String format) => switch (format) {
    'single' => 'ELIMINACIÓN SIMPLE',
    'double' => 'DOBLE ELIMINACIÓN',
    'league' || 'liga' => 'ROUND ROBIN · LIGA',
    'groups' => 'FASE DE GRUPOS',
    'swiss' => 'SISTEMA SUIZO',
    _ => format.toUpperCase(),
  };

  String _formatDescription(String format) =>
      'Cada set es a ${_tournament.raceTo} partidas; gana el enfrentamiento '
      'quien obtenga la mayoría de ${_tournament.setsToPlay} sets. '
      '${switch (format) {
        'single' => 'El ganador avanza y el perdedor queda eliminado.',
        'double' => 'Se juega una sola final entre las llaves de ganadores y perdedores.',
        'league' || 'liga' => _tournament.playoffQualifiers > 0 ? 'Cada jornada queda guardada como semana. Los ${_tournament.playoffQualifiers} mejores por puntos pasan a finales con nuevo sorteo, eliminación directa y partido por el tercer lugar.' : 'Cada jornada queda guardada como semana. El campeón se define por puntos: 3 por victoria; desempates por diferencia de juegos, enfrentamiento directo y sets.',
        'groups' => 'Grupos de hasta cuatro jugadores; clasifican los dos primeros de cada grupo a eliminación directa.',
        'swiss' => 'Rondas automáticas por posición, evitando repetir rivales; la tabla se actualiza al guardar resultados.',
        _ => '',
      }}';

  Widget _buildStandings({
    required String title,
    required String stage,
    int? groupNumber,
    Iterable<String>? entryIds,
  }) {
    final standings = TournamentStandings.calculate(
      _tournament.entries,
      _tournament.matches,
      stage: stage,
      groupNumber: groupNumber,
      entryIds: entryIds,
    );
    if (standings.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (var index = 0; index < standings.length; index++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    SizedBox(
                      width: 26,
                      child: Text(
                        '${index + 1}.',
                        style: TextStyle(
                          color: index == 0 ? Colors.amber : Colors.white54,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            standings[index].entry.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            '${standings[index].points} PTS  ·  PJ ${standings[index].matchesPlayed}  ·  '
                            'V-D ${standings[index].matchesWon}-${standings[index].matchesLost}  ·  '
                            'Juegos ${standings[index].gamesWon}-${standings[index].gamesLost}  ·  '
                            'Dif. ${standings[index].gameDifference >= 0 ? '+' : ''}${standings[index].gameDifference}',
                            maxLines: 2,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRound(
    int round,
    List<TournamentMatch> matches,
    int roundCount, {
    required String stage,
    int? groupNumber,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(
            _roundLabel(round, roundCount, stage, groupNumber),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
        ),
        for (final match in matches)
          _MatchCard(
            match: match,
            raceTo: _tournament.raceTo,
            setsToPlay: _tournament.setsToPlay,
            entries: _entriesById,
            tournamentWins: _matchWins,
            enabled: !_saving,
            onAddPoint: (entry) => _recordPoint(match, entry),
            onUndoPoint: (entry) => _undoPoint(match, entry),
          ),
      ],
    );
  }

  String _roundLabel(
    int round,
    int roundCount,
    String stage,
    int? groupNumber,
  ) {
    if (stage == 'league') return 'SEMANA $round · JORNADA $round';
    if (stage == 'groups') {
      return 'GRUPO ${groupNumber ?? ''} · JORNADA $round';
    }
    if (stage == 'swiss') return 'RONDA SUIZA $round';
    if (stage == 'double_winners') return 'RONDA $round · LLAVE DE GANADORES';
    if (stage == 'double_losers') return 'RONDA $round · LLAVE DE PERDEDORES';
    if (stage == 'double_final') return 'FINAL · DOBLE ELIMINACIÓN';
    if (stage == 'third_place') return 'PARTIDO POR EL TERCER LUGAR';
    if (stage == 'playoff') {
      final remaining = roundCount - round;
      final label = switch (remaining) {
        0 => 'FINAL',
        1 => 'SEMIFINALES',
        2 => 'CUARTOS DE FINAL',
        _ => 'RONDA $round',
      };
      return 'FASE FINAL · $label';
    }
    final remaining = roundCount - round;
    final label = switch (remaining) {
      0 => 'FINAL',
      1 => 'SEMIFINALES',
      2 => 'CUARTOS DE FINAL',
      3 => 'OCTAVOS DE FINAL',
      _ => 'RONDA $round',
    };
    return '$label · RONDA $round';
  }
}

const _winMethods = <String, (String, IconData)>{
  'normal': ('Juego ganado', Icons.sports),
  'golden_break': ('Golden break', Icons.bolt),
  'break_and_run': ('Break & Run', Icons.done_all),
  'combination': ('Combinación', Icons.linear_scale),
  'fouls': ('Por faltas del rival', Icons.rule),
  'early_eight': ('Bola 8 anticipada del rival', Icons.sports_bar),
};

String _winMethodLabel(String method) =>
    method == 'run_out' ? 'Break & Run' : _winMethods[method]?.$1 ?? method;

class _MatchCard extends StatelessWidget {
  final TournamentMatch match;
  final int raceTo;
  final int setsToPlay;
  final Map<String, TournamentEntry> entries;
  final Map<String, int> tournamentWins;
  final bool enabled;
  final ValueChanged<TournamentEntry> onAddPoint;
  final ValueChanged<TournamentEntry> onUndoPoint;

  const _MatchCard({
    required this.match,
    required this.raceTo,
    required this.setsToPlay,
    required this.entries,
    required this.tournamentWins,
    required this.enabled,
    required this.onAddPoint,
    required this.onUndoPoint,
  });

  @override
  Widget build(BuildContext context) {
    final player1 = entries[match.player1Id];
    final player2 = entries[match.player2Id];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: Text('ENFRENTAMIENTO ${match.matchNumber}')),
                Text(
                  match.isBye
                      ? 'PASE AUTOMÁTICO'
                      : match.winnerEntryId == null
                      ? 'MEJOR DE $setsToPlay · A $raceTo'
                      : 'FINALIZADO',
                  style: TextStyle(
                    color:
                        match.winnerEntryId == null
                            ? Colors.white60
                            : Colors.greenAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            if (match.isReady) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surface.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Wrap(
                  alignment: WrapAlignment.spaceEvenly,
                  spacing: 16,
                  runSpacing: 4,
                  children: [
                    Text(
                      'SETS  ${match.sets1} - ${match.sets2}',
                      style: const TextStyle(
                        color: Colors.amber,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'JUEGOS  ${match.score1} - ${match.score2}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const Divider(),
            _PlayerScoreRow(
              entry: player1,
              score: match.score1,
              tournamentWins: tournamentWins[player1?.id] ?? 0,
              enabled: enabled,
              onAddPoint:
                  player1 == null || !match.isReady || match.isComplete
                      ? null
                      : () => onAddPoint(player1),
              onUndoPoint:
                  player1 == null ||
                          match.points.isEmpty ||
                          match.points.last.entryId != player1.id
                      ? null
                      : () => onUndoPoint(player1),
            ),
            const Divider(height: 12),
            _PlayerScoreRow(
              entry: player2,
              score: match.score2,
              tournamentWins: tournamentWins[player2?.id] ?? 0,
              enabled: enabled,
              onAddPoint:
                  player2 == null || !match.isReady || match.isComplete
                      ? null
                      : () => onAddPoint(player2),
              onUndoPoint:
                  player2 == null ||
                          match.points.isEmpty ||
                          match.points.last.entryId != player2.id
                      ? null
                      : () => onUndoPoint(player2),
            ),
            if (match.isBye && match.winnerEntryId != null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Avanza a la siguiente ronda'),
              ),
            if (match.points.isNotEmpty) ...[
              const Divider(height: 16),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final point in match.points)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        'SET ${point.setNumber} · ${entries[point.entryId]?.displayName ?? 'Jugador'} · '
                        '${_winMethodLabel(point.method)}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlayerScoreRow extends StatelessWidget {
  final TournamentEntry? entry;
  final int score;
  final int tournamentWins;
  final bool enabled;
  final VoidCallback? onAddPoint;
  final VoidCallback? onUndoPoint;

  const _PlayerScoreRow({
    required this.entry,
    required this.score,
    required this.tournamentWins,
    required this.enabled,
    required this.onAddPoint,
    required this.onUndoPoint,
  });

  @override
  Widget build(BuildContext context) {
    if (entry == null) {
      return const SizedBox(
        height: 54,
        child: Row(
          children: [
            Icon(Icons.hourglass_empty),
            SizedBox(width: 8),
            Text('POR DEFINIR'),
          ],
        ),
      );
    }
    final player = entry!;
    return Row(
      children: [
        TournamentEntryAvatar(entry: player),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                player.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '★' * player.handicap.clamp(1, 6).toInt(),
                    style: const TextStyle(
                      color: Colors.amber,
                      letterSpacing: 1,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.emoji_events,
                        size: 14,
                        color: Colors.amber.shade300,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '$tournamentWins victorias',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Deshacer partida ganada',
          onPressed: enabled ? onUndoPoint : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$score',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const Text(
              'JUEGOS',
              style: TextStyle(fontSize: 8, color: Colors.white54),
            ),
          ],
        ),
        IconButton(
          tooltip: 'Sumar partida ganada',
          onPressed: enabled ? onAddPoint : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}

class TournamentEntryAvatar extends StatelessWidget {
  final TournamentEntry entry;

  const TournamentEntryAvatar({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final avatar = entry.avatar;
    final uri = Uri.tryParse(avatar);
    final isNetworkImage =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    final fallback = CircleAvatar(
      backgroundColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.2),
      child: Text(entry.displayName.isEmpty ? '?' : entry.displayName[0]),
    );
    if (avatar.isEmpty) return fallback;
    return ClipOval(
      child:
          isNetworkImage
              ? Image.network(
                avatar,
                width: 42,
                height: 42,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              )
              : Image.file(
                File(avatar),
                width: 42,
                height: 42,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const _ErrorState({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.info_outline, size: 40),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('REINTENTAR')),
        ],
      ),
    ),
  );
}
