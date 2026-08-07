import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

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

  String get logoUrl => _prefs?.getString('logo_url') ?? '';
  set logoUrl(String v) => _prefs?.setString('logo_url', v);

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

  // Datos extendidos del negocio para tickets y perfil
  String get businessAddress => _prefs?.getString('business_address') ?? '';
  set businessAddress(String v) => _prefs?.setString('business_address', v);

  String get businessStreet => _prefs?.getString('business_street') ?? '';
  set businessStreet(String v) => _prefs?.setString('business_street', v);

  String get businessExtNumber => _prefs?.getString('business_ext_number') ?? '';
  set businessExtNumber(String v) => _prefs?.setString('business_ext_number', v);

  String get businessIntNumber => _prefs?.getString('business_int_number') ?? '';
  set businessIntNumber(String v) => _prefs?.setString('business_int_number', v);

  String get businessColony => _prefs?.getString('business_colony') ?? '';
  set businessColony(String v) => _prefs?.setString('business_colony', v);

  String get businessZipCode => _prefs?.getString('business_zip_code') ?? '';
  set businessZipCode(String v) => _prefs?.setString('business_zip_code', v);

  String get businessCity => _prefs?.getString('business_city') ?? '';
  set businessCity(String v) => _prefs?.setString('business_city', v);

  String get businessState => _prefs?.getString('business_state') ?? '';
  set businessState(String v) => _prefs?.setString('business_state', v);

  String get businessPhone => _prefs?.getString('business_phone') ?? '';
  set businessPhone(String v) => _prefs?.setString('business_phone', v);

  String get businessWhatsapp => _prefs?.getString('business_whatsapp') ?? '';
  set businessWhatsapp(String v) => _prefs?.setString('business_whatsapp', v);

  String get businessSlogan => _prefs?.getString('business_slogan') ?? '';
  set businessSlogan(String v) => _prefs?.setString('business_slogan', v);

  String get businessWebsite => _prefs?.getString('business_website') ?? '';
  set businessWebsite(String v) => _prefs?.setString('business_website', v);

  String get ticketFarewell => _prefs?.getString('ticket_farewell') ?? 'GRACIAS POR SU COMPRA';
  set ticketFarewell(String v) => _prefs?.setString('ticket_farewell', v);

  int get ticketCounter => _prefs?.getInt('ticket_counter') ?? 0;
  set ticketCounter(int v) => _prefs?.setInt('ticket_counter', v);

  Map<String, String> get socialNetworks {
    final raw = _prefs?.getString('business_socials') ?? '{}';
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  set socialNetworks(Map<String, String> v) => _prefs?.setString('business_socials', jsonEncode(v));

  Future<void> setBusinessName(String v) async => _prefs?.setString('business_name', v);
  Future<void> setUserName(String v) async => _prefs?.setString('user_name', v);
  Future<void> setBillarId(String v) async => _prefs?.setString('billar_id', v);
  Future<void> setLogoPath(String v) async => _prefs?.setString('logo_path', v);
  Future<void> setLogoUrl(String v) async => _prefs?.setString('logo_url', v);
  Future<void> setPrintWidth(String v) async => _prefs?.setString('print_width', v);
  Future<void> setTableCount(int v) async => _prefs?.setInt('table_count', v);
  Future<void> setHourlyRate(double v) async => _prefs?.setDouble('hourly_rate', v);
  Future<void> setPrimaryColorValue(int v) async => _prefs?.setInt('primary_color', v);
  Future<void> setBusinessAddress(String v) async => _prefs?.setString('business_address', v);
  Future<void> setBusinessStreet(String v) async => _prefs?.setString('business_street', v);
  Future<void> setBusinessExtNumber(String v) async => _prefs?.setString('business_ext_number', v);
  Future<void> setBusinessIntNumber(String v) async => _prefs?.setString('business_int_number', v);
  Future<void> setBusinessColony(String v) async => _prefs?.setString('business_colony', v);
  Future<void> setBusinessZipCode(String v) async => _prefs?.setString('business_zip_code', v);
  Future<void> setBusinessCity(String v) async => _prefs?.setString('business_city', v);
  Future<void> setBusinessState(String v) async => _prefs?.setString('business_state', v);
  Future<void> setBusinessPhone(String v) async => _prefs?.setString('business_phone', v);
  Future<void> setBusinessWhatsapp(String v) async => _prefs?.setString('business_whatsapp', v);
  Future<void> setBusinessSlogan(String v) async => _prefs?.setString('business_slogan', v);
  Future<void> setBusinessWebsite(String v) async => _prefs?.setString('business_website', v);
  Future<void> setTicketFarewell(String v) async => _prefs?.setString('ticket_farewell', v);
  Future<void> setTicketCounter(int v) async => _prefs?.setInt('ticket_counter', v);
  Future<void> setSocialNetworks(Map<String, String> v) async => _prefs?.setString('business_socials', jsonEncode(v));

  String get defaultTableType => _prefs?.getString('default_table_type') ?? 'Pool';
  set defaultTableType(String v) => _prefs?.setString('default_table_type', v);
  Future<void> setDefaultTableType(String v) async => _prefs?.setString('default_table_type', v);

  bool get isFirstRun => _prefs?.getBool('is_first_run') ?? true;
  set isFirstRun(bool v) => _prefs?.setBool('is_first_run', v);

  Future<void> setIsFirstRun(bool v) async => _prefs?.setBool('is_first_run', v);

  bool get isSolidTheme => _prefs?.getBool('is_solid_theme') ?? false;
  set isSolidTheme(bool v) => _prefs?.setBool('is_solid_theme', v);

  Future<void> setIsSolidTheme(bool v) async => _prefs?.setBool('is_solid_theme', v);

  // Estilo de tarjetas: 0 = degradado, 1 = contorno de color, 2 = sólido blanco.
  // -1 = no configurado aún (se migra desde isSolidTheme la primera vez).
  int get cardStyleIndex => _prefs?.getInt('card_style_index') ?? -1;
  set cardStyleIndex(int v) => _prefs?.setInt('card_style_index', v);

  /// Limpia solo los datos de sesión del usuario. No toca la base de datos
  /// ni la configuración del negocio (mesas, tarifas, colores, etc.).
  Future<void> clearSession() async {
    await _prefs?.remove('user_name');
  }
}
