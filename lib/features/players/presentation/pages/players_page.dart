import 'dart:async';
import 'package:flutter/material.dart';

class PlayersPage extends StatefulWidget {
  const PlayersPage({super.key});

  @override
  State<PlayersPage> createState() => _PlayersPageState();
}

class _PlayersPageState extends State<PlayersPage> {
  final List<_PlayerTimer> _players = [];
  final _nameCtrl = TextEditingController();

  void _addPlayer() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() => _players.add(_PlayerTimer(name: name)));
    _nameCtrl.clear();
  }

  void _removePlayer(int index) {
    _players[index].stop();
    setState(() => _players.removeAt(index));
  }

  @override
  void dispose() {
    for (final p in _players) {
      p.stop();
    }
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'JUGADORES',
          style: TextStyle(color: Color(0xFF00ACC1), fontWeight: FontWeight.bold),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Nombre del jugador',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _addPlayer(),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00ACC1),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('AGREGAR'),
                  onPressed: _addPlayer,
                ),
              ],
            ),
          ),
          Expanded(
            child:
                _players.isEmpty
                    ? const Center(
                      child: Text('Sin jugadores', style: TextStyle(color: Colors.white24)),
                    )
                    : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _players.length,
                      itemBuilder:
                          (_, i) =>
                              _PlayerCard(player: _players[i], onRemove: () => _removePlayer(i)),
                    ),
          ),
        ],
      ),
    );
  }
}

class _PlayerTimer {
  final String name;
  int seconds = 0;
  bool running = false;
  Timer? _timer;

  _PlayerTimer({required this.name});

  void toggle() {
    if (running) {
      _timer?.cancel();
      running = false;
    } else {
      running = true;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => seconds++);
    }
  }

  void reset() {
    _timer?.cancel();
    running = false;
    seconds = 0;
  }

  void stop() {
    _timer?.cancel();
    running = false;
  }

  String get formattedTime {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _PlayerCard extends StatefulWidget {
  final _PlayerTimer player;
  final VoidCallback onRemove;
  const _PlayerCard({required this.player, required this.onRemove});

  @override
  State<_PlayerCard> createState() => _PlayerCardState();
}

class _PlayerCardState extends State<_PlayerCard> {
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: const Color(0xFF00ACC1).withValues(alpha: 0.2),
              child: Text(
                p.name[0].toUpperCase(),
                style: const TextStyle(color: Color(0xFF00ACC1), fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.name,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    p.formattedTime,
                    style: TextStyle(
                      color: p.running ? Colors.greenAccent : Colors.white38,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                p.running ? Icons.pause_circle : Icons.play_circle,
                color: const Color(0xFF00ACC1),
                size: 36,
              ),
              onPressed: () => setState(() => p.toggle()),
            ),
            IconButton(
              icon: const Icon(Icons.restart_alt, color: Colors.white38),
              onPressed: () => setState(() => p.reset()),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.red),
              onPressed: widget.onRemove,
            ),
          ],
        ),
      ),
    );
  }
}
