import 'dart:developer';
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../storage/preferences_service.dart';
import 'sync_session.dart';

typedef BusinessBranding = ({
  String businessName,
  String logoUrl,
  int? primaryColor,
});

class ConfigRemoteRepository {
  final _client = Supabase.instance.client;

  static const _table = 'billar_settings';

  Future<BusinessBranding> fetchStaffBranding() async {
    final guard = SyncSessionGuard(_client, PreferencesService());
    final session = guard.capture();
    final row = await _client
        .rpc('staff_business_profile', params: {
          'requested_billar_id': session.billarId,
        })
        .setHeader('Authorization', 'Bearer ${session.token}')
        .single();
    guard.require(session);
    final name = row['business_name'];
    final logo = row['logo_url'];
    final color = row['primary_color'];
    if (row['billar_id'] != session.billarId ||
        name is! String ||
        name.trim().isEmpty ||
        (logo != null && logo is! String) ||
        (color != null && color is! int)) {
      throw const FormatException('La identidad del negocio no es válida.');
    }
    return (
      businessName: name.trim(),
      logoUrl: normalizeLogoUrl(logo as String?),
      primaryColor: color is int ? 0xFF000000 | (color & 0x00FFFFFF) : null,
    );
  }

  static String normalizeLogoUrl(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.length >= 2 &&
        trimmed.startsWith('`') &&
        trimmed.endsWith('`')) {
      return trimmed.substring(1, trimmed.length - 1).trim();
    }
    return trimmed;
  }

  Future<Map<String, dynamic>?> fetchSettings() async {
    final session = _client.auth.currentSession;
    if (session == null) return null;
    void requireSameSession() {
      final current = _client.auth.currentSession;
      if (current?.user.id != session.user.id ||
          current?.accessToken != session.accessToken) {
        throw StateError('La sesión cambió durante la descarga de configuración.');
      }
    }

    try {
      final res =
          await _client
              .from(_table)
              .setHeader('Authorization', 'Bearer ${session.accessToken}')
              .select()
              .eq('user_id', session.user.id)
              .maybeSingle();

      requireSameSession();
      if (res == null) return null;

      // Restaurar el canal alpha del color: Supabase guarda solo RGB (sin alpha)
      // para no exceder el rango INTEGER de PostgreSQL.
      final raw = res['primary_color'];
      if (raw is num) {
        res['primary_color'] = 0xFF000000 | (raw.toInt() & 0x00FFFFFF);
      }
      res['logo_url'] = normalizeLogoUrl(res['logo_url']?.toString());
      return res;
    } catch (e, st) {
      requireSameSession();
      log('[ConfigRemoteRepository] fetchSettings error: $e', stackTrace: st);
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> upsertSettings({
    required String billarId,
    required String businessName,
    required int tableCount,
    required double hourlyRate,
    bool? allowNegativeStockSales,
    int? primaryColor,
    String? businessAddress,
    String? businessStreet,
    String? businessExtNumber,
    String? businessIntNumber,
    String? businessColony,
    String? businessZipCode,
    String? businessCity,
    String? businessState,
    String? businessPhone,
    String? businessWhatsapp,
    String? businessSlogan,
    String? businessWebsite,
    String? ticketFarewell,
    Map<String, String>? socialNetworks,
    String? logoUrl,
  }) async {
    try {
      final session = _client.auth.currentSession;
      if (session == null) return null;
      final user = session.user;
      void requireSameSession() {
        if (!identical(_client.auth.currentSession, session)) {
          throw StateError('La sesión cambió durante el guardado de configuración.');
        }
      }

      final existing = await fetchSettings();
      requireSameSession();

      String value(String? v) => (v != null && v.isNotEmpty) ? v : '';

      final payload = {
        'user_id': user.id,
        'billar_id': billarId,
        'business_name': businessName,
        'table_count': tableCount,
        'hourly_rate': hourlyRate,
        if (allowNegativeStockSales != null)
          'allow_negative_stock_sales': allowNegativeStockSales,
        // Guardar solo los 3 bytes RGB (sin alpha) para no exceder el rango
        // INTEGER de PostgreSQL (max 2147483647). 0xFFE53935 = 4294967295.
        if (primaryColor != null) 'primary_color': primaryColor & 0x00FFFFFF,
        'business_address': value(businessAddress),
        'business_street': value(businessStreet),
        'business_ext_number': value(businessExtNumber),
        'business_int_number': value(businessIntNumber),
        'business_colony': value(businessColony),
        'business_zip_code': value(businessZipCode),
        'business_city': value(businessCity),
        'business_state': value(businessState),
        'business_phone': value(businessPhone),
        'business_whatsapp': value(businessWhatsapp),
        'business_slogan': value(businessSlogan),
        'business_website': value(businessWebsite),
        'ticket_farewell': value(ticketFarewell),
        'social_networks': jsonEncode(
          socialNetworks ?? const <String, String>{},
        ),
        if (logoUrl != null) 'logo_url': normalizeLogoUrl(logoUrl),
      };

      if (existing != null) {
        // Actualizar
        final res =
            await _client
                .from(_table)
                .setHeader('Authorization', 'Bearer ${session.accessToken}')
                .update(payload)
                .eq('user_id', user.id)
                .select()
                .single();
        requireSameSession();
        return res;
      } else {
        // Insertar
        final res =
            await _client.from(_table)
                .setHeader('Authorization', 'Bearer ${session.accessToken}')
                .insert(payload).select().single();
        requireSameSession();
        return res;
      }
    } catch (e, st) {
      log('[ConfigRemoteRepository] upsertSettings error: $e', stackTrace: st);
      return null;
    }
  }

  Future<void> updateAllowNegativeStockSales(bool enabled) async {
    final user = _client.auth.currentUser;
    if (user == null) return;
    await _client
        .from(_table)
        .update({'allow_negative_stock_sales': enabled})
        .eq('user_id', user.id);
  }
}
