import 'dart:convert';

import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/reports/data/repositories/staff_purchase_report_repository.dart';
import 'package:app_integral_complete/features/reports/data/repositories/staff_report_repository.dart';
import 'package:app_integral_complete/features/auth/domain/staff_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const actor = '00000000-0000-0000-0000-000000000001';
  final start = DateTime.utc(2026, 1);
  final end = DateTime.utc(2026, 2);
  late SupabaseClient client;
  late MockClient transport;
  late SyncSession session;
  late StaffPurchaseReportRepository repository;
  late Map<String, Object?> membership;
  late Map<String, Object?> response;
  late Map<String, Object?> row;
  late List<Map<String, dynamic>> requests;
  var generation = 1;
  var revokeDuringRead = false;
  var changeScopeDuringRead = false;

  setUp(() async {
    generation = 1;
    revokeDuringRead = false;
    changeScopeDuringRead = false;
    requests = [];
    membership = {
      'billar_id': 'A',
      'role': 'manager',
      'is_active': true,
      'username': 'consulta',
      'must_change_password': false,
      'allowed_modules': ['reports_purchases'],
    };
    row = {
      'id': 52,
      'billar_id': 'A',
      'date': '2026-01-15T12:00:00Z',
      'reference': 'REF',
      'provider_name': 'Proveedor A',
      'total': 10,
      'paid_amount': 0,
      'balance_due': 10,
    };
    response = {
      'billar_id': 'A',
      'count': 52,
      'total': 520,
      'paid': 510,
      'balance': 10,
      'has_more': true,
      'items': List.generate(50, (index) => {...row, 'id': 52 - index}),
    };
    transport = MockClient((request) async {
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
            'created_at': '2025-01-01T00:00:00Z',
            'app_metadata': {'account_type': 'staff', 'billar_id': 'A'},
            'user_metadata': <String, dynamic>{},
          },
        };
      } else {
        expect(request.headers['authorization'], 'Bearer ${session.token}');
        if (request.url.path == '/rest/v1/business_memberships') {
          expect(request.method, 'GET');
          expect(request.url.queryParameters['user_id'], 'eq.$actor');
          expect(request.url.queryParameters['billar_id'], 'eq.A');
          data = membership;
        } else if (request.url.path == '/rest/v1/rpc/staff_purchase_report' ||
            request.url.path == '/rest/v1/rpc/staff_read_report') {
          expect(request.method, 'POST');
          final params = jsonDecode(request.body) as Map<String, dynamic>;
          expect(params['requested_billar_id'], 'A');
          expect(params['start_at'], start.toIso8601String());
          expect(params['end_at'], end.toIso8601String());
          requests.add(params);
          if (revokeDuringRead) membership['allowed_modules'] = ['purchases'];
          if (changeScopeDuringRead) generation++;
          data = response;
        } else {
          throw StateError(
            'Unexpected report request: ${request.method} ${request.url.path}',
          );
        }
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
    final auth = client.auth.currentSession!;
    session = (
      actorId: actor,
      billarId: 'A',
      token: auth.accessToken,
      authSession: auth,
      scopeGeneration: 1,
    );
    repository = StaffPurchaseReportRepository(client, (expected) {
      if (generation != expected.scopeGeneration ||
          expected.actorId != client.auth.currentUser?.id ||
          !identical(client.auth.currentSession, expected.authSession)) {
        throw StateError('La sesión o el billar cambió.');
      }
    });
  });

  tearDown(() async {
    await client.dispose();
    transport.close();
  });

  test(
    'reads each report independently, preserving signed Kardex and nullable profit',
    () async {
      final generic = StaffReportRepository(client, repository.requireSession);
      for (final (module, metrics) in [
        (StaffModule.reportsSales, {'total': 10, 'paid': 8}),
        (StaffModule.reportsKardex, <String, num?>{}),
        (
          StaffModule.reportsCashFlow,
          {
            'sales': 10,
            'purchases': 5,
            'inflows': 0,
            'outflows': 8,
            'netCash': -3,
            'netFlow': -3,
          },
        ),
        (
          StaffModule.reportsProfit,
          {'sales': 10, 'cost': null, 'expenses': 5, 'profit': null},
        ),
      ]) {
        membership['allowed_modules'] = [module.id];
        final hasRows =
            module == StaffModule.reportsSales ||
            module == StaffModule.reportsKardex;
        response = {
          'billar_id': 'A',
          'report': module.id,
          'count': 1,
          'has_more': false,
          'metrics': metrics,
          'incomplete_expenses': false,
          'items': [
            if (hasRows)
              {
                'id': 1,
                'billar_id': 'A',
                'date': '2026-01-15T12:00:00Z',
                'label': 'Registro',
                'details': 'Detalle',
                'amount': module == StaffModule.reportsKardex ? -2 : 10,
              },
          ],
        };
        final result = await generic.load(session, module, start, end);
        expect(result.count, 1);
        expect(result.metrics.length, metrics.length);
        expect(result.items.length, hasRows ? 1 : 0);
        expect(requests.last['requested_report'], module.id);
        if (module == StaffModule.reportsKardex) {
          expect(result.items.single.amount, -2);
        }
        if (module == StaffModule.reportsProfit) {
          expect(result.metrics['Utilidad'], isNull);
        }
      }
    },
  );

  test(
    'generic reports reject mismatched responses and mid-request revocation',
    () async {
      final generic = StaffReportRepository(client, repository.requireSession);
      membership['allowed_modules'] = ['reports_sales'];
      response = {
        'billar_id': 'A',
        'report': 'reports_sales',
        'count': 0,
        'has_more': false,
        'metrics': {'total': 0, 'paid': 0},
        'items': [],
        'incomplete_expenses': false,
      };
      final valid = Map<String, Object?>.from(response);
      for (final change in [
        {'report': 'reports_profit'},
        {'billar_id': 'B'},
        {
          'metrics': {'total': -1, 'paid': 0},
        },
        {
          'metrics': {'total': 0},
        },
        {'has_more': true},
      ]) {
        response = {...valid, ...change};
        await expectLater(
          generic.load(session, StaffModule.reportsSales, start, end),
          throwsFormatException,
        );
      }
      response = valid;
      revokeDuringRead = true;
      await expectLater(
        generic.load(session, StaffModule.reportsSales, start, end),
        throwsStateError,
      );
      membership['allowed_modules'] = ['reports_sales'];
      revokeDuringRead = false;
      changeScopeDuringRead = true;
      await expectLater(
        generic.load(session, StaffModule.reportsSales, start, end),
        throwsStateError,
      );
    },
  );

  test(
    'reads full-range totals and paginated rows without granting operational access',
    () async {
      final first = await repository.load(session, start, end);
      expect(first.count, 52);
      expect(first.total, 520);
      expect(first.paid, 510);
      expect(first.balance, 10);
      expect(first.items.length, 50);
      expect(first.items.first.id, 52);
      expect(first.items.last.id, 3);
      expect(first.hasMore, isTrue);
      response['items'] = [
        {...row, 'id': 2},
        {...row, 'id': 1},
      ];
      response['has_more'] = false;
      final second = await repository.load(session, start, end, beforeId: 3);
      expect(second.items.map((row) => row.id), [2, 1]);
      expect(second.total, 520);
      expect(second.hasMore, isFalse);
      expect(requests.map((params) => params['before_id']), [null, 3]);
    },
  );

  test(
    'refuses purchases-only, password-pending and revoked memberships before reading',
    () async {
      for (final change in [
        {
          'allowed_modules': ['purchases'],
        },
        {
          'allowed_modules': ['reports'],
        },
        {'is_active': false},
        {'must_change_password': true},
      ]) {
        final valid = Map<String, Object?>.from(membership);
        membership.addAll(change);
        await expectLater(
          repository.load(session, start, end),
          throwsStateError,
        );
        membership = valid;
      }
      expect(requests, isEmpty);
      await expectLater(
        repository.load(session, end, start),
        throwsArgumentError,
      );
    },
  );

  test(
    'discards a response if permission or account scope changes during reading',
    () async {
      revokeDuringRead = true;
      await expectLater(repository.load(session, start, end), throwsStateError);
      membership['allowed_modules'] = ['reports_purchases'];
      revokeDuringRead = false;
      changeScopeDuringRead = true;
      await expectLater(repository.load(session, start, end), throwsStateError);
    },
  );

  test(
    'rejects foreign, repeated, out-of-range and malformed data instead of publishing it',
    () async {
      final original = Map<String, Object?>.from(response);
      for (final change in [
        {'billar_id': 'B'},
        {'total': '520'},
        {
          'items': [
            {...row, 'billar_id': 'B'},
          ],
          'has_more': false,
        },
        {
          'items': [row, row],
          'has_more': false,
        },
        {
          'items': [
            {...row, 'date': '2026-02-01T00:00:00Z'},
          ],
          'has_more': false,
        },
        {
          'items': [
            {...row, 'balance_due': -1},
          ],
          'has_more': false,
        },
        {
          'items': [row],
          'has_more': true,
        },
      ]) {
        response = {...original, ...change};
        await expectLater(
          repository.load(session, start, end),
          throwsFormatException,
        );
      }
      response = {
        ...original,
        'items': [row],
        'has_more': false,
      };
      await expectLater(
        repository.load(session, start, end, beforeId: 52),
        throwsFormatException,
      );
    },
  );
}
