import 'dart:convert';

import 'package:app_integral_complete/features/auth/data/auth_access_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const actor = '00000000-0000-0000-0000-000000000001';
  late SupabaseClient client;
  late MockClient transport;
  late AuthAccessRepository repository;
  var pending = true;
  var active = true;
  var completeFlag = true;
  var malformedResponse = false;
  var replaceSession = '';
  var revokeOnResponse = false;
  var currentActor = actor;
  var edgeCalls = 0;
  var membershipCalls = 0;

  setUp(() async {
    pending = true;
    active = true;
    completeFlag = true;
    malformedResponse = false;
    replaceSession = '';
    revokeOnResponse = false;
    currentActor = actor;
    edgeCalls = 0;
    membershipCalls = 0;
    transport = MockClient((request) async {
      Object? data;
      if (request.url.path == '/auth/v1/token') {
        final payload = base64Url
            .encode(
              utf8.encode(
                jsonEncode({
                  'sub': currentActor,
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
            'id': currentActor,
            'aud': 'authenticated',
            'app_metadata': {'account_type': 'staff', 'billar_id': 'A'},
            'user_metadata': <String, dynamic>{},
            'created_at': '2025-01-01T00:00:00Z',
          },
        };
      } else if (request.url.path == '/rest/v1/business_memberships') {
        membershipCalls++;
        expect(request.url.queryParameters['user_id'], 'eq.$actor');
        expect(request.url.queryParameters['billar_id'], 'eq.A');
        data = {
          'billar_id': 'A',
          'role': 'manager',
          'is_active': active,
          'must_change_password': pending,
          'username': 'caja',
          'allowed_modules': ['quick_sale'],
        };
      } else if (request.url.path == '/functions/v1/player-admin') {
        edgeCalls++;
        expect(
          request.headers['authorization'],
          'Bearer ${client.auth.currentSession!.accessToken}',
        );
        expect(jsonDecode(request.body), {
          'action': 'finish_password_change',
          'password': '  nueva1234  ',
        });
        if (replaceSession.isNotEmpty) {
          if (replaceSession == 'other') {
            currentActor = '00000000-0000-0000-0000-000000000002';
          }
          await client.auth.signInWithPassword(
            email: 'a@example.test',
            password: 'test',
          );
        }
        if (completeFlag) pending = false;
        if (revokeOnResponse) active = false;
        data = malformedResponse ? <String, dynamic>{} : {'ok': true};
      } else {
        throw StateError('Unexpected request: ${request.url.path}');
      }
      return http.Response(
        jsonEncode(data),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      httpClient: transport,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    await client.auth.signInWithPassword(
      email: 'a@example.test',
      password: 'test',
    );
    repository = AuthAccessRepository(
      client: client,
      enableStaffForIntegration: true,
    );
  });

  tearDown(() async {
    await client.dispose();
    transport.close();
  });

  test('default staff gate cannot call the password endpoint', () async {
    await expectLater(
      AuthAccessRepository(
        client: client,
      ).finishPasswordChange('  nueva1234  '),
      throwsStateError,
    );
    expect(edgeCalls, 0);
    expect(membershipCalls, 0);
  });

  test(
    'sends the exact password with the captured token and revalidates completion',
    () async {
      await repository.finishPasswordChange('  nueva1234  ');
      expect(edgeCalls, 1);
      expect(membershipCalls, 2);
      expect(pending, isFalse);
    },
  );

  test(
    'malformed success, pending flags and revoked accounts cannot complete',
    () async {
      malformedResponse = true;
      await expectLater(
        repository.finishPasswordChange('  nueva1234  '),
        throwsStateError,
      );
      pending = true;
      malformedResponse = false;
      completeFlag = false;
      await expectLater(
        repository.finishPasswordChange('  nueva1234  '),
        throwsStateError,
      );
      completeFlag = true;
      revokeOnResponse = true;
      await expectLater(
        repository.finishPasswordChange('  nueva1234  '),
        throwsStateError,
      );
      expect(edgeCalls, 3);
    },
  );

  for (final replacement in ['same', 'other']) {
    test(
      'rejects a $replacement account session replacement during the response',
      () async {
        replaceSession = replacement;
        await expectLater(
          repository.finishPasswordChange('  nueva1234  '),
          throwsStateError,
        );
        expect(edgeCalls, 1);
        expect(membershipCalls, 1);
      },
    );
  }
}
