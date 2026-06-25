import 'package:flutter/material.dart';

class AppTheme {
  static const Color _primaryRed = Color(0xFFE53935);
  static const Color _darkBg = Color(0xFF000000);
  static const Color _darkSurface = Color(0xFF121212);
  static const Color _darkCard = Color(0xFF1A1A1A);

  static final ThemeData darkRedTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: _darkBg,
    cardColor: _darkCard,
    colorScheme: const ColorScheme.dark(
      primary: _primaryRed,
      secondary: Color(0xFFB71C1C),
      surface: _darkSurface,
      onPrimary: Colors.white,
      onSurface: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: _darkBg,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
      ),
      iconTheme: IconThemeData(color: Colors.white),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.05),
      labelStyle: const TextStyle(color: Colors.white54),
      hintStyle: const TextStyle(color: Colors.white24),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      prefixIconColor: _primaryRed,
    ),
    dividerTheme: const DividerThemeData(color: Colors.white10),
    cardTheme: CardThemeData(
      color: _darkCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 2,
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: _darkCard,
      selectedIconTheme: IconThemeData(color: _primaryRed),
      unselectedIconTheme: IconThemeData(color: Colors.white38),
      selectedLabelTextStyle: TextStyle(color: _primaryRed, fontWeight: FontWeight.bold),
      unselectedLabelTextStyle: TextStyle(color: Colors.white38),
    ),
  );

  static final ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(seedColor: _primaryRed),
    appBarTheme: const AppBarTheme(centerTitle: false),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
