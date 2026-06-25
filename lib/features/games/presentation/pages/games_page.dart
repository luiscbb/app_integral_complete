import 'package:flutter/material.dart';
import '../../../../core/routes/app_routes.dart';

class GamesPage extends StatefulWidget {
  const GamesPage({super.key});

  @override
  State<GamesPage> createState() => _GamesPageState();
}

class _GamesPageState extends State<GamesPage> {
  int _selectedGame = 0;

  static const _games = [
    _GameInfo('BOLA 8', Icons.sports_bar, Color(0xFF4CAF50), 'Partida clásica de bola 8'),
    _GameInfo('BOLA 9', Icons.circle_outlined, Color(0xFFFF9800), 'Rápida y técnica'),
    _GameInfo('BOLA 10', Icons.looks_3, Color(0xFF2196F3), 'Estrategia pura'),
    _GameInfo('CARAMBOLA', Icons.control_point, Color(0xFF9C27B0), '3 bandas'),
    _GameInfo('SNOOKER', Icons.sports_baseball, Color(0xFF00BCD4), '15 rojas'),
    _GameInfo('14.1', Icons.filter_1, Color(0xFFE91E63), 'Tiro continuo'),
  ];

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'PARTIDAS 1 VS 1',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(20),
        itemCount: _games.length,
        itemBuilder: (_, i) {
          final g = _games[i];
          final sel = _selectedGame == i;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() => _selectedGame = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      sel ? g.color.withValues(alpha: 0.25) : cs.surface,
                      cs.surface,
                    ],
                  ),
                  border: Border.all(
                    color: sel ? g.color : Colors.white10,
                    width: sel ? 2 : 1,
                  ),
                  boxShadow: sel
                      ? [
                          BoxShadow(
                            color: g.color.withValues(alpha: 0.15),
                            blurRadius: 14,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: g.color.withValues(alpha: 0.15),
                          border: Border.all(
                            color: g.color.withValues(alpha: 0.4),
                            width: 1.5,
                          ),
                        ),
                        child: Icon(g.icon, color: g.color, size: 28),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              g.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              g.desc,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.45),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        sel ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                        color: sel ? g.color : Colors.white24,
                        size: 28,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: primary,
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('INICIAR PARTIDA'),
        onPressed: () => Navigator.pushNamed(context, AppRoutes.recordMatch),
      ),
    );
  }
}

class _GameInfo {
  final String name;
  final IconData icon;
  final Color color;
  final String desc;
  const _GameInfo(this.name, this.icon, this.color, this.desc);
}
