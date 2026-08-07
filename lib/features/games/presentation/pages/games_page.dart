import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../../core/widgets/module_card.dart';
import '../providers/game_provider.dart';
import 'game_selection_screen.dart';

class GamesPage extends StatelessWidget {
  const GamesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => GameProvider(),
      child: const _GamesHub(),
    );
  }
}

class _GamesHub extends StatelessWidget {
  const _GamesHub();

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PARTIDAS', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
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
          itemCount: 2,
          itemBuilder: (_, i) {
            if (i == 0) {
              return ModuleCard(
                label: 'TRAINING',
                subtitle: 'Práctica libre',
                icon: Icons.sports_score,
                color: primary,
                onTap: () => _goToMatch(context, realMatch: false),
              );
            }
            return ModuleCard(
              label: '1 VS 1',
              subtitle: 'Jugadores reales',
              icon: Icons.people,
              color: primary,
              onTap: () => _goToMatch(context, realMatch: true),
            );
          },
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
        builder: (_) => ChangeNotifierProvider<GameProvider>.value(
          value: provider,
          child: const GameSelectionScreen(),
        ),
      ),
    );
  }
}
