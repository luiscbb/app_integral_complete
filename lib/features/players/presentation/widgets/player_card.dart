import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/player_stats.dart';
import '../../../../core/theme/theme_provider.dart';

class PlayerCard extends StatelessWidget {
  final PlayerEntity player;
  final VoidCallback? onTap;
  final VoidCallback? onRecordWin;
  final VoidCallback? onRecordLoss;
  final bool showActions;

  const PlayerCard({
    super.key,
    required this.player,
    this.onTap,
    this.onRecordWin,
    this.onRecordLoss,
    this.showActions = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = context.watch<ThemeProvider>().cardStyle;
    final solid = style == CardStyle.solidWhite;
    final outlined = style == CardStyle.outlined;
    final contentColor = solid ? Colors.white.withValues(alpha: 0.92) : _levelColor;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: solid ? _levelColor : (outlined ? Theme.of(context).colorScheme.surface : null),
          gradient: (solid || outlined)
              ? null
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_levelColor.withValues(alpha: 0.15), Theme.of(context).colorScheme.surface],
                ),
          border: Border.all(
            color: solid ? Colors.white.withValues(alpha: 0.28) : _levelColor.withValues(alpha: outlined ? 1.0 : 0.3),
            width: outlined ? 2 : 1.0,
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Avatar(player: player),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        player.displayName,
                        style: TextStyle(
                          color: solid ? Colors.white.withValues(alpha: 0.92) : Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        player.levelLabel,
                        style: TextStyle(
                          color: contentColor,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  player.stats.formattedWinRate,
                  style: TextStyle(color: contentColor, fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _StatBadge(Icons.emoji_events, '${player.stats.wins}', Colors.greenAccent),
                const SizedBox(width: 8),
                _StatBadge(Icons.close, '${player.stats.losses}', Colors.redAccent),
                const SizedBox(width: 8),
                _StatBadge(Icons.schedule, player.formattedTime, Colors.white54),
                const Spacer(),
                if (showActions) ...[
                  IconButton(
                    icon: const Icon(Icons.add_circle, color: Colors.greenAccent),
                    onPressed: onRecordWin,
                    tooltip: 'Victoria',
                    iconSize: 28,
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove_circle, color: Colors.redAccent),
                    onPressed: onRecordLoss,
                    tooltip: 'Derrota',
                    iconSize: 28,
                  ),
                ],
              ],
            ),
            if (player.stats.currentStreak > 1)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.local_fire_department, color: Colors.orangeAccent, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      'Racha de ${player.stats.currentStreak}',
                      style: TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color get _levelColor {
    return switch (player.level) {
      1 => Colors.grey,
      2 => Colors.blueAccent,
      3 => Colors.greenAccent,
      4 => Colors.purpleAccent,
      _ => Colors.amber,
    };
  }
}

class _Avatar extends StatelessWidget {
  final PlayerEntity player;
  const _Avatar({required this.player});

  @override
  Widget build(BuildContext context) {
    final avatarPath = player.avatar;

    if (avatarPath.isNotEmpty) {
      final uri = Uri.tryParse(avatarPath);
      final isWebUrl = uri != null && (uri.scheme == 'http' || uri.scheme == 'https');

      if (isWebUrl) {
        return ClipOval(
          child: Image.network(
            avatarPath,
            width: 48,
            height: 48,
            cacheWidth: 128,
            cacheHeight: 128,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => _FallbackAvatar(player: player),
          ),
        );
      }

      return ClipOval(
        child: Image.file(
          File(avatarPath),
          width: 48,
          height: 48,
          cacheWidth: 128,
          cacheHeight: 128,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _FallbackAvatar(player: player),
        ),
      );
    }

    return _FallbackAvatar(player: player);
  }
}

class _FallbackAvatar extends StatelessWidget {
  final PlayerEntity player;
  const _FallbackAvatar({required this.player});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 24,
      backgroundColor: Colors.white10,
      child: Text(
        player.initials,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 18,
        ),
      ),
    );
  }
}

class _StatBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _StatBadge(this.icon, this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
  }
}
