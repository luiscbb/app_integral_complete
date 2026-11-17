import 'dart:async';
import 'dart:convert';

import 'package:app_integral_complete/features/auth/data/auth_access_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const userId = '00000000-0000-0000-0000-000000000001';

  Future<AccountAccess> resolve({
    List<Map<String, dynamic>> activeMemberships = const [],
    Map<String, dynamic>? ownerMembership,
    String? membershipError,
    bool membershipHidden = false,
  }) async {
    final client = MockClient((request) async {
      Object? data;
      var status = 200;
      switch (request.url.path) {
        case '/auth/v1/token':
          final payload = base64Url
              .encode(
                utf8.encode(
                  jsonEncode({
                    'sub': userId,
                    'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
                  }),
                ),
              )
              .replaceAll('=', '');
          data = {
            'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'test-refresh',
            'user': {
              'id': userId,
              'aud': 'authenticated',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2025-01-01T00:00:00Z',
            },
          };
        case '/rest/v1/players':
          data = null;
        case '/rest/v1/billar_settings':
          data = {'billar_id': 'A'};
        case '/rest/v1/business_memberships':
          expect(request.url.queryParameters['is_active'], 'eq.true');
          if (membershipError != null) {
            status = 400;
            data = {'code': membershipError, 'message': 'membership unavailable'};
          } else {
            data = membershipHidden
                ? []
                : [
                    ...activeMemberships,
                    if (ownerMembership != null)
                      {'billar_id': 'A', ...ownerMembership},
                  ].where((row) => row['is_active'] == true).toList();
          }
        default:
          throw StateError('Unexpected request: ${request.url.path}');
      }
      return http.Response(
        jsonEncode(data),
        status,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    final supabase = SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: client,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    try {
      await supabase.auth.signInWithPassword(
        email: 'owner@example.com',
        password: 'test',
      );
      return await AuthAccessRepository(
        client: supabase,
      ).resolveCurrentAccount();
    } finally {
      await supabase.dispose();
      client.close();
    }
  }

  test(
    'inactive owner cannot regain access through business settings',
    () async {
      final account = await resolve(
        ownerMembership: {'role': 'admin', 'is_active': false},
      );
      expect(account.kind, AccountKind.blocked);
    },
  );

  test(
    'legacy owner remains supported only if the membership table is absent',
    () async {
      expect((await resolve()).kind, AccountKind.blocked);
      expect((await resolve(membershipError: '42P01')).kind, AccountKind.owner);
      expect(
        (await resolve(membershipError: 'PGRST205')).kind,
        AccountKind.owner,
      );
    },
  );

  test('an owner cannot bypass a membership hidden by RLS', () async {
    final account = await resolve(
      ownerMembership: {
        'role': 'admin',
        'is_active': true,
        'must_change_password': false,
      },
      membershipHidden: true,
    );
    expect(account.kind, AccountKind.blocked);
  });

  test('membership errors cannot bypass access through settings', () async {
    await expectLater(
      resolve(membershipError: '42501'),
      throwsA(isA<PostgrestException>()),
    );
  });

  test(
    'another active manager membership keeps its own business and role',
    () async {
      final account = await resolve(
        activeMemberships: [
          {
            'billar_id': 'B',
            'role': 'manager',
            'is_active': true,
            'must_change_password': false,
          },
        ],
        ownerMembership: {'role': 'admin', 'is_active': false},
      );
      expect(account.kind, AccountKind.manager);
      expect(account.billarId, 'B');
    },
  );

  test(
    'an administrator membership cannot unlock another owner business',
    () async {
      final account = await resolve(
        activeMemberships: [
          {
            'billar_id': 'B',
            'role': 'admin',
            'is_active': true,
            'must_change_password': false,
          },
        ],
        ownerMembership: {'role': 'admin', 'is_active': false},
      );
      expect(account.kind, AccountKind.blocked);
    },
  );

  test('an active administrator can access the matching business', () async {
    final account = await resolve(
      activeMemberships: [
        {
          'billar_id': 'A',
          'role': 'admin',
          'is_active': true,
          'must_change_password': false,
        },
      ],
    );
    expect(account.kind, AccountKind.owner);
    expect(account.billarId, 'A');
  });

  test(
    'the matching owner membership wins regardless of membership order',
    () async {
      final account = await resolve(
        activeMemberships: [
          {
            'billar_id': 'B',
            'role': 'admin',
            'is_active': true,
            'must_change_password': false,
          },
          {
            'billar_id': 'A',
            'role': 'admin',
            'is_active': true,
            'must_change_password': false,
          },
        ],
      );
      expect(account.kind, AccountKind.owner);
      expect(account.billarId, 'A');
    },
  );

  test('access verification keeps its token and rejects changed sessions', () async {
    for (final (pausedPath, membershipError, sameUser) in [
      ('/rest/v1/players', false, false),
      ('/rest/v1/business_memberships', true, false),
      ('/rest/v1/billar_settings', false, true),
    ]) {
      final started = Completer<void>();
      final resume = Completer<void>();
      final authorizations = <String?>[];
      var signIns = 0;
      final httpClient = MockClient((request) async {
        Object? data;
        var status = 200;
        if (request.url.path == '/auth/v1/token') {
          final email = (jsonDecode(request.body) as Map)['email'];
          final id = email == 'other@example.com'
              ? '00000000-0000-0000-0000-000000000002'
              : userId;
          final payload = base64Url.encode(utf8.encode(jsonEncode({
            'sub': id,
            'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
            'nonce': ++signIns,
          }))).replaceAll('=', '');
          data = {
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
          };
        } else {
          authorizations.add(request.headers['authorization']);
          if (request.url.path == pausedPath) {
            started.complete();
            await resume.future;
          }
          switch (request.url.path) {
            case '/rest/v1/players':
              data = null;
            case '/rest/v1/business_memberships':
              if (membershipError) {
                status = 400;
                data = {'code': '42P01', 'message': 'table unavailable'};
              } else {
                data = [];
              }
            case '/rest/v1/billar_settings':
              data = {'billar_id': 'A'};
            default:
              throw StateError('Unexpected request: ${request.url.path}');
          }
        }
        return http.Response(
          jsonEncode(data),
          status,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      final supabase = SupabaseClient(
        'http://localhost:54321',
        'test-key',
        httpClient: httpClient,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      try {
        await supabase.auth.signInWithPassword(email: 'owner@example.com', password: 'test');
        final token = supabase.auth.currentSession!.accessToken;
        final result = AuthAccessRepository(client: supabase).resolveCurrentAccount();
        final assertion = expectLater(result, throwsStateError);
        await started.future.timeout(const Duration(seconds: 5));
        await supabase.auth.signInWithPassword(
          email: sameUser ? 'owner@example.com' : 'other@example.com',
          password: 'test',
        );
        resume.complete();
        await assertion;
        expect(authorizations, everyElement('Bearer $token'));
        expect(authorizations.length, switch (pausedPath) {
          '/rest/v1/players' => 1,
          '/rest/v1/business_memberships' => 2,
          _ => 3,
        });
      } finally {
        await supabase.dispose();
        httpClient.close();
      }
    }
  });
}
