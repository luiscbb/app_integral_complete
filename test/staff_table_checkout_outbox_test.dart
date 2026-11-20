import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_checkout_outbox.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_checkout_snapshot_repository.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_conflict_repository.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_service_outbox.dart';
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
    'uncertain table checkout reuses its durable request and receipt',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'table_checkout_',
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
      var failFinalLocalCheck = false;
      var localChecks = 0;
      var remoteCommitted = false;
      final requestIds = <String>[];
      final receiptItems = [
        {
          'product_id': 1,
          'product_name': 'Agua',
          'quantity': 1.0,
          'price_at_sale': 10.0,
          'cost_at_sale': 3.0,
        },
      ];
      final remoteReceipt = <String, dynamic>{
        'request_id': '',
        'billar_id': 'A',
        'service_id': '10000000-0000-4000-8000-000000000001',
        'table_id': 7,
        'table_type': 'Billar',
        'sale_id': 55,
        'date': '2026-11-18T18:00:00Z',
        'payment_method': 'Efectivo',
        'total': 10.0,
        'paid': 10.0,
        'sale_type': 'Mesa 7',
        'items': receiptItems,
        'movements': [
          {
            'cloud_id': 88,
            'product_id': 1,
            'quantity': -1.0,
            'unit_cost': 3.0,
            'unit_price': 10.0,
            'notes': 'Servicio de mesa',
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
        if (failFinalLocalCheck && ++localChecks == 10) {
          throw StateError('La confirmación local fue interrumpida.');
        }
      }

      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/rest/v1/rpc/staff_table_checkout');
          expect(request.headers['authorization'], 'Bearer token');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body.containsKey('expected_service_actor_id'), isFalse);
          final requestId = body['requested_request_id'] as String;
          requestIds.add(requestId);
          remoteReceipt['request_id'] = requestId;
          remoteCommitted = true;
          if (requestIds.length == 1) {
            throw http.ClientException('Lost checkout response');
          }
          return http.Response(
            jsonEncode(remoteReceipt),
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
        final outbox = StaffTableServiceOutbox(db, requireSession);
        await outbox.open(
          session: session,
          serviceId: remoteReceipt['service_id'] as String,
          tableId: 7,
          tableType: 'Billar',
          openedAt: DateTime.utc(2026, 11, 18, 17),
        );
        await db.update(
          'staff_table_service_drafts',
          {'state': 'active'},
          where: 'service_id = ?',
          whereArgs: [remoteReceipt['service_id']],
        );
        await db.insert('staff_table_service_consumptions', {
          'request_id': '20000000-0000-4000-8000-000000000001',
          'service_id': remoteReceipt['service_id'],
          'actor_id': session.actorId,
          'billar_id': session.billarId,
          'product_id': 1,
          'product_name': 'Agua',
          'quantity': 1.0,
          'price': 10.0,
          'recorded_at': '2026-11-18T17:10:00Z',
          'confirmed': 1,
          'late': 0,
        });
        final snapshot = StaffTableCheckoutSnapshot(
          serviceId: remoteReceipt['service_id'] as String,
          tableId: 7,
          tableType: 'Billar',
          actorId: 'cashier',
          openedAt: DateTime.utc(2026, 11, 18, 17),
          revision: 1,
          quotedAt: DateTime.utc(2026, 11, 18, 18),
          timeCost: 0,
          total: 10,
          items: [
            StaffTableConsumptionSnapshot(
              ordinal: 1,
              requestId: '20000000-0000-4000-8000-000000000001',
              productId: 1,
              productName: 'Agua',
              quantity: 1,
              price: 10,
              recordedAt: DateTime.utc(2026, 11, 18, 17, 10),
            ),
          ],
        );
        var checkoutOutbox = StaffTableCheckoutOutbox(db, requireSession);
        var sender = StaffTableCheckoutSender(client, checkoutOutbox);
        final prepared = await checkoutOutbox.prepare(
          session: session,
          snapshot: snapshot,
          paymentMethod: 'Efectivo',
          paid: 10,
        );
        await expectLater(
          checkoutOutbox.prepare(
            session: session,
            snapshot: snapshot,
            paymentMethod: 'Efectivo',
            paid: 9,
          ),
          throwsArgumentError,
        );
        await expectLater(
          sender.send(session: session, request: prepared),
          throwsA(isA<http.ClientException>()),
        );
        expect(remoteCommitted, isTrue);
        expect(
          (await checkoutOutbox.pending(session)).single.requestId,
          prepared.requestId,
        );
        await db.close();
        db = await ffi.databaseFactoryFfi.openDatabase(dbPath);
        checkoutOutbox = StaffTableCheckoutOutbox(db, requireSession);
        sender = StaffTableCheckoutSender(client, checkoutOutbox);
        final persisted = (await checkoutOutbox.pending(session)).single;
        expect(persisted.requestId, prepared.requestId);

        localChecks = 0;
        failFinalLocalCheck = true;
        await expectLater(
          sender.send(session: session, request: persisted),
          throwsStateError,
        );
        failFinalLocalCheck = false;
        expect(
          (await checkoutOutbox.pending(session)).single.receipt,
          isNotNull,
        );
        expect(await db.query('sales_history'), isEmpty);
        await db.insert('table_sync_conflicts', {
          'actor_id': session.actorId,
          'billar_id': session.billarId,
          'table_id': 7,
          'payload': jsonEncode({'kind': 'local_test_conflict'}),
          'created_at': '2026-11-18T18:01:00Z',
        });
        await expectLater(
          checkoutOutbox.applyReceipt(session: session, request: persisted),
          throwsStateError,
        );
        expect(await db.query('sales_history'), isEmpty);
        await db.delete(
          'table_sync_conflicts',
          where: 'actor_id = ? AND billar_id = ? AND table_id = ?',
          whereArgs: [session.actorId, session.billarId, 7],
        );

        final applied = await sender.send(session: session, request: persisted);
        expect(applied.localSaleId, greaterThan(0));
        expect(requestIds, [prepared.requestId, prepared.requestId]);
        expect(await checkoutOutbox.pending(session), isEmpty);
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
        expect(
          (await sender.send(session: session, request: applied)).localSaleId,
          applied.localSaleId,
        );
        expect(await db.query('sales_history'), hasLength(1));

        const foreignServiceId = '10000000-0000-4000-8000-000000000002';
        remoteReceipt
          ..['service_id'] = foreignServiceId
          ..['table_id'] = 8
          ..['sale_id'] = 56
          ..['sale_type'] = 'Mesa 8'
          ..['movements'] = [
            {
              'cloud_id': 89,
              'product_id': 1,
              'quantity': -1.0,
              'unit_cost': 3.0,
              'unit_price': 10.0,
              'notes': 'Servicio de mesa 8',
            },
          ]
          ..['stock'] = [
            {
              'product_id': 1,
              'stock': 8.0,
              'stock_revision': 2,
              'previous_revision': 1,
            },
          ];
        final foreignSnapshot = StaffTableCheckoutSnapshot(
          serviceId: foreignServiceId,
          tableId: 8,
          tableType: 'Billar',
          actorId: 'waiter',
          openedAt: DateTime.utc(2026, 11, 18, 17),
          revision: 1,
          quotedAt: DateTime.utc(2026, 11, 18, 18),
          timeCost: 0,
          total: 10,
          items: [
            StaffTableConsumptionSnapshot(
              ordinal: 1,
              requestId: '20000000-0000-4000-8000-000000000002',
              productId: 1,
              productName: 'Agua',
              quantity: 1,
              price: 10,
              recordedAt: DateTime.utc(2026, 11, 18, 17, 15),
            ),
          ],
        );
        final foreignRequest = await checkoutOutbox.prepare(
          session: session,
          snapshot: foreignSnapshot,
          paymentMethod: 'Efectivo',
          paid: 10,
        );
        expect(foreignRequest.serviceActorId, 'waiter');
        final foreignApplied = await sender.send(
          session: session,
          request: foreignRequest,
        );
        expect(foreignApplied.localSaleId, greaterThan(0));
        expect(requestIds, [
          prepared.requestId,
          prepared.requestId,
          foreignRequest.requestId,
        ]);
        expect(await db.query('sales_history'), hasLength(2));
        expect(await db.query('staff_table_service_drafts'), hasLength(1));
        expect(
          (await db.query('staff_table_service_drafts')).single['state'],
          'closed',
        );
        expect(
          (await db.query(
            'products',
            columns: ['stock', 'stock_revision'],
          )).single,
          {'stock': 8.0, 'stock_revision': 2},
        );
        final rejectedClient = SupabaseClient(
          'https://example.supabase.co',
          'test-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            return http.Response(
              jsonEncode({
                'code': 'PST02',
                'message': 'Los consumos cambiaron.',
                'details': null,
                'hint': null,
              }),
              400,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );
        try {
          final staleSnapshot = StaffTableCheckoutSnapshot(
            serviceId: '10000000-0000-4000-8000-000000000003',
            tableId: 9,
            tableType: 'Billar',
            actorId: 'waiter',
            openedAt: DateTime.utc(2026, 11, 18, 17),
            revision: 1,
            quotedAt: DateTime.utc(2026, 11, 18, 18),
            timeCost: 0,
            total: 10,
            items: [
              StaffTableConsumptionSnapshot(
                ordinal: 1,
                requestId: '20000000-0000-4000-8000-000000000003',
                productId: 1,
                productName: 'Agua',
                quantity: 1,
                price: 10,
                recordedAt: DateTime.utc(2026, 11, 18, 17, 20),
              ),
            ],
          );
          final staleRequest = await checkoutOutbox.prepare(
            session: session,
            snapshot: staleSnapshot,
            paymentMethod: 'Efectivo',
            paid: 10,
          );
          await expectLater(
            StaffTableCheckoutSender(
              rejectedClient,
              checkoutOutbox,
            ).send(session: session, request: staleRequest),
            throwsA(isA<PostgrestException>()),
          );
          expect(await checkoutOutbox.pending(session), isEmpty);
        } finally {
          await rejectedClient.dispose();
        }
        sessionValid = false;
        await expectLater(checkoutOutbox.pending(session), throwsStateError);
      } finally {
        await client.dispose();
        await db.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
