import 'dart:convert';

import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/features/players/data/repositories/player_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy manager list excludes staff usernames', () async {
    SharedPreferences.setMockInitialValues({'billar_id': 'A'});
    await PreferencesService().init();
    Uri? requested;
    final client = MockClient((request) async {
      requested = request.url;
      final managers = [
        {'user_id': 'legacy', 'email': 'legacy@example.com'},
        if (request.url.queryParameters['username'] != 'is.null')
          {'user_id': 'staff', 'email': 'staff@invalid.example'},
      ];
      return http.Response(
        jsonEncode(managers),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    try {
      await Supabase.initialize(
        url: 'http://localhost:54321',
        publishableKey: 'test-key',
        httpClient: client,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      );
      final managers = await PlayerRepository().getManagers();
      expect(requested?.queryParameters['username'], 'is.null');
      expect(requested?.queryParameters['billar_id'], 'eq.A');
      expect(managers.map((row) => row['user_id']), ['legacy']);
    } finally {
      await Supabase.instance.dispose();
      client.close();
    }
  });
}
