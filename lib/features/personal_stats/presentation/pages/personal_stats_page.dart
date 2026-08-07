import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../core/theme/theme_provider.dart';

class PersonalStatsPage extends StatefulWidget {
  const PersonalStatsPage({super.key});

  @override
  State<PersonalStatsPage> createState() => _PersonalStatsPageState();
}

class _PersonalStatsPageState extends State<PersonalStatsPage> {
  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ESTADÍSTICAS PERSONALES',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Sincronizando estadísticas...')),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle('RESUMEN GENERAL'),
            const SizedBox(height: 12),
            GridView.extent(
              maxCrossAxisExtent: 220,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.4,
              children: [
                _buildStatCard('Partidas', '0', Icons.sports_bar, primary),
                _buildStatCard('Victorias', '0', Icons.check_circle, Colors.greenAccent),
                _buildStatCard('Eficiencia', '0%', Icons.trending_up, Colors.orangeAccent),
                _buildStatCard('Golden Breaks', '0', Icons.star, Colors.amber),
              ],
            ),
            const SizedBox(height: 32),
            _buildSectionTitle('HISTORIAL RECIENTE'),
            const SizedBox(height: 12),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.white.withValues(alpha: 0.06)),
                  const SizedBox(height: 12),
                  Text(
                    'No hay historial registrado',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Juega partidas 1 vs 1 para ver tus estadísticas',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.12), fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 2),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    final style = context.watch<ThemeProvider>().cardStyle;
    final solid = style == CardStyle.solidWhite;
    final outlined = style == CardStyle.outlined;
    final contentColor = solid ? Colors.white.withValues(alpha: 0.92) : color;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: solid ? color : (outlined ? Theme.of(context).colorScheme.surface : null),
        gradient: (solid || outlined)
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  color.withValues(alpha: 0.15),
                  Theme.of(context).colorScheme.surface,
                ],
              ),
        border: Border.all(
          color: solid ? Colors.white.withValues(alpha: 0.28) : color.withValues(alpha: outlined ? 1.0 : 0.3),
          width: outlined ? 2 : 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: contentColor, size: 26),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(color: contentColor, fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: solid ? Colors.white.withValues(alpha: 0.75) : Colors.white.withValues(alpha: 0.4),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
