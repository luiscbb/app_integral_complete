import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/game_provider.dart';
import 'game_screen.dart';

class GameSelectionScreen extends StatelessWidget {
  const GameSelectionScreen({super.key});

  static const _modes = [
    ('BOLA 8', 'Bola 8', 'assets/balls/bola_8.png', Colors.white),
    ('BOLA 9', 'Bola 9', 'assets/balls/bola_9.png', Colors.amber),
    ('BOLA 10', 'Bola 10', 'assets/balls/bola_10.png', Colors.blueAccent),
  ];

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'NUEVA PARTIDA',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'MODALIDAD',
              style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
            ),
            const SizedBox(height: 12),
            _ModeCard(
              title: 'TRAINING',
              subtitle: 'Práctica libre sin guardar jugadores',
              icon: Icons.sports_score,
              color: primary,
              onTap: () => _goToMatch(context, realMatch: false),
            ),
            const SizedBox(height: 12),
            _ModeCard(
              title: '1 VS 1 REAL',
              subtitle: 'Registra partida entre jugadores',
              icon: Icons.people,
              color: primary,
              onTap: () => _goToMatch(context, realMatch: true),
            ),
            const SizedBox(height: 28),
            Text(
              'TIPO DE JUEGO',
              style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: _modes.length,
                itemBuilder: (_, i) {
                  final (title, mode, image, color) = _modes[i];
                  return _GameCard(
                    title: title,
                    mode: mode,
                    imagePath: image,
                    color: color,
                    onTap: () => context.read<GameProvider>().setGameType(mode),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _goToMatch(BuildContext context, {required bool realMatch}) {
    final provider = context.read<GameProvider>();
    if (realMatch) {
      provider.setPlayers(player1Name: 'LOCAL', player2Name: 'VISITA');
    } else {
      provider.setPlayers();
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => ChangeNotifierProvider<GameProvider>.value(
              value: provider,
              child: const GameScreen(),
            ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ModeCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: color, size: 16),
          ],
        ),
      ),
    );
  }
}

class _GameCard extends StatelessWidget {
  final String title;
  final String mode;
  final String imagePath;
  final Color color;
  final VoidCallback onTap;

  const _GameCard({
    required this.title,
    required this.mode,
    required this.imagePath,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final selected = context.watch<GameProvider>().gameType == mode;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? color : color.withValues(alpha: 0.2),
            width: selected ? 2.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color.withValues(alpha: 0.3)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Image.asset(
                  imagePath,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Icon(Icons.help, color: color),
                ),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    selected ? 'Seleccionado' : 'Tocar para seleccionar',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (selected) Icon(Icons.check_circle, color: color, size: 26),
          ],
        ),
      ),
    );
  }
}
