import 'package:flutter/material.dart';

import '../../../../core/routes/app_routes.dart';

class HomeModule {
  const HomeModule(
    this.label,
    this.icon,
    this.color,
    this.route,
    this.category,
  );

  final String label;
  final IconData icon;
  final Color color;
  final String route;
  final String category;
}

const homeModules = [
  HomeModule(
    'VENTA\nRÁPIDA',
    Icons.flash_on_rounded,
    Color(0xFFE53935),
    AppRoutes.quickSale,
    'Ventas',
  ),
  HomeModule(
    'MESAS\nBILLAR',
    Icons.table_bar_rounded,
    Color(0xFF1E88E5),
    AppRoutes.billiardTables,
    'Ventas',
  ),
  HomeModule(
    'COMANDAS',
    Icons.restaurant_rounded,
    Color(0xFFE91E63),
    AppRoutes.dineIn,
    'Ventas',
  ),
  HomeModule(
    'CUENTA\nPERSONAL',
    Icons.person_rounded,
    Color(0xFF00ACC1),
    AppRoutes.specialClient,
    'Ventas',
  ),
  HomeModule(
    'INVENTARIO',
    Icons.inventory_2_rounded,
    Color(0xFF43A047),
    AppRoutes.inventory,
    'Admin',
  ),
  HomeModule(
    'COMPRAS',
    Icons.shopping_cart_rounded,
    Color(0xFFFB8C00),
    AppRoutes.purchases,
    'Admin',
  ),
  HomeModule(
    'INFORMES',
    Icons.bar_chart_rounded,
    Color(0xFF8E24AA),
    AppRoutes.reports,
    'Admin',
  ),
  HomeModule(
    'JUGADORES\nTORNEOS',
    Icons.sports_esports_rounded,
    Color(0xFF00ACC1),
    AppRoutes.playersHub,
    'Juego',
  ),
  HomeModule(
    'CONFIGURACIÓN',
    Icons.settings_suggest_rounded,
    Color(0xFF78909C),
    AppRoutes.config,
    'Admin',
  ),
];
