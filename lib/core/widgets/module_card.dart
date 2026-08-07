import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/theme_provider.dart';

class ModuleCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String? subtitle;
  final int? badgeCount;

  const ModuleCard({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.subtitle,
    this.badgeCount,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = context.watch<ThemeProvider>().cardStyle;
    final solid = style == CardStyle.solidWhite;
    final outlined = style == CardStyle.outlined;

    // Sólido blanco: fondo plano con el color dominante y contenido en
    // blanco suavizado. Contorno de color: fondo neutro con borde y
    // contenido en el color dominante. Degradado: estilo original.
    final decorationBox = solid
        ? BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: color,
            border: Border.all(color: Colors.white.withValues(alpha: 0.28), width: 1.5),
          )
        : outlined
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: cs.surface,
                border: Border.all(color: color, width: 2),
              )
            : BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    color.withValues(alpha: 0.18),
                    cs.surface,
                  ],
                ),
                border: Border.all(color: color.withValues(alpha: 0.35), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.12),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              );

    // Blanco suavizado (no puro) en modo sólido: mantiene alto contraste
    // pero evita el brillo/glare de un #FFFFFF sobre un color saturado.
    final contentColor = solid ? Colors.white.withValues(alpha: 0.92) : color;
    final subtitleColor = solid ? Colors.white.withValues(alpha: 0.75) : Colors.white38;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Ink(
        decoration: decorationBox,
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(icon, size: 44, color: contentColor),
                    const SizedBox(height: 10),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: contentColor,
                        letterSpacing: 0.5,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, color: subtitleColor),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (badgeCount != null && badgeCount! > 0)
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: cs.primary.withValues(alpha: 0.4),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: Text(
                    '$badgeCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
