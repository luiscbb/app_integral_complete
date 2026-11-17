import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/storage/account_storage.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('offline opening requires both verified owner and existing database', () async {
    final directory = await Directory.systemTemp.createTemp('account_offline_');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    SharedPreferences.setMockInitialValues({});
    final prefs = PreferencesService();
    await prefs.init();
    const actor = '00000000-0000-0000-0000-000000000001';
    final httpClient = MockClient((request) async {
      if (request.url.path != '/auth/v1/token') {
        throw StateError('Unexpected network request: ${request.url.path}');
      }
      final tokenPayload = base64Url.encode(utf8.encode(jsonEncode({
        'sub': actor, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      }))).replaceAll('=', '');
      return http.Response(jsonEncode({
        'access_token': 'eyJhbGciOiJub25lIn0.$tokenPayload.signature',
        'token_type': 'bearer', 'expires_in': 3600, 'refresh_token': 'refresh',
        'user': {
          'id': actor, 'aud': 'authenticated', 'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{}, 'created_at': '2025-01-01T00:00:00Z',
        },
      }), 200, headers: {'content-type': 'application/json'}, request: request);
    });
    AccountStorage? storage;
    try {
      await Supabase.initialize(
        url: 'http://localhost:54321', publishableKey: 'test-key',
        httpClient: httpClient,
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false, detectSessionInUri: false,
        ),
      );
      final client = Supabase.instance.client;
      await client.auth.signInWithPassword(email: 'a@example.com', password: 'test');
      final helper = DatabaseHelper.instance;
      helper.requireAccountScope();
      storage = AccountStorage(client: client, database: helper, preferences: prefs);
      Future<void> open() => storage!.activate(
        billarId: 'A', migrateLegacyOwner: false, offline: true,
      );
      await expectLater(open(), throwsStateError);
      await prefs.recordVerifiedOwner(actor, 'A');
      await expectLater(open(), throwsStateError);
      final existing = await helper.openScopedDatabase(
        actorId: actor, billarId: 'A', isCurrentScope: () => true,
      );
      await existing.insert('categories', {'billar_id': 'A', 'name': 'GUARDADA'});
      await existing.close();
      await open();
      final active = await helper.database;
      expect((await active.query('categories')).single['name'], 'GUARDADA');
      await active.close();
    } finally {
      await storage?.dispose();
      await Supabase.instance.dispose();
      httpClient.close();
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    }
  });
}
