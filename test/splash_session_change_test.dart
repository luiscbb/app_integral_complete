import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/routes/app_routes.dart';
import 'package:app_integral_complete/core/storage/account_storage.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/core/theme/theme_provider.dart';
import 'package:app_integral_complete/features/home/presentation/pages/splash_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('splash retries for a new session without signing it out', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('splash_scope_'),
    ))!;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    SharedPreferences.setMockInitialValues({'billar_id': 'A'});
    await tester.runAsync(PreferencesService().init);
    final started = Completer<void>();
    final resume = Completer<void>();
    var signOuts = 0;
    final httpClient = MockClient((request) async {
      Object? data;
      var status = 200;
      if (request.url.path == '/auth/v1/token') {
        final email = (jsonDecode(request.body) as Map)['email'];
        final player = email == 'b@example.com';
        final id = player
            ? '00000000-0000-0000-0000-000000000002'
            : '00000000-0000-0000-0000-000000000001';
        final payload = base64Url.encode(utf8.encode(jsonEncode({
          'sub': id,
          'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
        }))).replaceAll('=', '');
        data = {
          'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-$id',
          'user': {
            'id': id,
            'aud': 'authenticated',
            'app_metadata': player ? {'account_type': 'player'} : <String, dynamic>{},
            'user_metadata': <String, dynamic>{},
            'created_at': '2025-01-01T00:00:00Z',
          },
        };
      } else if (request.url.path == '/rest/v1/players') {
        final id = request.url.queryParameters['auth_user_id'];
        if (id == 'eq.00000000-0000-0000-0000-000000000001') {
          started.complete();
          await resume.future;
          data = null;
        } else {
          data = {
            'id': 'player-b',
            'name': 'JUGADOR B',
            'billar_id': 'B',
            'is_active': true,
            'must_change_password': false,
          };
        }
      } else if (request.url.path == '/auth/v1/logout') {
        signOuts++;
        status = 204;
      } else {
        throw StateError('Unexpected request: ${request.method} ${request.url.path}');
      }
      return http.Response(
        status == 204 ? '' : jsonEncode(data),
        status,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    try {
      await tester.runAsync(() => Supabase.initialize(
        url: 'http://localhost:54321',
        publishableKey: 'test-key',
        httpClient: httpClient,
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
        ),
      ));
      final client = Supabase.instance.client;
      AccountStorage.initialize(client);
      await tester.runAsync(() => client.auth.signInWithPassword(email: 'a@example.com', password: 'test'));
      await tester.pumpWidget(ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: const SplashPage(),
          routes: {
            AppRoutes.playerPortal: (_) => const Scaffold(body: Text('PORTAL B')),
            AppRoutes.login: (_) => const Scaffold(body: Text('LOGIN')),
          },
        ),
      ));
      await tester.pump();
      await tester.runAsync(() => started.future.timeout(const Duration(seconds: 5)));
      await tester.runAsync(() => client.auth.signInWithPassword(email: 'b@example.com', password: 'test'));
      resume.complete();
      for (var i = 0; i < 100 && find.text('PORTAL B').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('PORTAL B'), findsOneWidget);
      expect(signOuts, 0);
      expect(client.auth.currentUser?.id, '00000000-0000-0000-0000-000000000002');
      expect(PreferencesService().billarId, 'B');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (AccountStorage.instance.isActive) {
        await tester.runAsync(() async => (await DatabaseHelper.instance.database).close());
      }
      await tester.runAsync(AccountStorage.instance.dispose);
      await tester.runAsync(Supabase.instance.dispose);
      httpClient.close();
      messenger.setMockMethodCallHandler(channel, null);
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });
}
