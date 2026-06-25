import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  static final PreferencesService _instance = PreferencesService._internal();
  factory PreferencesService() => _instance;
  PreferencesService._internal();

  SharedPreferences? _prefs;

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (e) {
      if (kDebugMode) debugPrint('[PreferencesService] Error: $e');
    }
  }

  String get businessName => _prefs?.getString('business_name') ?? 'MI BILLAR';
  set businessName(String v) => _prefs?.setString('business_name', v);

  String get userName => _prefs?.getString('user_name') ?? 'Administrador';
  set userName(String v) => _prefs?.setString('user_name', v);

  String get billarId => _prefs?.getString('billar_id') ?? 'BILLAR_001';
  set billarId(String v) => _prefs?.setString('billar_id', v);

  String get logoPath => _prefs?.getString('logo_path') ?? '';
  set logoPath(String v) => _prefs?.setString('logo_path', v);

  String get printWidth => _prefs?.getString('print_width') ?? '80mm';
  set printWidth(String v) => _prefs?.setString('print_width', v);

  bool get isDarkTheme => _prefs?.getBool('is_dark_theme') ?? true;
  set isDarkTheme(bool v) => _prefs?.setBool('is_dark_theme', v);

  int get tableCount => _prefs?.getInt('table_count') ?? 8;
  set tableCount(int v) => _prefs?.setInt('table_count', v);

  double get hourlyRate => _prefs?.getDouble('hourly_rate') ?? 0.0;
  set hourlyRate(double v) => _prefs?.setDouble('hourly_rate', v);

  int get primaryColorValue => _prefs?.getInt('primary_color') ?? 0xFFE53935;
  set primaryColorValue(int v) => _prefs?.setInt('primary_color', v);

  Future<void> setBusinessName(String v) async => _prefs?.setString('business_name', v);
  Future<void> setUserName(String v) async => _prefs?.setString('user_name', v);
  Future<void> setBillarId(String v) async => _prefs?.setString('billar_id', v);
  Future<void> setLogoPath(String v) async => _prefs?.setString('logo_path', v);
  Future<void> setPrintWidth(String v) async => _prefs?.setString('print_width', v);
  Future<void> setTableCount(int v) async => _prefs?.setInt('table_count', v);
  Future<void> setHourlyRate(double v) async => _prefs?.setDouble('hourly_rate', v);
  Future<void> setPrimaryColorValue(int v) async => _prefs?.setInt('primary_color', v);
  bool get isFirstRun => _prefs?.getBool('is_first_run') ?? true;
  set isFirstRun(bool v) => _prefs?.setBool('is_first_run', v);

  Future<void> setIsFirstRun(bool v) async => _prefs?.setBool('is_first_run', v);
}
