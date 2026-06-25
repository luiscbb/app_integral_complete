import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/player_stats.dart';
import '../../presentation/providers/players_provider.dart';

class PlayerComparisonPage extends StatefulWidget {
  const PlayerComparisonPage({super.key});

  @override
  State<PlayerComparisonPage> createState() => _PlayerComparisonPageState();
}

class _PlayerComparisonPageState extends State<PlayerComparisonPage> {
  PlayerEntity? _p1;
  PlayerEntity? _p2;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ChangeNotifierProvider(
      create: (_) => PlayersProvider(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'COMPARACIÓN 1 VS 1',
            style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
          ),
        ),
        body: Consumer<PlayersProvider>(
          builder: (_, provider, __) {
            if (provider.isLoading) return Center(child: CircularProgressIndicator(color: primary));
            if (provider.players.length < 2) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.compare_arrows, size: 64, color: Colors.white.withValues(alpha: 0.06)),
                    const SizedBox(height: 16),
                    Text('Necesitas al menos 2 jugadores', style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 15)),
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _PlayerSelector(
                    players: provider.players,
                    selected: _p1,
                    onSelected: (p) => setState(() => _p1 = p),
                    label: 'JUGADOR 1',
                  ),
                  const SizedBox(height: 12),
                  _PlayerSelector(
                    players: provider.players,
                    selected: _p2,
                    onSelected: (p) => setState(() => _p2 = p),
                    label: 'JUGADOR 2',
                  ),
                  const SizedBox(height: 20),
                  if (_p1 != null && _p2 != null)
                    Expanded(child: _ComparisonTable(p1: _p1!, p2: _p2!)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PlayerSelector extends StatelessWidget {
  final List<PlayerEntity> players;
  final PlayerEntity? selected;
  final ValueChanged<PlayerEntity> onSelected;
  final String label;
  const _PlayerSelector({required this.players, required this.selected, required this.onSelected, required this.label});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.white10,
          child: selected == null
              ? const Icon(Icons.person, color: Colors.white54)
              : Text(selected!.initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
        title: Text(selected?.displayName ?? label, style: const TextStyle(color: Colors.white)),
        trailing: const Icon(Icons.arrow_drop_down, color: Colors.white54),
        onTap: () async {
          final picked = await showModalBottomSheet<PlayerEntity>(
            context: context,
            backgroundColor: const Color(0xFF1A1A1A),
            builder: (_) => SafeArea(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: players.length,
                itemBuilder: (_, i) {
                  final p = players[i];
                  return ListTile(
                    leading: CircleAvatar(backgroundColor: Colors.white10, child: Text(p.initials, style: const TextStyle(color: Colors.white))),
                    title: Text(p.displayName, style: const TextStyle(color: Colors.white)),
                    trailing: Text('${p.stats.wins}V', style: TextStyle(color: Colors.greenAccent)),
                    onTap: () => Navigator.pop(context, p),
                  );
                },
              ),
            ),
          );
          if (picked != null) onSelected(picked);
        },
      ),
    );
  }
}

class _ComparisonTable extends StatelessWidget {
  final PlayerEntity p1;
  final PlayerEntity p2;
  const _ComparisonTable({required this.p1, required this.p2});

  @override
  Widget build(BuildContext context) {
    final stats = [
      _ComparisonRow('Partidas', '${p1.stats.totalMatches}', '${p2.stats.totalMatches}'),
      _ComparisonRow('Victorias', '${p1.stats.wins}', '${p2.stats.wins}', greaterIsBetter: true),
      _ComparisonRow('Derrotas', '${p1.stats.losses}', '${p2.stats.losses}'),
      _ComparisonRow('Empates', '${p1.stats.draws}', '${p2.stats.draws}'),
      _ComparisonRow('Win Rate', p1.stats.formattedWinRate, p2.stats.formattedWinRate, greaterIsBetter: true),
      _ComparisonRow('Golden Breaks', '${p1.stats.goldenBreaks}', '${p2.stats.goldenBreaks}', greaterIsBetter: true),
      _ComparisonRow('Break & Run', '${p1.stats.breakAndRun}', '${p2.stats.breakAndRun}', greaterIsBetter: true),
      _ComparisonRow('Mejor Racha', '${p1.stats.bestStreak}', '${p2.stats.bestStreak}', greaterIsBetter: true),
      _ComparisonRow('Tiempo Total', p1.formattedTime, p2.formattedTime),
    ];

    return ListView.separated(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      itemCount: stats.length,
      separatorBuilder: (_, __) => const Divider(color: Colors.white10),
      itemBuilder: (_, i) => stats[i],
    );
  }
}

class _ComparisonRow extends StatelessWidget {
  final String label;
  final String v1;
  final String v2;
  final bool greaterIsBetter;
  const _ComparisonRow(this.label, this.v1, this.v2, {this.greaterIsBetter = false});

  @override
  Widget build(BuildContext context) {
    final p1Win = greaterIsBetter && _parse(v1) > _parse(v2);
    final p2Win = greaterIsBetter && _parse(v2) > _parse(v1);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              v1,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: p1Win ? Colors.greenAccent : Colors.white70,
                fontWeight: p1Win ? FontWeight.bold : FontWeight.normal,
                fontSize: 16,
              ),
            ),
          ),
          SizedBox(
            width: 120,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1),
            ),
          ),
          Expanded(
            child: Text(
              v2,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: p2Win ? Colors.greenAccent : Colors.white70,
                fontWeight: p2Win ? FontWeight.bold : FontWeight.normal,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  num _parse(String s) {
    final clean = s.replaceAll('%', '').replaceAll('h ', '').replaceAll('m', '');
    return num.tryParse(clean) ?? 0;
  }
}
