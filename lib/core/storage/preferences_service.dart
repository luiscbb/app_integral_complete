import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class PreferencesService {
  static final PreferencesService _instance = PreferencesService._internal();
  factory PreferencesService() => _instance;
  PreferencesService._internal();
  PreferencesService._scoped(this._prefs);

  _PreferencesView? _prefs;
  int _scopeGeneration = 0;
  int get scopeGeneration => _scopeGeneration;
  static const _legacySnapshotKey = 'legacy_settings_snapshot_v1';
  static const _settingsKeys = {
    'business_name',
    'user_name',
    'billar_id',
    'logo_path',
    'logo_url',
    'print_width',
    'is_dark_theme',
    'table_count',
    'allow_negative_stock_sales',
    'hourly_rate',
    'primary_color',
    'business_address',
    'business_street',
    'business_ext_number',
    'business_int_number',
    'business_colony',
    'business_zip_code',
    'business_city',
    'business_state',
    'business_phone',
    'business_whatsapp',
    'business_slogan',
    'business_website',
    'ticket_farewell',
    'ticket_counter',
    'business_socials',
    'default_table_type',
    'is_first_run',
    'is_solid_theme',
    'card_style_index',
  };

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    await _ensureLegacySnapshot(prefs);
    _scopeGeneration++;
    _prefs = _PreferencesView(prefs);
  }

  PreferencesService forScope({
    required String actorId,
    required String billarId,
    required bool Function() isCurrentScope,
  }) {
    if (actorId.trim().isEmpty || billarId.trim().isEmpty) {
      throw ArgumentError('La cuenta y el billar son obligatorios.');
    }
    final prefs = _prefs;
    if (prefs == null) {
      throw StateError('Las preferencias no están inicializadas.');
    }
    if (prefs.prefix.isNotEmpty) {
      throw StateError('El ámbito de preferencias ya está seleccionado.');
    }
    String encode(String value) =>
        base64Url.encode(utf8.encode(value)).replaceAll('=', '');
    return PreferencesService._scoped(
      _PreferencesView(
        prefs.raw,
        prefix: 'account_scope_v1.${encode(actorId)}.${encode(billarId)}.',
        actorId: actorId,
        billarId: billarId,
        isCurrentScope: isCurrentScope,
      ),
    );
  }

  void activateScope(PreferencesService scoped) {
    final current = _prefs;
    final next = scoped._prefs;
    if (current == null || current.prefix.isNotEmpty ||
        next == null || next.prefix.isEmpty ||
        !identical(current.raw, next.raw)) {
      throw StateError('No se puede activar el ámbito de preferencias.');
    }
    next._key('billar_id');
    _prefs = next;
    _scopeGeneration++;
  }

  String _verifiedOwnerKey(String actorId) {
    if (actorId.trim().isEmpty) throw ArgumentError('La cuenta es obligatoria.');
    return 'verified_owner_scope_v1.${base64Url.encode(utf8.encode(actorId)).replaceAll('=', '')}';
  }

  String? verifiedOwnerBillar(String actorId) {
    final prefs = _prefs;
    if (prefs == null || prefs.prefix.isNotEmpty) {
      throw StateError('La verificación local solo se consulta antes de seleccionar cuenta.');
    }
    return prefs.raw.getString(_verifiedOwnerKey(actorId));
  }

  Future<void> recordVerifiedOwner(String actorId, String billarId) async {
    final prefs = _prefs;
    if (prefs == null || prefs.prefix.isNotEmpty || billarId.trim().isEmpty) {
      throw StateError('No se pudo registrar la verificación local.');
    }
    if (!await prefs.raw.setString(_verifiedOwnerKey(actorId), billarId)) {
      throw StateError('No se pudo guardar la verificación local.');
    }
  }

  Future<void> ensureLegacyPreferencesSnapshot() async {
    final prefs = _prefs;
    if (prefs == null) {
      throw StateError('Las preferencias no están inicializadas.');
    }
    if (prefs.prefix.isNotEmpty) {
      throw StateError(
        'La copia anterior solo se consulta antes de seleccionar cuenta.',
      );
    }
    await _ensureLegacySnapshot(prefs.raw);
  }

  Future<void> _ensureLegacySnapshot(SharedPreferences prefs) async {
    if (!prefs.containsKey(_legacySnapshotKey)) {
      final snapshot = <String, Object>{};
      for (final key in _settingsKeys) {
        final value = prefs.get(key);
        if (value != null) snapshot[key] = value;
      }
      if (snapshot.isNotEmpty &&
          !await prefs.setString(_legacySnapshotKey, jsonEncode(snapshot))) {
        throw StateError(
          'No se pudo conservar la configuración local anterior.',
        );
      }
    }
  }

  Map<String, Object?>? get legacyPreferencesSnapshot {
    if (_prefs?.prefix.isNotEmpty ?? false) {
      throw StateError(
        'La copia anterior solo se consulta antes de seleccionar cuenta.',
      );
    }
    final raw = _prefs?.raw.getString(_legacySnapshotKey);
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('La configuración local anterior no es válida.');
    }

    return Map.unmodifiable(decoded);
  }

  Future<void> importVerifiedLegacySettings({
    required PreferencesService source,
    required String expectedActorId,
    required String expectedBillarId,
    required void Function() requireOwner,
  }) async {
    final target = _prefs;
    final legacy = source._prefs;
    if (target == null ||
        target.prefix.isEmpty ||
        target.actorId != expectedActorId ||
        target.billarId != expectedBillarId ||
        legacy == null ||
        legacy.prefix.isNotEmpty ||
        !identical(target.raw, legacy.raw)) {
      throw StateError('El ámbito de preferencias para migrar no es válido.');
    }
    requireOwner();
    target.getString('billar_id');
    final savedBillar = source.legacyPreferencesSnapshot?['billar_id'];
    if (savedBillar != expectedBillarId ||
        legacy.getString('billar_id') != expectedBillarId) {
      throw StateError('La configuración anterior pertenece a otro billar.');
    }
    final completedKey = target._key('legacy_import_completed_v1');
    if (target.raw.getBool(completedKey) == true) return;
    const boolKeys = {
      'is_dark_theme',
      'allow_negative_stock_sales',
      'is_first_run',
      'is_solid_theme',
    };
    const intKeys = {
      'table_count',
      'primary_color',
      'ticket_counter',
      'card_style_index',
    };
    final values = <String, Object>{};
    for (final key in {..._settingsKeys, 'admin_pin'}) {
      requireOwner();
      target._key(key);
      final value = legacy.raw.get(key);
      if (value == null) continue;
      final valid =
          boolKeys.contains(key)
              ? value is bool
              : intKeys.contains(key)
              ? value is int
              : key == 'hourly_rate'
              ? value is double
              : value is String;
      if (!valid) {
        throw StateError(
          'La preferencia anterior $key no tiene un tipo válido.',
        );
      }
      values[key] = value;
    }
    for (final entry in values.entries) {
      requireOwner();
      final key = entry.key;
      final scopedKey = target._key(key);
      if (target.raw.containsKey(scopedKey)) continue;
      final value = entry.value;
      if (value is String) {
        await target.setString(key, value);
      } else if (value is bool) {
        await target.setBool(key, value);
      } else if (value is int) {
        await target.setInt(key, value);
      } else if (value is double) {
        await target.setDouble(key, value);
      } else {
        throw StateError(
          'La preferencia anterior $key no tiene un tipo válido.',
        );
      }
      requireOwner();
    }
    requireOwner();
    await target.setBool('legacy_import_completed_v1', true);
    requireOwner();
  }

  String get businessName => _prefs?.getString('business_name') ?? 'MI BILLAR';
  set businessName(String v) => _prefs?.setString('business_name', v);

  String get userName => _prefs?.getString('user_name') ?? 'Administrador';
  set userName(String v) => _prefs?.setString('user_name', v);

  String get billarId => _prefs?.getString('billar_id') ?? 'BILLAR_001';
  set billarId(String v) => setBillarId(v);

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

  bool get allowNegativeStockSales =>
      _prefs?.getBool('allow_negative_stock_sales') ?? false;
  set allowNegativeStockSales(bool v) =>
      _prefs?.setBool('allow_negative_stock_sales', v);

  double get hourlyRate => _prefs?.getDouble('hourly_rate') ?? 0.0;
  set hourlyRate(double v) => _prefs?.setDouble('hourly_rate', v);

  int get primaryColorValue => _prefs?.getInt('primary_color') ?? 0xFFE53935;
  set primaryColorValue(int v) => _prefs?.setInt('primary_color', v);

  // Datos extendidos del negocio para tickets y perfil
  String get businessAddress => _prefs?.getString('business_address') ?? '';
  set businessAddress(String v) => _prefs?.setString('business_address', v);

  String get businessStreet => _prefs?.getString('business_street') ?? '';
  set businessStreet(String v) => _prefs?.setString('business_street', v);

  String get businessExtNumber =>
      _prefs?.getString('business_ext_number') ?? '';
  set businessExtNumber(String v) =>
      _prefs?.setString('business_ext_number', v);

  String get businessIntNumber =>
      _prefs?.getString('business_int_number') ?? '';
  set businessIntNumber(String v) =>
      _prefs?.setString('business_int_number', v);

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

  String get ticketFarewell =>
      _prefs?.getString('ticket_farewell') ?? 'GRACIAS POR SU COMPRA';
  set ticketFarewell(String v) => _prefs?.setString('ticket_farewell', v);

  int get ticketCounter => _prefs?.getInt('ticket_counter') ?? 0;
  set ticketCounter(int v) => _prefs?.setInt('ticket_counter', v);

  /// PIN de autorización para operaciones críticas (anular venta).
  /// Vacío = sin PIN configurado (la anulación queda deshabilitada).
  String get adminPin => _prefs?.getString('admin_pin') ?? '';
  set adminPin(String v) => _prefs?.setString('admin_pin', v);

  Map<String, String> get socialNetworks {
    final raw = _prefs?.getString('business_socials') ?? '{}';
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  set socialNetworks(Map<String, String> v) =>
      _prefs?.setString('business_socials', jsonEncode(v));

  Future<void> setBusinessName(String v) async =>
      _prefs?.setString('business_name', v);
  Future<void> setUserName(String v) async => _prefs?.setString('user_name', v);
  Future<void> setAdminPin(String v) async => _prefs?.setString('admin_pin', v);
  Future<void> setBillarId(String v) async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (billarId != v) _scopeGeneration++;
    await prefs.setString('billar_id', v);
  }
  Future<void> setLogoPath(String v) async => _prefs?.setString('logo_path', v);
  Future<void> setLogoUrl(String v) async => _prefs?.setString('logo_url', v);
  Future<void> setPrintWidth(String v) async =>
      _prefs?.setString('print_width', v);
  Future<void> setTableCount(int v) async => _prefs?.setInt('table_count', v);
  Future<void> setAllowNegativeStockSales(bool v) async =>
      _prefs?.setBool('allow_negative_stock_sales', v);
  Future<void> setHourlyRate(double v) async =>
      _prefs?.setDouble('hourly_rate', v);
  Future<void> setPrimaryColorValue(int v) async =>
      _prefs?.setInt('primary_color', v);
  Future<void> setBusinessAddress(String v) async =>
      _prefs?.setString('business_address', v);
  Future<void> setBusinessStreet(String v) async =>
      _prefs?.setString('business_street', v);
  Future<void> setBusinessExtNumber(String v) async =>
      _prefs?.setString('business_ext_number', v);
  Future<void> setBusinessIntNumber(String v) async =>
      _prefs?.setString('business_int_number', v);
  Future<void> setBusinessColony(String v) async =>
      _prefs?.setString('business_colony', v);
  Future<void> setBusinessZipCode(String v) async =>
      _prefs?.setString('business_zip_code', v);
  Future<void> setBusinessCity(String v) async =>
      _prefs?.setString('business_city', v);
  Future<void> setBusinessState(String v) async =>
      _prefs?.setString('business_state', v);
  Future<void> setBusinessPhone(String v) async =>
      _prefs?.setString('business_phone', v);
  Future<void> setBusinessWhatsapp(String v) async =>
      _prefs?.setString('business_whatsapp', v);
  Future<void> setBusinessSlogan(String v) async =>
      _prefs?.setString('business_slogan', v);
  Future<void> setBusinessWebsite(String v) async =>
      _prefs?.setString('business_website', v);
  Future<void> setTicketFarewell(String v) async =>
      _prefs?.setString('ticket_farewell', v);
  Future<void> setTicketCounter(int v) async =>
      _prefs?.setInt('ticket_counter', v);
  Future<void> setSocialNetworks(Map<String, String> v) async =>
      _prefs?.setString('business_socials', jsonEncode(v));

  String get defaultTableType =>
      _prefs?.getString('default_table_type') ?? 'Pool';
  set defaultTableType(String v) => _prefs?.setString('default_table_type', v);
  Future<void> setDefaultTableType(String v) async =>
      _prefs?.setString('default_table_type', v);

  bool get isFirstRun => _prefs?.getBool('is_first_run') ?? true;
  set isFirstRun(bool v) => _prefs?.setBool('is_first_run', v);

  Future<void> setIsFirstRun(bool v) async =>
      _prefs?.setBool('is_first_run', v);

  bool get isSolidTheme => _prefs?.getBool('is_solid_theme') ?? false;
  set isSolidTheme(bool v) => _prefs?.setBool('is_solid_theme', v);

  Future<void> setIsSolidTheme(bool v) async =>
      _prefs?.setBool('is_solid_theme', v);

  // Estilo de tarjetas: 0 = degradado, 1 = contorno de color, 2 = sólido blanco.
  // -1 = no configurado aún (se migra desde isSolidTheme la primera vez).
  int get cardStyleIndex => _prefs?.getInt('card_style_index') ?? -1;
  set cardStyleIndex(int v) => _prefs?.setInt('card_style_index', v);

  /// Limpia solo los datos de sesión del usuario. No toca la base de datos
  /// ni la configuración del negocio (mesas, tarifas, colores, etc.).
  Future<void> clearSession() async {
    if (_prefs?.prefix.isEmpty ?? true) {
      await ensureLegacyPreferencesSnapshot();
    }
    await _prefs?.remove('user_name');
  }
}

class _PreferencesView {
  _PreferencesView(
    this.raw, {
    this.prefix = '',
    this.actorId,
    this.billarId,
    this.isCurrentScope,
  });

  final SharedPreferences raw;
  final String prefix;
  final String? actorId;
  final String? billarId;
  final bool Function()? isCurrentScope;

  String _key(String key) {
    if (isCurrentScope != null && !isCurrentScope!()) {
      throw StateError('La cuenta o el billar de las preferencias cambió.');
    }
    return '$prefix$key';
  }

  String? getString(String key) {
    final value = raw.getString(_key(key));
    if (key == 'billar_id' && billarId != null) {
      if (value != null && value != billarId) {
        throw StateError('El billar guardado no coincide con el ámbito local.');
      }
      return billarId;
    }
    return value;
  }

  bool? getBool(String key) => raw.getBool(_key(key));
  int? getInt(String key) => raw.getInt(_key(key));
  double? getDouble(String key) => raw.getDouble(_key(key));

  Future<void> setString(String key, String value) {
    final scopedKey = _key(key);
    if (key == 'billar_id' && billarId != null && value != billarId) {
      throw StateError('No se puede cambiar el billar del ámbito local.');
    }
    return _write(key, raw.setString(scopedKey, value));
  }

  Future<void> _write(String key, Future<bool> result) async {
    if (!await result) {
      throw StateError('No se pudo guardar la preferencia local: $key.');
    }
    _key(key);
  }

  Future<void> setBool(String key, bool value) =>
      _write(key, raw.setBool(_key(key), value));
  Future<void> setInt(String key, int value) =>
      _write(key, raw.setInt(_key(key), value));
  Future<void> setDouble(String key, double value) =>
      _write(key, raw.setDouble(_key(key), value));
  Future<void> remove(String key) => _write(key, raw.remove(_key(key)));
}
