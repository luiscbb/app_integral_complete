import 'dart:async';
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
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('activates verified legacy data and rejects a different session', () async {
    final directory = await Directory.systemTemp.createTemp('account_storage_');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    SharedPreferences.setMockInitialValues({
      'billar_id': 'A',
      'business_name': 'Original',
      'admin_pin': '1234',
    });
    final prefs = PreferencesService();
    await prefs.init();
    const owner = '00000000-0000-0000-0000-000000000001';
    const other = '00000000-0000-0000-0000-000000000002';
    final httpClient = MockClient((request) async {
      Object? data;
      if (request.url.path == '/auth/v1/token') {
        final email = (jsonDecode(request.body) as Map)['email'];
        final id = email == 'a@example.com' ? owner : other;
        final tokenPayload = base64Url.encode(utf8.encode(jsonEncode({
          'sub': id,
          'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
        }))).replaceAll('=', '');
        data = {
          'access_token': 'eyJhbGciOiJub25lIn0.$tokenPayload.signature',
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-$id',
          'user': {
            'id': id, 'aud': 'authenticated', 'app_metadata': <String, dynamic>{},
            'user_metadata': <String, dynamic>{}, 'created_at': '2025-01-01T00:00:00Z',
          },
        };
      } else if (request.url.path == '/rest/v1/billar_settings') {
        data = {'user_id': owner, 'billar_id': 'A'};
      } else if (request.url.path == '/rest/v1/business_memberships') {
        data = {'role': 'admin', 'is_active': true, 'must_change_password': false};
      } else {
        throw StateError('Unexpected request: ${request.url.path}');
      }
      return http.Response(
        jsonEncode(data), 200,
        headers: {'content-type': 'application/json'}, request: request,
      );
    });
    AccountStorage? storage;
    Database? scoped;
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
      final legacy = await helper.database;
      await legacy.insert('sales_history', {
        'billar_id': 'A', 'total': 10, 'paid': 10, 'date': '2026-01-01',
        'type': 'Venta Rápida', 'payment_method': 'Efectivo', 'synced': 0,
      });
      await legacy.close();
      helper.requireAccountScope();
      await expectLater(helper.database, throwsStateError);
      storage = AccountStorage(client: client, database: helper, preferences: prefs);
      await storage.activate(billarId: 'A', migrateLegacyOwner: true);
      scoped = await helper.database;
      expect((await scoped.query('sales_history')).single['total'], 10);
      expect(prefs.businessName, 'Original');
      expect(prefs.adminPin, '1234');
      final scopedPath = scoped.path;
      final started = Completer<void>();
      final resume = Completer<void>();
      final transaction = scoped.transaction((txn) async {
        await txn.insert('categories', {'billar_id': 'A', 'name': 'TEMPORAL'});
        started.complete();
        await resume.future;
      });
      final rejected = expectLater(transaction, throwsStateError);
      await started.future;
      await client.auth.signInWithPassword(email: 'b@example.com', password: 'test');
      await expectLater(helper.database, throwsStateError);
      expect(() => prefs.businessName, throwsStateError);
      await expectLater(storage.activate(billarId: 'B', migrateLegacyOwner: false), throwsStateError);
      await client.auth.signInWithPassword(email: 'a@example.com', password: 'test');
      resume.complete();
      await rejected;
      await expectLater(helper.database, throwsStateError);
      expect(() => prefs.businessName, throwsStateError);
      final inspection = await ffi.databaseFactoryFfi.openDatabase(
        scopedPath, options: ffi.OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      try {
        expect(await inspection.query('categories'), isEmpty);
      } finally {
        await inspection.close();
      }
    } finally {
      await scoped?.close();
      await storage?.dispose();
      await Supabase.instance.dispose();
      httpClient.close();
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    }
  });
}
