import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/game_provider.dart';

class GameScreen extends StatelessWidget {
  const GameScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final gameProv = context.watch<GameProvider>();
    final primary = Theme.of(context).colorScheme.primary;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _showExitConfirmation(context);
        if (shouldPop ?? false) {
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            gameProv.gameType.toUpperCase(),
            style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 14),
          ),
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () async {
              final shouldPop = await _showExitConfirmation(context);
              if (shouldPop ?? false) {
                if (context.mounted) Navigator.of(context).pop();
              }
            },
          ),
        ),
        body: Column(
          children: [
            _buildTargetSelector(gameProv, primary),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    _buildScoreBoard(gameProv, primary),
                    if (gameProv.gameType == 'Bola 8') ...[
                      const SizedBox(height: 12),
                      _buildEarlyEightButton(context, gameProv, primary),
                    ],
                    const SizedBox(height: 10),
                    const Divider(color: Colors.white10, indent: 30, endIndent: 30),
                    const SizedBox(height: 10),
                    _buildBallGrid(gameProv, primary),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
            ),
            _buildActionButtons(context, gameProv, primary),
          ],
        ),
      ),
    );
  }

  Widget _buildBallGrid(GameProvider gameProv, Color primary) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 90,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1,
      ),
      itemCount: gameProv.maxBalls,
      itemBuilder: (context, index) {
        final num = index + 1;
        final isPotted = gameProv.pottedBalls.contains(num);
        final isTargetBall =
            (gameProv.gameType == 'Bola 9' && num == 9) ||
            (gameProv.gameType == 'Bola 10' && num == 10) ||
            (gameProv.gameType == 'Bola 8' && num == 8);
        final activeColor = isTargetBall ? Colors.amber : Colors.green;

        return GestureDetector(
          onTap: () {
            HapticFeedback.mediumImpact();
            gameProv.toggleBall(num);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(21),
              color: isPotted ? Colors.transparent : Colors.white.withValues(alpha: 0.03),
              border: Border.all(
                color: isPotted ? activeColor : Colors.white.withValues(alpha: 0.15),
                width: isPotted ? 3 : 1.5,
              ),
              boxShadow:
                  isPotted
                      ? [
                        BoxShadow(
                          color:
                              isTargetBall
                                  ? Colors.amber.withValues(alpha: 0.6)
                                  : Colors.green.withValues(alpha: 0.6),
                          blurRadius: 15,
                          spreadRadius: 2,
                        ),
                      ]
                      : [],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ColorFiltered(
                colorFilter:
                    isPotted
                        ? const ColorFilter.mode(Colors.transparent, BlendMode.multiply)
                        : const ColorFilter.matrix(<double>[
                          0.45,
                          0.25,
                          0.15,
                          0,
                          0,
                          0.45,
                          0.25,
                          0.15,
                          0,
                          0,
                          0.45,
                          0.25,
                          0.15,
                          0,
                          0,
                          0,
                          0,
                          0,
                          1,
                          0,
                        ]),
                child: Image.asset(
                  'assets/balls/bola_$num.png',
                  fit: BoxFit.cover,
                  errorBuilder:
                      (_, _, _) => Center(
                        child: Text(
                          '$num',
                          style: TextStyle(
                            color: isPotted ? Colors.white : Colors.grey[800],
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildScoreBoard(GameProvider gameProv, Color primary) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _scoreItem(gameProv.player1Name, gameProv.playerSets, primary),
        _accuracyCircle(gameProv.accuracy, primary),
        _scoreItem(gameProv.player2Name, gameProv.opponentSets, Colors.redAccent),
      ],
    );
  }

  Widget _scoreItem(String label, int score, Color color) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
        ),
        Text('$score', style: TextStyle(color: color, fontSize: 45, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _accuracyCircle(double acc, Color color) {
    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 55,
              height: 55,
              child: CircularProgressIndicator(
                value: acc / 100,
                color: color,
                backgroundColor: Colors.white10,
                strokeWidth: 5,
              ),
            ),
            Text(
              '${acc.toStringAsFixed(0)}%',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'PUNTERÍA',
          style: TextStyle(color: Colors.white, fontSize: 8, letterSpacing: 1.5),
        ),
      ],
    );
  }

  Widget _buildTargetSelector(GameProvider gameProv, Color primary) {
    return Container(
      height: 50,
      margin: const EdgeInsets.symmetric(vertical: 10),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        children:
            gameProv.targetOptions.map((opt) {
              final isSelected = gameProv.targetSets == opt;
              return GestureDetector(
                onTap: () => gameProv.setTargetSets(opt),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: isSelected ? primary : Colors.white10,
                    borderRadius: BorderRadius.circular(25),
                  ),
                  child: Center(
                    child: Text(
                      opt == 0 ? 'LIBRE' : 'A $opt',
                      style: TextStyle(
                        color: isSelected ? Colors.black : Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context, GameProvider gameProv, Color primary) {
    return Container(
      padding: const EdgeInsets.fromLTRB(25, 20, 25, 35),
      decoration: const BoxDecoration(
        color: Color(0xFF0D0D0D),
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => _showRivalWinConfirm(context, gameProv, primary),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
              child: const Text('RIVAL GANÓ', style: TextStyle(color: Colors.red, fontSize: 12)),
            ),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: ElevatedButton(
              onPressed:
                  gameProv.canFinishSet
                      ? () async {
                        final isGolden = gameProv.isGoldenBreak;
                        final finished = await gameProv.incrementPlayerSet();
                        if (context.mounted) {
                          _showSummaryDialog(
                            context,
                            gameProv,
                            isGolden: isGolden,
                            isMatchFinished: finished,
                            isRivalWin: false,
                          );
                        }
                      }
                      : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: primary,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                elevation: 0,
              ),
              child: const Text(
                '¡GANE EL SET!',
                style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEarlyEightButton(BuildContext context, GameProvider gameProv, Color primary) {
    return TextButton.icon(
      onPressed: () => _showConfirmEightLoss(context, gameProv, primary),
      icon: const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 20),
      label: const Text(
        'METÍ LA 8 POR ERROR',
        style: TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold),
      ),
      style: TextButton.styleFrom(
        backgroundColor: Colors.orangeAccent.withValues(alpha: 0.15),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void _showRivalWinConfirm(BuildContext context, GameProvider gameProv, Color primary) {
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1B1B1B),
            title: const Text(
              '¿Rival ganó el rack?',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('NO', style: TextStyle(color: Colors.grey)),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final matchFinished = await gameProv.incrementOpponentSet();
                  if (context.mounted) {
                    _showSummaryDialog(
                      context,
                      gameProv,
                      isGolden: false,
                      isMatchFinished: matchFinished,
                      isRivalWin: true,
                    );
                  }
                },
                child: Text('SÍ', style: TextStyle(color: primary)),
              ),
            ],
          ),
    );
  }

  void _showConfirmEightLoss(BuildContext context, GameProvider gameProv, Color primary) {
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1B1B1B),
            title: const Text(
              '¿Derrota por Bola 8?',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
            content: const Text(
              'Confirmas que la bola 8 entró antes de tiempo.',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('CANCELAR', style: TextStyle(color: Colors.grey)),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await gameProv.loseByEarlyEight();
                  final matchFinished = await gameProv.incrementOpponentSet();
                  if (context.mounted) {
                    _showSummaryDialog(
                      context,
                      gameProv,
                      isGolden: false,
                      isMatchFinished: matchFinished,
                      isRivalWin: true,
                      isEightLoss: true,
                    );
                  }
                },
                child: const Text('SÍ, PERDÍ', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
    );
  }

  void _showSummaryDialog(
    BuildContext context,
    GameProvider provider, {
    required bool isGolden,
    required bool isMatchFinished,
    required bool isRivalWin,
    bool isEightLoss = false,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF141414),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(25),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
            ),
            title: Text(
              isEightLoss
                  ? 'DERROTA BOLA 8'
                  : (isRivalWin
                      ? 'SET RIVAL'
                      : (isGolden && provider.gameType == 'Bola 9'
                          ? '¡GOLDEN BREAK!'
                          : '¡SET TUYO!')),
              textAlign: TextAlign.center,
              style: TextStyle(
                color:
                    isEightLoss
                        ? Colors.orange
                        : (isGolden && provider.gameType == 'Bola 9'
                            ? Colors.amber
                            : (isRivalWin ? Colors.white : primary)),
                fontWeight: FontWeight.bold,
                fontSize: 18,
                letterSpacing: 1,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Text(
                  '${provider.playerSets} - ${provider.opponentSets}',
                  style: const TextStyle(
                    fontSize: 55,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                if (isMatchFinished)
                  Padding(
                    padding: const EdgeInsets.only(top: 15),
                    child: Text(
                      'PARTIDA FINALIZADA',
                      style: TextStyle(
                        color: primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                        letterSpacing: 3,
                      ),
                    ),
                  ),
              ],
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Center(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      if (isMatchFinished) {
                        provider.resetMatch();
                        Navigator.pop(context);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isGolden ? Colors.amber : primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
                    ),
                    child: Text(
                      isMatchFinished ? 'SALIR AL MENÚ' : 'SIGUIENTE RACK',
                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            ],
          ),
    );
  }

  Future<bool?> _showExitConfirmation(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1B1B1B),
            title: const Text('¿Abandonar?', style: TextStyle(color: Colors.white, fontSize: 18)),
            content: const Text(
              'El progreso actual no se guardará.',
              style: TextStyle(color: Colors.grey),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('VOLVER', style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'SALIR',
                  style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
    );
  }
}
