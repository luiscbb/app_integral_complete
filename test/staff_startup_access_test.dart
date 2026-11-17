import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/routes/app_router.dart';
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
  testWidgets(
    'saved staff sessions require the startup gate and mandatory password',
    (tester) async {
      const actor = '00000000-0000-0000-0000-000000000001';
      const path = MethodChannel('plugins.flutter.io/path_provider');
      final directory =
          (await tester.runAsync(
            () => Directory.systemTemp.createTemp('staff_startup_access_'),
          ))!;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(path, (_) async => directory.path);
      SharedPreferences.setMockInitialValues({
        'billar_id': 'ORIGINAL',
        'business_name': 'NEGOCIO ORIGINAL',
      });
      final preferences = PreferencesService();
      await tester.runAsync(preferences.init);
      var membershipCalls = 0;
      final transport = MockClient((request) async {
        Object? data;
        if (request.url.path == '/auth/v1/token') {
          final payload = base64Url
              .encode(
                utf8.encode(
                  jsonEncode({
                    'sub': actor,
                    'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
                  }),
                ),
              )
              .replaceAll('=', '');
          data = {
            'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'test',
            'user': {
              'id': actor,
              'aud': 'authenticated',
              'app_metadata': {'account_type': 'staff', 'billar_id': 'A'},
              'user_metadata': <String, dynamic>{},
              'created_at': '2025-01-01T00:00:00Z',
            },
          };
        } else if (request.url.path == '/auth/v1/logout') {
          return http.Response('', 204, request: request);
        } else if (request.url.path == '/rest/v1/business_memberships') {
          membershipCalls++;
          expect(request.url.queryParameters['user_id'], 'eq.$actor');
          expect(request.url.queryParameters['billar_id'], 'eq.A');
          data = {
            'billar_id': 'A',
            'role': 'manager',
            'is_active': true,
            'username': 'caja',
            'must_change_password': true,
            'allowed_modules': ['quick_sale'],
          };
        } else {
          throw StateError('Unexpected startup request: ${request.url}');
        }
        return http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      Future<void> waitFor(String text) async {
        for (var attempt = 0; attempt < 300; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (find.text(text).evaluate().isNotEmpty) {
            await tester.pumpAndSettle();
            return;
          }
        }
        fail('El arranque no mostró $text.');
      }

      try {
        await tester.runAsync(
          () => Supabase.initialize(
            url: 'https://example.supabase.co',
            publishableKey: 'test-key',
            httpClient: transport,
            authOptions: const FlutterAuthClientOptions(
              autoRefreshToken: false,
              detectSessionInUri: false,
            ),
          ),
        );
        final client = Supabase.instance.client;
        await tester.runAsync(
          () => client.auth.signInWithPassword(
            email: 'a@example.test',
            password: 'test',
          ),
        );
        AccountStorage.initialize(client);
        await tester.pumpWidget(
          ChangeNotifierProvider(
            create: (_) => ThemeProvider()..init(),
            child: const MaterialApp(
              home: SplashPage(),
              onGenerateRoute: AppRouter.onGenerateRoute,
            ),
          ),
        );
        await waitFor('ENTRAR');
        expect(client.auth.currentUser, isNull);
        expect(membershipCalls, 0);
        expect(AccountStorage.instance.isActive, isFalse);
        expect(AccountStorage.instance.requiresRestart, isFalse);
        expect(preferences.billarId, 'ORIGINAL');
        expect(preferences.businessName, 'NEGOCIO ORIGINAL');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
          () => client.auth.signInWithPassword(
            email: 'a@example.test',
            password: 'test',
          ),
        );
        await tester.pumpWidget(
          ChangeNotifierProvider(
            create: (_) => ThemeProvider()..init(),
            child: MaterialApp(
              home: const SplashPage(enableStaffForIntegration: true),
              onGenerateRoute:
                  (settings) => AppRouter.generateRoute(
                    settings,
                    enableStaffForIntegration: true,
                  ),
            ),
          ),
        );
        await waitFor('CAMBIAR CONTRASEÑA');
        expect(AccountStorage.instance.isActive, isTrue);
        expect(preferences.billarId, 'A');
        expect(preferences.businessName, isNot('NEGOCIO ORIGINAL'));
        expect(membershipCalls, greaterThanOrEqualTo(2));
        expect(find.text('MI ACCESO · PERSONAL'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (AccountStorage.instance.isActive) {
            await (await DatabaseHelper.instance.database).close();
          }
        });
        await tester.runAsync(AccountStorage.instance.dispose);
        await tester.runAsync(Supabase.instance.dispose);
        transport.close();
        messenger.setMockMethodCallHandler(path, null);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
