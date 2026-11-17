import 'dart:convert';

import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('operations reject account and business A-B-A transitions', () async {
    SharedPreferences.setMockInitialValues({'billar_id': 'A'});
    final preferences = PreferencesService();
    await preferences.init();
    final httpClient = MockClient((request) async {
      final email = (jsonDecode(request.body) as Map)['email'];
      final id =
          email == 'b@example.com'
              ? '00000000-0000-0000-0000-000000000002'
              : '00000000-0000-0000-0000-000000000001';
      final payload = base64Url
          .encode(utf8.encode(jsonEncode({'sub': id, 'exp': 2000000000})))
          .replaceAll('=', '');
      return http.Response(
        jsonEncode({
          'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-$id',
          'user': {
            'id': id,
            'aud': 'authenticated',
            'app_metadata': <String, dynamic>{},
            'user_metadata': <String, dynamic>{},
            'created_at': '2025-01-01T00:00:00Z',
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    final client = SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: httpClient,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    try {
      Future<void> signIn(String email) async {
        await client.auth.signInWithPassword(email: email, password: 'test');
      }

      await signIn('a@example.com');
      final guard = SyncSessionGuard(client, preferences);
      final original = guard.capture();
      await preferences.setBillarId('A');
      guard.require(original);
      await preferences.setBillarId('B');
      await preferences.setBillarId('A');
      expect(() => guard.require(original), throwsStateError);

      final next = guard.capture();
      await signIn('b@example.com');
      await signIn('a@example.com');
      expect(client.auth.currentSession!.accessToken, next.token);
      expect(() => guard.require(next), throwsStateError);
      guard.require(guard.capture());
    } finally {
      await client.dispose();
      httpClient.close();
    }
  });
}
