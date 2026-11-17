import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/routes/app_routes.dart';
import 'package:app_integral_complete/core/services/sync_service.dart';
import 'package:app_integral_complete/core/storage/account_storage.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/core/theme/theme_provider.dart';
import 'package:app_integral_complete/features/auth/presentation/pages/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('owner login restores the remote business logo', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('owner_login_logo_'),
    ))!;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const path = MethodChannel('plugins.flutter.io/path_provider');
    const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
    const events = MethodChannel('dev.fluttercommunity.plus/connectivity_status');
    messenger.setMockMethodCallHandler(path, (_) async => directory.path);
    messenger.setMockMethodCallHandler(connectivity, (_) async => ['none']);
    messenger.setMockMethodCallHandler(events, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(PreferencesService().init);

    const actor = '00000000-0000-0000-0000-000000000001';
    const logo = 'https://example.test/storage/v1/object/public/product_images/A/logos/logo.jpg';
    final client = MockClient((request) async {
      Object? data;
      if (request.url.path == '/auth/v1/token') {
        final payload = base64Url.encode(utf8.encode(jsonEncode({
          'sub': actor, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
        }))).replaceAll('=', '');
        data = {
          'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
          'token_type': 'bearer', 'expires_in': 3600, 'refresh_token': 'test',
          'user': {
            'id': actor, 'aud': 'authenticated', 'app_metadata': <String, dynamic>{},
            'user_metadata': <String, dynamic>{}, 'created_at': '2025-01-01T00:00:00Z',
          },
        };
      } else if (request.url.path == '/rest/v1/players') {
        data = null;
      } else if (request.url.path == '/rest/v1/business_memberships') {
        data = [{
          'billar_id': 'A', 'role': 'admin', 'is_active': true, 'must_change_password': false,
        }];
      } else if (request.url.path == '/rest/v1/billar_settings') {
        data = {
          'user_id': actor, 'billar_id': 'A', 'business_name': 'Negocio A',
          'table_count': 1, 'hourly_rate': 0, 'logo_url': '`$logo`',
        };
      } else if (request.url.path == '/rest/v1/billiard_tables') {
        data = [];
      } else {
        throw StateError('Unexpected request: ${request.method} ${request.url.path}');
      }
      return http.Response(
        jsonEncode(data), 200,
        headers: {'content-type': 'application/json'}, request: request,
      );
    });

    try {
      await tester.runAsync(() => Supabase.initialize(
        url: 'http://localhost:54321', publishableKey: 'test',
        httpClient: client,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false, detectSessionInUri: false),
      ));
      AccountStorage.initialize(Supabase.instance.client);
      await tester.pumpWidget(ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: const LoginPage(),
          routes: {AppRoutes.home: (_) => const Scaffold(body: Text('HOME'))},
        ),
      ));
      await tester.enterText(find.byType(TextField).at(0), 'owner@example.test');
      await tester.enterText(find.byType(TextField).at(1), 'password');
      await tester.ensureVisible(find.text('ENTRAR'));
      await tester.tap(find.text('ENTRAR'));
      for (var i = 0; i < 250 && find.text('HOME').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('HOME'), findsOneWidget);
      expect(PreferencesService().logoUrl, logo);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      SyncService().dispose();
      if (AccountStorage.instance.isActive) {
        await tester.runAsync(() async => (await DatabaseHelper.instance.database).close());
      }
      await tester.runAsync(AccountStorage.instance.dispose);
      await tester.runAsync(Supabase.instance.dispose);
      client.close();
      messenger.setMockMethodCallHandler(path, null);
      messenger.setMockMethodCallHandler(connectivity, null);
      messenger.setMockMethodCallHandler(events, null);
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });
}
