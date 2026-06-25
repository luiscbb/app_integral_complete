import 'package:flutter/material.dart';
import '../../core/storage/preferences_service.dart';

class ThemeProvider extends ChangeNotifier {
  bool _isDark = true;
  Color _primaryColor = const Color(0xFFE53935);

  bool get isDark => _isDark;
  Color get primaryColor => _primaryColor;

  void init() {
    final prefs = PreferencesService();
    _isDark = prefs.isDarkTheme;
    _primaryColor = Color(prefs.primaryColorValue);
  }

  ThemeData get currentTheme => _buildTheme();

  ThemeData _buildTheme() {
    final bg = _isDark ? const Color(0xFF000000) : const Color(0xFFF5F5F5);
    final surface = _isDark ? const Color(0xFF121212) : Colors.white;
    final card = _isDark ? const Color(0xFF1A1A1A) : const Color(0xFFFAFAFA);

    return ThemeData(
      useMaterial3: true,
      brightness: _isDark ? Brightness.dark : Brightness.light,
      scaffoldBackgroundColor: bg,
      cardColor: card,
      colorScheme: ColorScheme(
        brightness: _isDark ? Brightness.dark : Brightness.light,
        primary: _primaryColor,
        onPrimary: Colors.white,
        secondary: _primaryColor.withValues(alpha: 0.7),
        onSecondary: Colors.white,
        error: Colors.red,
        onError: Colors.white,
        surface: surface,
        onSurface: _isDark ? Colors.white : Colors.black87,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: _isDark ? Colors.white : Colors.black87,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
        iconTheme: IconThemeData(color: _isDark ? Colors.white : Colors.black87),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _primaryColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: _primaryColor,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _primaryColor,
          side: BorderSide(color: _primaryColor),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: _primaryColor,
        linearTrackColor: _primaryColor.withValues(alpha: 0.2),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: _primaryColor,
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: TextStyle(color: _isDark ? Colors.white : Colors.black87),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: _primaryColor.withValues(alpha: 0.15),
        selectedColor: _primaryColor,
        labelStyle: TextStyle(color: _isDark ? Colors.white : Colors.black87),
        secondaryLabelStyle: TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: (_isDark ? Colors.white : Colors.black).withValues(alpha: 0.05),
        labelStyle: TextStyle(color: _isDark ? Colors.white54 : Colors.black54),
        hintStyle: TextStyle(color: _isDark ? Colors.white24 : Colors.black26),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        prefixIconColor: _primaryColor,
      ),
      dividerTheme: DividerThemeData(color: _isDark ? Colors.white10 : Colors.black12),
      cardTheme: CardThemeData(
        color: card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 2,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: card,
        selectedIconTheme: IconThemeData(color: _primaryColor),
        unselectedIconTheme: IconThemeData(color: _isDark ? Colors.white38 : Colors.black38),
        selectedLabelTextStyle: TextStyle(color: _primaryColor, fontWeight: FontWeight.bold),
        unselectedLabelTextStyle: TextStyle(color: _isDark ? Colors.white38 : Colors.black38),
      ),
    );
  }

  void toggleTheme() {
    _isDark = !_isDark;
    PreferencesService().isDarkTheme = _isDark;
    notifyListeners();
  }

  void setPrimaryColor(Color color) {
    _primaryColor = color;
    PreferencesService().primaryColorValue = color.toARGB32();
    notifyListeners();
  }
}
