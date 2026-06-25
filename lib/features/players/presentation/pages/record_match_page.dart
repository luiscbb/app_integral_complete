import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/match_result.dart';
import '../../domain/entities/player_stats.dart';
import '../../presentation/providers/players_provider.dart';
import '../../data/repositories/match_repository.dart';

class RecordMatchPage extends StatefulWidget {
  const RecordMatchPage({super.key});

  @override
  State createState() => _RecordMatchPageState();
}

class _RecordMatchPageState extends State<RecordMatchPage> {
  String _gameType = 'Bola 8';
  PlayerEntity? _p1;
  PlayerEntity? _p2;
  PlayerEntity? _winner;
  bool _isDraw = false;
  bool _goldenBreak = false;
  bool _breakAndRun = false;
  final _notesCtrl = TextEditingController();
  final _repo = MatchRepository();

  static const _games = ['Bola 8', 'Bola 9', 'Bola 10', 'Carambola', 'Snooker', '14.1'];

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return ChangeNotifierProvider(
      create: (_) => PlayersProvider(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('REGISTRAR PARTIDA', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        ),
        body: Consumer<PlayersProvider>(
          builder: (_, provider, __) {
            if (provider.isLoading) return Center(child: CircularProgressIndicator(color: primary));
            final players = provider.players;

            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionTitle('MODALIDAD'),
                  Wrap(
                    spacing: 10,
                    children: _games.map((g) => ChoiceChip(
                      label: Text(g),
                      selected: _gameType == g,
                      onSelected: (_) => setState(() => _gameType = g),
                      selectedColor: primary.withValues(alpha: 0.25),
                      checkmarkColor: primary,
                      side: BorderSide(color: _gameType == g ? primary : Colors.white12),
                    )).toList(),
                  ),
                  const SizedBox(height: 24),
                  _SectionTitle('JUGADORES'),
                  const SizedBox(height: 12),
                  _PlayerPicker(label: 'Jugador 1', player: _p1, players: players, onPick: (p) => setState(() => _p1 = p)),
                  const SizedBox(height: 12),
                  _PlayerPicker(label: 'Jugador 2', player: _p2, players: players, onPick: (p) => setState(() => _p2 = p)),
                  const SizedBox(height: 24),
                  _SectionTitle('RESULTADO'),
                  const SizedBox(height: 12),
                  if (_p1 != null && _p2 != null) ...[
                    Wrap(
                      spacing: 10,
                      children: [
                        FilterChip(
                          label: Text('Gana ${_p1!.displayName}'),
                          selected: _winner == _p1 && !_isDraw,
                          onSelected: (_) => setState(() { _winner = _p1; _isDraw = false; }),
                        ),
                        FilterChip(
                          label: Text('Gana ${_p2!.displayName}'),
                          selected: _winner == _p2 && !_isDraw,
                          onSelected: (_) => setState(() { _winner = _p2; _isDraw = false; }),
                        ),
                        FilterChip(
                          label: const Text('Empate'),
                          selected: _isDraw,
                          onSelected: (_) => setState(() { _isDraw = true; _winner = null; }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      children: [
                        FilterChip(
                          label: const Text('Golden Break'),
                          selected: _goldenBreak,
                          onSelected: (_) => setState(() => _goldenBreak = !_goldenBreak),
                        ),
                        FilterChip(
                          label: const Text('Break & Run'),
                          selected: _breakAndRun,
                          onSelected: (_) => setState(() => _breakAndRun = !_breakAndRun),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  _SectionTitle('NOTAS (opcional)'),
                  TextField(
                    controller: _notesCtrl,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'Comentarios de la partida...',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: primary, padding: const EdgeInsets.symmetric(vertical: 18)),
                      icon: const Icon(Icons.save, color: Colors.white),
                      label: const Text('GUARDAR PARTIDA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1)),
                      onPressed: (_p1 != null && _p2 != null && (_winner != null || _isDraw)) ? _save : null,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _save() async {
    final match = MatchResult(
      gameType: _gameType,
      player1Id: _p1!.id!,
      player2Id: _p2!.id!,
      winnerId: _winner?.id,
      isDraw: _isDraw,
      goldenBreak: _goldenBreak,
      breakAndRun: _breakAndRun,
      notes: _notesCtrl.text.trim(),
    );
    await _repo.recordHeadToHead(match);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Partida guardada')));
      Navigator.pop(context);
    }
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: const TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 2)),
  );
}

class _PlayerPicker extends StatelessWidget {
  final String label;
  final PlayerEntity? player;
  final List<PlayerEntity> players;
  final ValueChanged<PlayerEntity> onPick;
  const _PlayerPicker({required this.label, required this.player, required this.players, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () async {
        final picked = await showModalBottomSheet<PlayerEntity>(
          context: context,
          backgroundColor: const Color(0xFF1A1A1A),
          builder: (_) => SafeArea(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: players.length,
              itemBuilder: (_, i) => ListTile(
                leading: CircleAvatar(backgroundColor: Colors.white10, child: Text(players[i].initials, style: const TextStyle(color: Colors.white))),
                title: Text(players[i].displayName, style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context, players[i]),
              ),
            ),
          ),
        );
        if (picked != null) onPick(picked);
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: Colors.white10,
              child: player == null
                  ? const Icon(Icons.person_add, color: Colors.white38)
                  : Text(player!.initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 12),
            Text(player?.displayName ?? label, style: TextStyle(color: player == null ? Colors.white38 : Colors.white, fontSize: 15)),
          ],
        ),
      ),
    );
  }
}
