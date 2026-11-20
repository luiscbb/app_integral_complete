import 'dart:convert';

import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_late_adjustment_snapshot_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('late adjustment snapshots require complete consistent pages', () async {
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
      'price': 1,
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
      'revision': revision,
      'item_count': count,
      'total': count.toDouble(),
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
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer token');
        expect(
          request.url.path,
          '/rest/v1/rpc/staff_table_late_adjustment_snapshot',
        );
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode(responses.removeAt(0)),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    final repository = StaffTableLateAdjustmentSnapshotRepository(client, (_) {
      if (!validSession) throw StateError('La sesión cambió.');
    });
    Future<StaffTableLateAdjustmentSnapshot> read() => repository.read(
      session: session,
      tableType: 'Billar',
      serviceId: 'service-1',
    );
    try {
      final result = await read();
      expect(result.items, hasLength(51));
      expect(result.items.first.ordinal, 51);
      expect(result.items.last.ordinal, 1);
      expect(result.revision, 51);
      expect(result.total, 51);
      expect(requests[0]['before_ordinal'], isNull);
      expect(requests[1]['before_ordinal'], 2);
      expect(requests[1]['requested_billar_id'], 'A');

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
          'billar_id': 'B',
        },
      ];
      await expectLater(read(), throwsFormatException);
      responses = [
        page(revision: 2, count: 2, items: [item(2), item(2)], hasMore: false),
      ];
      await expectLater(read(), throwsFormatException);
      final requestCount = requests.length;
      validSession = false;
      await expectLater(read(), throwsStateError);
      expect(requests, hasLength(requestCount));
    } finally {
      await client.dispose();
    }
  });
}
