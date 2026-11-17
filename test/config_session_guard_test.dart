import 'dart:async';
import 'dart:convert';

import 'package:app_integral_complete/core/services/config_remote_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('settings fetched for one session are not returned to another', () async {
    SharedPreferences.setMockInitialValues({});
    final started = Completer<void>();
    final resume = Completer<void>();
    String? authorization;
    var networkFailure = false;
    final httpClient = MockClient((request) async {
      if (request.url.path == '/auth/v1/token') {
        final email = (jsonDecode(request.body) as Map)['email'];
        final id = email == 'b@example.com'
            ? '00000000-0000-0000-0000-000000000002'
            : '00000000-0000-0000-0000-000000000001';
        final payload = base64Url.encode(utf8.encode(jsonEncode({
          'sub': id,
          'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
        }))).replaceAll('=', '');
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
      }
      if (request.url.path == '/rest/v1/billar_settings') {
        if (networkFailure) throw http.ClientException('Sin conexión');
        authorization = request.headers['authorization'];
        started.complete();
        await resume.future;
        return http.Response(
          jsonEncode({'billar_id': 'A', 'business_name': 'BILLAR A'}),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      throw StateError('Unexpected request: ${request.url.path}');
    });
    try {
      await Supabase.initialize(
        url: 'http://localhost:54321',
        publishableKey: 'test-key',
        httpClient: httpClient,
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
        ),
      );
      final client = Supabase.instance.client;
      await client.auth.signInWithPassword(email: 'a@example.com', password: 'test');
      final token = client.auth.currentSession!.accessToken;
      final pending = ConfigRemoteRepository().fetchSettings();
      final assertion = expectLater(pending, throwsStateError);
      await started.future.timeout(const Duration(seconds: 5));
      await client.auth.signInWithPassword(email: 'b@example.com', password: 'test');
      resume.complete();
      await assertion;
      expect(authorization, 'Bearer $token');

      networkFailure = true;
      await expectLater(
        ConfigRemoteRepository().fetchSettings(),
        throwsA(isA<http.ClientException>()),
      );
    } finally {
      await Supabase.instance.dispose();
      httpClient.close();
    }
  });
}
