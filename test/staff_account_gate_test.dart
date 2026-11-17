import 'dart:async';
import 'dart:convert';

import 'package:app_integral_complete/features/auth/data/auth_access_repository.dart';
import 'package:app_integral_complete/features/auth/domain/staff_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'unimplemented staff accounts cannot fall through to administrator setup',
    () async {
      SharedPreferences.setMockInitialValues({});
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
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
              'app_metadata': {'account_type': 'staff'},
              'user_metadata': <String, dynamic>{},
              'created_at': '2025-01-01T00:00:00Z',
            },
          }),
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
          authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
          ),
        );
        final response = await Supabase.instance.client.auth.signInWithPassword(
          email: 'test@example.com',
          password: 'test-password',
        );
        expect(requiresManagedAccountAccess(response.user!), isTrue);
        expect(
          (await AuthAccessRepository().resolveCurrentAccount()).kind,
          AccountKind.unavailable,
        );
        expect(requests, 1);
      } finally {
        await Supabase.instance.dispose();
        client.close();
      }
    },
  );

  test(
    'staff integration validates the active membership and session',
    () async {
      const actor = '00000000-0000-0000-0000-000000000001';
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
      Map<String, Object?>? membership = {
        'billar_id': 'A',
        'role': 'manager',
        'is_active': true,
        'must_change_password': true,
        'username': 'caja',
        'allowed_modules': ['quick_sale', 'players'],
      };
      final started = Completer<void>();
      final resume = Completer<void>();
      var delayMembership = false;
      var failMembership = false;
      String? authorization;
      final httpClient = MockClient((request) async {
        if (request.url.path == '/auth/v1/token') {
          return http.Response(
            jsonEncode({
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
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (request.url.path == '/auth/v1/logout') {
          return http.Response('', 204, request: request);
        }
        if (request.url.path == '/rest/v1/business_memberships') {
          expect(request.url.queryParameters['user_id'], 'eq.$actor');
          expect(request.url.queryParameters['billar_id'], 'eq.A');
          authorization = request.headers['authorization'];
          if (failMembership) {
            return http.Response(
              jsonEncode({'message': 'Database unavailable', 'code': 'XX000'}),
              500,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          if (delayMembership) {
            started.complete();
            await resume.future;
          }
          return http.Response(
            jsonEncode(membership),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        throw StateError('Unexpected request: ${request.url.path}');
      });
      final client = SupabaseClient(
        'http://localhost:54321',
        'test-key',
        httpClient: httpClient,
      );
      try {
        await client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        final token = client.auth.currentSession!.accessToken;
        final repository = AuthAccessRepository(
          client: client,
          enableStaffForIntegration: true,
        );
        final account = await repository.resolveCurrentAccount();
        expect(account.kind, AccountKind.staff);
        expect(account.billarId, 'A');
        expect(account.mustChangePassword, isTrue);
        expect(account.allowedModules, {
          StaffModule.quickSale,
          StaffModule.players,
        });
        expect(authorization, 'Bearer $token');

        final valid = Map<String, Object?>.from(membership);
        for (final change in [
          {'is_active': false},
          {'role': 'admin'},
          {'billar_id': 'B'},
          {'username': 'CAJA'},
          {'must_change_password': null},
          {'allowed_modules': <String>[]},
          {
            'allowed_modules': ['quick_sale', 'quick_sale'],
          },
          {
            'allowed_modules': ['unknown'],
          },
        ]) {
          membership = {...valid, ...change};
          expect(
            (await repository.resolveCurrentAccount()).kind,
            AccountKind.blocked,
            reason: '$change must not grant staff access',
          );
        }
        membership = null;
        expect(
          (await repository.resolveCurrentAccount()).kind,
          AccountKind.blocked,
        );

        membership = valid;
        failMembership = true;
        await expectLater(
          repository.resolveCurrentAccount(),
          throwsA(isA<PostgrestException>()),
        );
        failMembership = false;
        delayMembership = true;
        final pending = repository.resolveCurrentAccount();
        final assertion = expectLater(pending, throwsStateError);
        await started.future;
        await client.auth.signOut();
        resume.complete();
        await assertion;
      } finally {
        await client.dispose();
        httpClient.close();
      }
    },
  );
}
