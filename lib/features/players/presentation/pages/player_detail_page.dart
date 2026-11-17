import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/utils/scoped_remote_image.dart';
import '../../../tournaments/data/tournament_repository.dart';
import '../../../tournaments/domain/tournament.dart';
import '../../../tournaments/presentation/pages/tournament_detail_page.dart';
import '../../domain/entities/player_stats.dart';

class PlayerDetailPage extends StatefulWidget {
  final PlayerEntity player;
  final bool readOnly;
  const PlayerDetailPage({
    super.key,
    required this.player,
    this.readOnly = false,
  });

  @override
  State<PlayerDetailPage> createState() => _PlayerDetailPageState();
}

class _PlayerDetailPageState extends State<PlayerDetailPage> {
  late final Future<List<TournamentPlayerHistory>> _tournamentHistory;

  @override
  void initState() {
    super.initState();
    _tournamentHistory = TournamentRepository().historyForPlayer(
      playerCode: widget.player.playerCode,
      cloudId: widget.player.cloudId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.player.displayName),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'ESTADÍSTICAS'),
              Tab(text: 'HISTORIAL'),
              Tab(text: 'TORNEOS'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _StatsTab(
              player: widget.player,
              tournamentHistory: _tournamentHistory,
            ),
            _HistoryTab(player: widget.player),
            _TournamentsTab(
              player: widget.player,
              tournamentHistory: _tournamentHistory,
              readOnly: widget.readOnly,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsTab extends StatelessWidget {
  final PlayerEntity player;
  final Future<List<TournamentPlayerHistory>> tournamentHistory;
  const _StatsTab({required this.player, required this.tournamentHistory});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stats = player.stats;

    return FutureBuilder<List<TournamentPlayerHistory>>(
      future: tournamentHistory,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('No se pudo cargar el historial: ${snapshot.error}'),
          );
        }
        final history = snapshot.data ?? const <TournamentPlayerHistory>[];
        final tournamentGamesPlayed = history.fold(
          0,
          (total, item) => total + item.gamesWon + item.gamesLost,
        );
        final tournamentWins = history.fold(
          0,
          (total, item) => total + item.gamesWon,
        );
        final tournamentLosses = history.fold(
          0,
          (total, item) => total + item.gamesLost,
        );
        final tournamentGoldenBreaks = history.fold(
          0,
          (total, item) => total + item.goldenBreaks,
        );
        final tournamentBreakAndRuns = history.fold(
          0,
          (total, item) => total + item.breakAndRuns,
        );
        final tournamentNormalWins = history.fold(
          0,
          (total, item) => total + item.normalWins,
        );
        final tournamentCombinations = history.fold(
          0,
          (total, item) => total + item.combinations,
        );
        final tournamentWinsByFouls = history.fold(
          0,
          (total, item) => total + item.winsByFouls,
        );
        final totalWins = stats.wins + tournamentWins;
        final totalLosses = stats.losses + tournamentLosses;
        final totalMatches = stats.totalMatches + tournamentGamesPlayed;
        final winRate =
            totalMatches == 0 ? 0.0 : (totalWins / totalMatches) * 100;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle('RESUMEN'),
              const SizedBox(height: 12),
              GridView.extent(
                maxCrossAxisExtent: 220,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.3,
                children: [
                  _StatCard(
                    'Partidas',
                    '$totalMatches',
                    Icons.sports_bar,
                    Colors.white70,
                  ),
                  _StatCard(
                    'Victorias',
                    '$totalWins',
                    Icons.emoji_events,
                    Colors.greenAccent,
                  ),
                  _StatCard(
                    'Derrotas',
                    '$totalLosses',
                    Icons.close,
                    Colors.redAccent,
                  ),
                  _StatCard(
                    'Empates',
                    '${stats.draws}',
                    Icons.handshake_outlined,
                    Colors.blueAccent,
                  ),
                  _StatCard(
                    'Golden Breaks',
                    '${stats.goldenBreaks + tournamentGoldenBreaks}',
                    Icons.star,
                    Colors.amber.shade700,
                  ),
                  _StatCard(
                    'Break & Run',
                    '${stats.breakAndRun + tournamentBreakAndRuns}',
                    Icons.flash_on,
                    Colors.purpleAccent,
                  ),
                  _StatCard(
                    'Combinación',
                    '$tournamentCombinations',
                    Icons.linear_scale,
                    Colors.cyanAccent,
                  ),
                  _StatCard(
                    'Por faltas',
                    '$tournamentWinsByFouls',
                    Icons.rule,
                    Colors.deepOrangeAccent,
                  ),
                  _StatCard(
                    'Juego normal',
                    '$tournamentNormalWins',
                    Icons.sports,
                    Colors.lightBlueAccent,
                  ),
                  _StatCard(
                    'Mejor Racha',
                    '${stats.bestStreak}',
                    Icons.local_fire_department,
                    Colors.orangeAccent,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 126,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: cs.surface,
                        border: Border.all(
                          color: Colors.amber.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'WIN RATE',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${winRate.toStringAsFixed(1)}%',
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 34,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '$totalWins ganadas de $totalMatches partidas',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                            maxLines: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _PlayerStatsIdentity(player: player),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PlayerStatsIdentity extends StatelessWidget {
  final PlayerEntity player;

  const _PlayerStatsIdentity({required this.player});

  @override
  Widget build(BuildContext context) {
    final avatarPath = player.avatar;
    final uri = Uri.tryParse(avatarPath);
    final isWebUrl =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    final image =
        avatarPath.isEmpty
            ? null
            : isWebUrl
            ? ScopedRemoteImage(
              url: avatarPath,
              width: 54,
              height: 54,
              fit: BoxFit.cover,
              error: _fallbackAvatar(),
            )
            : Image.file(
              File(avatarPath),
              width: 54,
              height: 54,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => _fallbackAvatar(),
            );

    return SizedBox(
      width: 126,
      height: 126,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ClipOval(child: image ?? _fallbackAvatar()),
            const SizedBox(height: 5),
            Text(
              player.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var index = 0; index < 6; index++)
                  Icon(
                    index < player.level
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color: index < player.level ? Colors.amber : Colors.white24,
                    size: 13,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _fallbackAvatar() => Container(
    width: 54,
    height: 54,
    alignment: Alignment.center,
    color: Colors.white10,
    child: Text(
      player.initials,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

class _HistoryTab extends StatelessWidget {
  final PlayerEntity player;
  const _HistoryTab({required this.player});

  @override
  Widget build(BuildContext context) {
    if (player.stats.totalMatches == 0) {
      return _EmptyTab('Sin partidas registradas', Icons.history);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Text(
        'Historial de partidas próximamente',
        style: TextStyle(color: Colors.white38),
      ),
    );
  }
}

class _TournamentsTab extends StatelessWidget {
  final PlayerEntity player;
  final Future<List<TournamentPlayerHistory>> tournamentHistory;
  final bool readOnly;
  const _TournamentsTab({
    required this.player,
    required this.tournamentHistory,
    required this.readOnly,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<TournamentPlayerHistory>>(
      future: tournamentHistory,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('No se pudo cargar el historial: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final history = snapshot.data!;
        if (history.isEmpty) {
          return _EmptyTab('Sin torneos jugados', Icons.emoji_events);
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final item in history)
              Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap:
                      readOnly
                          ? null
                          : () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder:
                                  (_) => TournamentDetailPage(
                                    tournament: item.tournament,
                                  ),
                            ),
                          ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.emoji_events, color: Colors.amber),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                item.tournament.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          item.placement,
                          style: const TextStyle(
                            color: Colors.amber,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            Text(
                              'Enfrentamientos ${item.matchesWon}-${item.matchesLost}',
                            ),
                            Text('Partidas ${item.gamesWon}-${item.gamesLost}'),
                            Text('Sets ganados ${item.setsWon}'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;
  final Color color;
  const _StatCard(this.label, this.value, this.icon, this.color);

  @override
  Widget build(BuildContext context) {
    Widget leading;
    if (icon != null) {
      leading = Icon(icon, color: color, size: 24);
    } else {
      leading = Text(
        label.isNotEmpty ? label.substring(0, 1) : '?',
        style: TextStyle(color: color, fontSize: 20),
      );
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          leading,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                label,
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white38,
        fontSize: 12,
        letterSpacing: 2,
      ),
    );
  }
}

class _EmptyTab extends StatelessWidget {
  final String text;
  final IconData icon;
  const _EmptyTab(this.text, this.icon);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Colors.white.withValues(alpha: 0.06)),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.2),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
