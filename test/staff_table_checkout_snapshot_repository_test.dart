import 'dart:convert';

import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_checkout_snapshot_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
    'checkout snapshots require complete consistent authorized pages',
    () async {
      final auth =
          Session.fromJson({
            'access_token': 'token',
            'token_type': 'bearer',
            'user': {
              'id': 'cashier',
              'aud': 'authenticated',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2025-01-01T00:00:00Z',
            },
          })!;
      final SyncSession session = (
        actorId: 'cashier',
        billarId: 'A',
        token: 'token',
        authSession: auth,
        scopeGeneration: 1,
      );
      Map<String, Object> item(int ordinal) => {
        'ordinal': ordinal,
        'request_id': 'request-$ordinal',
        'product_id': ordinal,
        'product_name': 'Producto $ordinal',
        'quantity': 1,
        'price': 10,
        'recorded_at': '2026-11-17T18:00:00Z',
      };
      Map<String, Object> page({
        required int revision,
        required int count,
        required List<Object> items,
        required bool hasMore,
      }) => {
        'service_id': 'service-1',
        'billar_id': 'A',
        'table_id': 7,
        'table_type': 'Billar',
        'actor_id': 'waiter',
        'opened_at': '2026-11-17T18:00:00Z',
        'quoted_at': '2026-11-17T18:05:00Z',
        'time_cost': 3,
        'total': count * 10 + 3,
        'revision': revision,
        'item_count': count,
        'items': items,
        'has_more': hasMore,
      };
      final firstItems = [for (var i = 51; i >= 2; i--) item(i)];
      var responses = <Map<String, Object>>[
        page(revision: 51, count: 51, items: firstItems, hasMore: true),
        page(revision: 51, count: 51, items: [item(1)], hasMore: false),
      ];
      final requests = <Map<String, dynamic>>[];
      var validSession = true;
      var invalidateResponse = false;
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer token');
          expect(
            request.url.path,
            '/rest/v1/rpc/staff_table_checkout_snapshot',
          );
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          if (invalidateResponse) validSession = false;
          return http.Response(
            jsonEncode(responses.removeAt(0)),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final repo = StaffTableCheckoutSnapshotRepository(client, (_) {
        if (!validSession) throw StateError('La sesión cambió.');
      });
      Future<StaffTableCheckoutSnapshot> read() => repo.read(
        session: session,
        tableType: 'Billar',
        serviceId: 'service-1',
      );
      try {
        final result = await read();
        expect(result.items, hasLength(51));
        expect(result.items.first.ordinal, 51);
        expect(result.items.last.ordinal, 1);
        expect(result.actorId, 'waiter');
        expect(result.revision, 51);
        expect(result.timeCost, 3);
        expect(result.total, 513);
        expect(requests[0]['expected_revision'], isNull);
        expect(requests[1]['expected_revision'], 51);
        expect(requests[1]['before_ordinal'], 2);
        expect(requests[1]['requested_billar_id'], 'A');

        responses = [
          page(revision: 51, count: 51, items: firstItems, hasMore: true),
          {
            ...page(revision: 51, count: 51, items: [item(1)], hasMore: false),
            'quoted_at': '2026-11-17T18:06:00Z',
            'time_cost': 5,
            'total': 515,
          },
        ];
        final refreshedQuote = await read();
        expect(refreshedQuote.timeCost, 5);
        expect(refreshedQuote.total, 515);

        responses = [
          page(revision: 51, count: 51, items: firstItems, hasMore: true),
          page(revision: 52, count: 51, items: [item(1)], hasMore: false),
        ];
        await expectLater(read(), throwsFormatException);
        responses = [
          {
            ...page(revision: 1, count: 1, items: [item(1)], hasMore: false),
            'total': 999,
          },
        ];
        await expectLater(read(), throwsFormatException);
        responses = [
          {
            ...page(revision: 1, count: 1, items: [item(1)], hasMore: false),
            'quoted_at': '2020-01-01T00:00:00Z',
          },
        ];
        await expectLater(read(), throwsFormatException);
        responses = [
          page(revision: 2, count: 2, items: [item(2)], hasMore: false),
        ];
        await expectLater(read(), throwsFormatException);
        responses = [
          page(
            revision: 2,
            count: 2,
            items: [item(2), item(2)],
            hasMore: false,
          ),
        ];
        await expectLater(read(), throwsFormatException);
        responses = [
          {
            ...page(revision: 0, count: 0, items: [], hasMore: false),
            'billar_id': 'B',
          },
        ];
        await expectLater(read(), throwsFormatException);
        responses = [
          page(
            revision: 1,
            count: 1,
            items: [
              {...item(1), 'quantity': 0},
            ],
            hasMore: false,
          ),
        ];
        await expectLater(read(), throwsFormatException);
        responses = [page(revision: 0, count: 0, items: [], hasMore: false)];
        invalidateResponse = true;
        await expectLater(read(), throwsStateError);
        final requestCount = requests.length;
        await expectLater(read(), throwsStateError);
        expect(requests, hasLength(requestCount));
      } finally {
        await client.dispose();
      }
    },
  );
}
