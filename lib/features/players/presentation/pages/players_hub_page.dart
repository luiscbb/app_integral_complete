import 'package:flutter/material.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../../core/widgets/module_card.dart';

class PlayersHubPage extends StatelessWidget {
  const PlayersHubPage({super.key});

  static const _modules = [
    _Module('JUGADORES', Icons.sports_esports_rounded, Color(0xFF00ACC1), AppRoutes.players),
    _Module('PARTIDAS', Icons.sports_bar_rounded, Color(0xFF7C4DFF), AppRoutes.games),
    _Module('STATS PERS.', Icons.trending_up_rounded, Color(0xFF00BFA5), AppRoutes.personalStats),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'GESTIÓN DE JUGADORES',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 210,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 1,
          ),
          itemCount: _modules.length,
          itemBuilder: (_, i) {
            final m = _modules[i];
            return ModuleCard(
              label: m.label,
              icon: m.icon,
              color: m.color,
              onTap: () => Navigator.pushNamed(context, m.route),
            );
          },
        ),
      ),
    );
  }
}

class _Module {
  final String label;
  final IconData icon;
  final Color color;
  final String route;
  const _Module(this.label, this.icon, this.color, this.route);
}
