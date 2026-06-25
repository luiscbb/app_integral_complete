import 'package:flutter/material.dart';
import '../../domain/entities/player_stats.dart';

class PlayerDetailPage extends StatelessWidget {
  final PlayerEntity player;
  const PlayerDetailPage({super.key, required this.player});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(player.displayName),
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
            _StatsTab(player: player),
            _HistoryTab(player: player),
            _TournamentsTab(player: player),
          ],
        ),
      ),
    );
  }
}

class _StatsTab extends StatelessWidget {
  final PlayerEntity player;
  const _StatsTab({required this.player});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stats = player.stats;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle('RESUMEN'),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.3,
            children: [
              _StatCard('Partidas', '${stats.totalMatches}', Icons.sports_bar, Colors.white70),
              _StatCard('Victorias', '${stats.wins}', Icons.emoji_events, Colors.greenAccent),
              _StatCard('Derrotas', '${stats.losses}', Icons.close, Colors.redAccent),
              _StatCard('Empates', '${stats.draws}', Icons.handshake_outlined, Colors.blueAccent),
              _StatCard('Win Rate', stats.formattedWinRate, Icons.trending_up, Colors.amber),
              _StatCard('Golden Breaks', '${stats.goldenBreaks}', Icons.star, Colors.amber.shade700),
              _StatCard('Break & Run', '${stats.breakAndRun}', Icons.flash_on, Colors.purpleAccent),
              _StatCard('Mejor Racha', '${stats.bestStreak}', Icons.local_fire_department, Colors.orangeAccent),
            ],
          ),
          const SizedBox(height: 24),
          _SectionTitle('TIEMPO JUGADO'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: cs.surface,
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              children: [
                Icon(Icons.timer, color: Colors.white70, size: 40),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      player.formattedTime,
                      style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                    ),
                    Text('Tiempo total', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
      child: Text('Historial de partidas próximamente', style: TextStyle(color: Colors.white38)),
    );
  }
}

class _TournamentsTab extends StatelessWidget {
  final PlayerEntity player;
  const _TournamentsTab({required this.player});

  @override
  Widget build(BuildContext context) {
    return _EmptyTab('Sin torneos jugados', Icons.emoji_events);
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
      leading = Text(label.isNotEmpty ? label.substring(0, 1) : '?', 
          style: TextStyle(color: color, fontSize: 20));
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
              Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold)),
              Text(label, style: TextStyle(color: Colors.white54, fontSize: 11)),
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
    return Text(text, style: const TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 2));
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
          Text(text, style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 14)),
        ],
      ),
    );
  }
}
