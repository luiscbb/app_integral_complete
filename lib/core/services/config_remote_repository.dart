import 'dart:developer';
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';

class ConfigRemoteRepository {
  final _client = Supabase.instance.client;

  static const _table = 'billar_settings';

  Future<Map<String, dynamic>?> fetchSettings() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return null;

      final res = await _client
          .from(_table)
          .select()
          .eq('user_id', user.id)
          .maybeSingle();

      if (res == null) return null;

      // Restaurar el canal alpha del color: Supabase guarda solo RGB (sin alpha)
      // para no exceder el rango INTEGER de PostgreSQL.
      final raw = res['primary_color'];
      if (raw is num) {
        res['primary_color'] = 0xFF000000 | (raw.toInt() & 0x00FFFFFF);
      }
      return res;
    } catch (e, st) {
      log('[ConfigRemoteRepository] fetchSettings error: $e', stackTrace: st);
      return null;
    }
  }

  Future<Map<String, dynamic>?> upsertSettings({
    required String billarId,
    required String businessName,
    required int tableCount,
    required double hourlyRate,
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
      final user = _client.auth.currentUser;
      if (user == null) return null;

      final existing = await fetchSettings();

      String value(String? v) => (v != null && v.isNotEmpty) ? v : '';

      final payload = {
        'user_id': user.id,
        'billar_id': billarId,
        'business_name': businessName,
        'table_count': tableCount,
        'hourly_rate': hourlyRate,
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
        if (socialNetworks != null && socialNetworks.isNotEmpty) 'social_networks': jsonEncode(socialNetworks),
        if (logoUrl != null && logoUrl.isNotEmpty) 'logo_url': logoUrl,
      };

      if (existing != null) {
        // Actualizar
        final res = await _client
            .from(_table)
            .update(payload)
            .eq('user_id', user.id)
            .select()
            .single();
        return res;
      } else {
        // Insertar
        final res = await _client
            .from(_table)
            .insert(payload)
            .select()
            .single();
        return res;
      }
    } catch (e, st) {
      log('[ConfigRemoteRepository] upsertSettings error: $e', stackTrace: st);
      return null;
    }
  }
}
