import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../core/routes/app_routes.dart';
import '../../presentation/providers/players_provider.dart';
import '../../presentation/widgets/player_card.dart';
import 'add_player_page.dart';

class PlayersListPage extends StatelessWidget {
  const PlayersListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(create: (_) => PlayersProvider(), child: const _Content());
  }
}

class _Content extends StatelessWidget {
  const _Content();

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final provider = context.read<PlayersProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'JUGADORES',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.sports_score),
            tooltip: 'Registrar partida',
            onPressed: () => Navigator.pushNamed(context, AppRoutes.recordMatch),
          ),
          IconButton(
            icon: const Icon(Icons.compare_arrows),
            tooltip: 'Comparar 1 vs 1',
            onPressed: () => Navigator.pushNamed(context, AppRoutes.playerComparison),
          ),
        ],
      ),
      body: Consumer<PlayersProvider>(
        builder: (context, prov, child) {
          if (prov.isLoading) {
            return Center(child: CircularProgressIndicator(color: primary));
          }
          if (prov.players.isEmpty) {
            return _EmptyState(onAdd: () => _showAddDialog(context, provider));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: prov.players.length,
            itemBuilder: (_, i) {
              final p = prov.players[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PlayerCard(
                  player: p,
                  showActions: true,
                  onRecordWin: () => prov.recordWin(p.id!),
                  onRecordLoss: () => prov.recordLoss(p.id!),
                  onTap: () => Navigator.pushNamed(context, AppRoutes.playerDetail, arguments: p),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: primary,
        icon: const Icon(Icons.person_add),
        label: const Text('AGREGAR'),
        onPressed: () => _showAddDialog(context, provider),
      ),
    );
  }

  void _showAddDialog(BuildContext ctx, PlayersProvider playersProvider) {
    Navigator.push(
      ctx,
      MaterialPageRoute(
        builder: (_) => AddPlayerPage(playersProvider: playersProvider),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.group_outlined, size: 64, color: Colors.white.withValues(alpha: 0.06)),
          const SizedBox(height: 16),
          Text(
            'No hay jugadores registrados',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 15),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.person_add),
            label: const Text('AGREGAR PRIMER JUGADOR'),
          ),
        ],
      ),
    );
  }
}
