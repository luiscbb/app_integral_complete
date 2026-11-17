import 'dart:convert';

import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/core/storage/account_storage.dart';
import 'package:app_integral_complete/features/auth/presentation/pages/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets(
    'staff login is normalized and blocked without changing local business',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'billar_id': 'BILLAR_ORIGINAL',
        'business_name': 'NEGOCIO ORIGINAL',
        'user_name': 'ADMIN',
      });
      final prefs = PreferencesService();
      await tester.runAsync(prefs.init);
      String? submittedEmail;
      var inactiveOwner = false;
      var inactiveOwnerChecked = false;
      final client = MockClient((request) async {
        if (request.url.path == '/auth/v1/logout') {
          return http.Response('', 204, request: request);
        }
        if (inactiveOwner && request.url.path.startsWith('/rest/v1/')) {
          if (request.url.path == '/rest/v1/business_memberships' &&
              request.url.queryParameters['is_active'] == 'eq.true') {
            inactiveOwnerChecked = true;
          }
          final Object? data = switch (request.url.path) {
            '/rest/v1/players' => null,
            '/rest/v1/billar_settings' => {'billar_id': 'BILLAR_OTRO'},
            '/rest/v1/business_memberships' =>
              request.url.queryParameters.containsKey('is_active')
                  ? []
                  : {'role': 'admin', 'is_active': false},
            _ => throw StateError('Unexpected request: ${request.url.path}'),
          };
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        submittedEmail =
            (jsonDecode(request.body) as Map<String, dynamic>)['email']
                as String?;
        final payload = base64Url
            .encode(
              utf8.encode(
                jsonEncode({
                  'sub': '00000000-0000-0000-0000-000000000001',
                  'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
                }),
              ),
            )
            .replaceAll('=', '');
        return http.Response(
          jsonEncode({
            'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'test-refresh',
            'user': {
              'id': '00000000-0000-0000-0000-000000000001',
              'aud': 'authenticated',
              'app_metadata':
                  inactiveOwner
                      ? <String, dynamic>{}
                      : {'account_type': 'staff'},
              'user_metadata': {
                'full_name': 'OTRO',
                'business_name': 'OTRO',
                'billar_id': 'OTRO',
              },
              'created_at': '2025-01-01T00:00:00Z',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      try {
        await tester.runAsync(
          () => Supabase.initialize(
            url: 'http://localhost:54321',
            publishableKey: 'test-key',
            httpClient: client,
            authOptions: const FlutterAuthClientOptions(
              autoRefreshToken: false,
              detectSessionInUri: false,
            ),
          ),
        );
        AccountStorage.initialize(Supabase.instance.client);
        await tester.pumpWidget(const MaterialApp(home: LoginPage()));
        await tester.enterText(find.byType(TextField).at(0), ' CAJERO..01 ');
        await tester.enterText(find.byType(TextField).at(1), 'test-password');
        await tester.ensureVisible(find.text('ENTRAR'));
        await tester.tap(find.text('ENTRAR'));
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 10));
          if (find
              .textContaining('La cuenta está inactiva')
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }

        expect(submittedEmail, '63616a65726f2e2e3031@staff.baumar.invalid');
        expect(find.textContaining('La cuenta está inactiva'), findsOneWidget);
        expect(prefs.billarId, 'BILLAR_ORIGINAL');
        expect(prefs.businessName, 'NEGOCIO ORIGINAL');
        expect(prefs.userName, 'ADMIN');
        expect(Supabase.instance.client.auth.currentUser, isNull);

        submittedEmail = null;
        await tester.enterText(
          find.byType(TextField).at(0),
          'Owner@Example.com',
        );
        await tester.ensureVisible(find.text('ENTRAR'));
        await tester.tap(find.text('ENTRAR'));
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 10));
          if (submittedEmail != null &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            break;
          }
        }
        expect(submittedEmail, 'Owner@Example.com');

        inactiveOwner = true;
        await tester.ensureVisible(find.text('ENTRAR'));
        await tester.tap(find.text('ENTRAR'));
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 10));
          if (inactiveOwnerChecked &&
              Supabase.instance.client.auth.currentUser == null &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            break;
          }
        }
        expect(inactiveOwnerChecked, isTrue);
        expect(Supabase.instance.client.auth.currentUser, isNull);
        expect(prefs.billarId, 'BILLAR_ORIGINAL');
        expect(prefs.businessName, 'NEGOCIO ORIGINAL');
        expect(prefs.userName, 'ADMIN');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(AccountStorage.instance.dispose);
        await tester.runAsync(Supabase.instance.dispose);
        client.close();
      }
    },
  );
}
