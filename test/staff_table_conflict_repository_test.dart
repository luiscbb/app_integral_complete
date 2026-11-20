import 'dart:convert';

import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_conflict_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'conflict pages enforce scope, ordering and complete consumption details',
    () async {
      final auth =
          Session.fromJson({
            'access_token': 'token',
            'token_type': 'bearer',
            'user': {
              'id': 'admin',
              'aud': 'authenticated',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2025-01-01T00:00:00Z',
            },
          })!;
      final SyncSession session = (
        actorId: 'admin',
        billarId: 'A',
        token: 'token',
        authSession: auth,
        scopeGeneration: 1,
      );
      var sessionValid = true;
      var changeDuringResponse = false;
      var calls = 0;
      Object response = {
        'billar_id': 'A',
        'table_type': 'Billar',
        'has_more': false,
        'items': [
          {
            'ordinal': 10,
            'service_id': 'service-1',
            'actor_id': 'waiter',
            'billar_id': 'A',
            'table_type': 'Billar',
            'table_id': 7,
            'opened_at': '2026-11-17T18:00:00Z',
            'reason': 'late_consumption',
          },
        ],
      };
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          calls++;
          expect(request.headers['authorization'], 'Bearer token');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['requested_billar_id'], 'A');
          expect(body['requested_table_type'], 'Billar');
          if (changeDuringResponse) sessionValid = false;
          return http.Response(
            jsonEncode(response),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final repository = StaffTableConflictRepository(client, (_) {
        if (!sessionValid) throw StateError('La sesión cambió.');
      });
      try {
        final page = await repository.list(
          session: session,
          tableType: 'Billar',
        );
        expect(page.items.single.serviceId, 'service-1');
        expect(page.items.single.actorId, 'waiter');
        expect(page.items.single.reason, 'late_consumption');
        expect(page.hasMore, false);

        response = {
          'billar_id': 'A',
          'table_type': 'Billar',
          'service_id': 'service-1',
          'has_more': false,
          'items': [
            {
              'ordinal': 3,
              'request_id': 'request-1',
              'product_id': 5,
              'product_name': 'Agua',
              'quantity': 2,
              'price': 12,
              'recorded_at': '2026-11-17T18:00:00Z',
            },
          ],
        };
        final detail = await repository.consumptions(
          session: session,
          tableType: 'Billar',
          serviceId: 'service-1',
        );
        expect(detail.items.single.productName, 'Agua');
        expect(detail.items.single.quantity, 2);
        await expectLater(
          repository.consumptions(
            session: session,
            tableType: 'Billar',
            serviceId: 'service-2',
          ),
          throwsFormatException,
        );

        response = {
          'billar_id': 'A',
          'table_type': 'Billar',
          'service_id': 'service-1',
          'has_more': true,
          'items': <Object>[],
        };
        await expectLater(
          repository.consumptions(
            session: session,
            tableType: 'Billar',
            serviceId: 'service-1',
          ),
          throwsFormatException,
        );
        response = {
          'billar_id': 'B',
          'table_type': 'Billar',
          'has_more': false,
          'items': <Object>[],
        };
        await expectLater(
          repository.list(session: session, tableType: 'Billar'),
          throwsFormatException,
        );
        response = {
          'billar_id': 'A',
          'table_type': 'Billar',
          'has_more': false,
          'items': [
            {
              'ordinal': 4,
              'service_id': 'same',
              'actor_id': 'a',
              'billar_id': 'A',
              'table_type': 'Billar',
              'table_id': 1,
              'opened_at': '2026-01-01T00:00:00Z',
            },
            {
              'ordinal': 3,
              'service_id': 'same',
              'actor_id': 'a',
              'billar_id': 'A',
              'table_type': 'Billar',
              'table_id': 2,
              'opened_at': '2026-01-01T00:00:00Z',
            },
          ],
        };
        await expectLater(
          repository.list(session: session, tableType: 'Billar'),
          throwsFormatException,
        );
        response = {
          'billar_id': 'A',
          'table_type': 'Billar',
          'has_more': false,
          'items': [],
        };
        changeDuringResponse = true;
        await expectLater(
          repository.list(session: session, tableType: 'Billar'),
          throwsStateError,
        );
        final before = calls;
        await expectLater(
          repository.list(session: session, tableType: 'Billar'),
          throwsStateError,
        );
        expect(calls, before);
        sessionValid = true;
        changeDuringResponse = false;
        response = {
          'service_id': 'service-1',
          'billar_id': 'A',
          'table_type': 'Billar',
          'state': 'conflict',
          'reviewed_at': '2026-11-19T20:00:00Z',
          'reviewed_by': 'manager',
        };
        final reviewed = await repository.reviewOpening(
          session: session,
          tableType: 'Billar',
          serviceId: 'service-1',
        );
        expect(reviewed.reviewedBy, 'manager');
        expect(reviewed.reviewedAt, DateTime.parse('2026-11-19T20:00:00Z'));
        response = {
          'service_id': 'service-1',
          'billar_id': 'B',
          'table_type': 'Billar',
          'state': 'conflict',
          'reviewed_at': '2026-11-19T20:00:00Z',
          'reviewed_by': 'manager',
        };
        await expectLater(
          repository.reviewOpening(
            session: session,
            tableType: 'Billar',
            serviceId: 'service-1',
          ),
          throwsFormatException,
        );
      } finally {
        await client.dispose();
      }
    },
  );
}
