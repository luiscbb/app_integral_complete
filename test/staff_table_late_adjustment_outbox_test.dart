import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_conflict_repository.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_late_adjustment_outbox.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_late_adjustment_snapshot_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'late adjustment retries its durable request without closing the service',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'table_late_adjustment_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      final dbPath = path.join(
        directory.path,
        'BaumarSolutions',
        'database',
        'integral_pos_v1.db',
      );
      await Directory(path.dirname(dbPath)).create(recursive: true);
      ffi.sqfliteFfiInit();
      var sessionValid = true;
      var remoteCommitted = false;
      final requestIds = <String>[];
      final serviceId = '10000000-0000-4000-8000-000000000001';
      final receipt = <String, dynamic>{
        'request_id': '',
        'billar_id': 'A',
        'service_id': serviceId,
        'table_id': 7,
        'table_type': 'Billar',
        'sale_id': 55,
        'date': '2026-11-18T18:00:00Z',
        'payment_method': 'Efectivo',
        'total': 10.0,
        'paid': 10.0,
        'sale_type': 'Ajuste consumo tardio - Mesa 7',
        'items': [
          {
            'product_id': 1,
            'product_name': 'Agua',
            'quantity': 1.0,
            'price_at_sale': 10.0,
            'cost_at_sale': 3.0,
          },
        ],
        'movements': [
          {
            'cloud_id': 88,
            'product_id': 1,
            'quantity': -1.0,
            'unit_cost': 3.0,
            'unit_price': 10.0,
            'notes': 'Ajuste tardio servicio $serviceId',
          },
        ],
        'stock': [
          {
            'product_id': 1,
            'stock': 9.0,
            'stock_revision': 1,
            'previous_revision': 0,
          },
        ],
      };
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
      void requireSession(SyncSession value) {
        if (!sessionValid || value != session) {
          throw StateError('La sesión cambió.');
        }
      }

      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(
            request.url.path,
            '/rest/v1/rpc/staff_table_adjust_late_consumptions',
          );
          expect(request.headers['authorization'], 'Bearer token');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final requestId = body['requested_request_id'] as String;
          requestIds.add(requestId);
          receipt['request_id'] = requestId;
          remoteCommitted = true;
          if (requestIds.length == 1) {
            throw http.ClientException('Lost adjustment response');
          }
          return http.Response(
            jsonEncode(receipt),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );

      var db = await DatabaseHelper.instance.database;
      try {
        expect(await db.getVersion(), 61);
        await db.insert('products', {
          'id': 1,
          'billar_id': 'A',
          'name': 'Agua',
          'price': 10.0,
          'cost': 3.0,
          'stock': 10.0,
          'stock_revision': 0,
          'synced': 1,
          'stock_conflict': 0,
        });
        await db.insert('staff_table_service_drafts', {
          'service_id': serviceId,
          'actor_id': session.actorId,
          'billar_id': session.billarId,
          'table_id': 7,
          'table_type': 'Billar',
          'opened_at': '2026-11-18T17:00:00Z',
          'state': 'closed',
        });
        final outbox = StaffTableLateAdjustmentOutbox(db, requireSession);
        final snapshot = StaffTableLateAdjustmentSnapshot(
          serviceId: serviceId,
          tableId: 7,
          tableType: 'Billar',
          revision: 4,
          total: 10,
          items: [
            StaffTableConsumptionSnapshot(
              ordinal: 4,
              requestId: '20000000-0000-4000-8000-000000000004',
              productId: 1,
              productName: 'Agua',
              quantity: 1,
              price: 10,
              recordedAt: DateTime.utc(2026, 11, 18, 17, 10),
            ),
          ],
        );
        final prepared = await outbox.prepare(
          session: session,
          snapshot: snapshot,
          paymentMethod: 'Efectivo',
          paid: 10,
        );
        await expectLater(
          outbox.prepare(
            session: session,
            snapshot: snapshot,
            paymentMethod: 'Efectivo',
            paid: 9,
          ),
          throwsArgumentError,
        );
        final sender = StaffTableLateAdjustmentSender(client, outbox);
        await expectLater(
          sender.send(session: session, request: prepared),
          throwsA(isA<http.ClientException>()),
        );
        expect(remoteCommitted, isTrue);
        expect(
          (await outbox.pending(session)).single.requestId,
          prepared.requestId,
        );
        await db.close();
        db = await ffi.databaseFactoryFfi.openDatabase(dbPath);
        final recoveredOutbox = StaffTableLateAdjustmentOutbox(
          db,
          requireSession,
        );
        final persisted = (await recoveredOutbox.pending(session)).single;
        expect(persisted.requestId, prepared.requestId);

        final recovered = await StaffTableLateAdjustmentSender(
          client,
          recoveredOutbox,
        ).send(session: session, request: persisted);
        expect(recovered.localSaleId, greaterThan(0));
        expect(requestIds, [prepared.requestId, prepared.requestId]);
        expect(await recoveredOutbox.pending(session), isEmpty);
        expect(await db.query('sales_history'), hasLength(1));
        expect(await db.query('sale_details'), hasLength(1));
        expect(await db.query('inventory_movements'), hasLength(1));
        expect(
          (await db.query(
            'products',
            columns: ['stock', 'stock_revision'],
          )).single,
          {'stock': 9.0, 'stock_revision': 1},
        );
        expect(
          (await db.query(
            'staff_table_service_drafts',
            columns: ['state'],
          )).single['state'],
          'closed',
        );
        expect(await db.query('sales_history'), hasLength(1));
        sessionValid = false;
        await expectLater(recoveredOutbox.pending(session), throwsStateError);
      } finally {
        await client.dispose();
        await db.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
