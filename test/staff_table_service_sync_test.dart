import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_service_outbox.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_service_sync.dart';
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
    'conflicted drafts retry lost and invalid responses without losing items',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'staff_table_sync_',
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
      final previous = await ffi.databaseFactoryFfi.openDatabase(
        dbPath,
        options: ffi.OpenDatabaseOptions(
          version: 55,
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE staff_table_service_drafts (
              service_id TEXT PRIMARY KEY, actor_id TEXT NOT NULL, billar_id TEXT NOT NULL,
              table_id INTEGER NOT NULL, table_type TEXT NOT NULL, opened_at TEXT NOT NULL,
              state TEXT NOT NULL
            )
          ''');
            await db.execute('''
            CREATE TABLE staff_table_service_consumptions (
              sequence INTEGER PRIMARY KEY AUTOINCREMENT, request_id TEXT NOT NULL UNIQUE,
              service_id TEXT NOT NULL, actor_id TEXT NOT NULL, billar_id TEXT NOT NULL,
              product_id INTEGER NOT NULL, product_name TEXT NOT NULL, quantity REAL NOT NULL,
              price REAL NOT NULL, recorded_at TEXT NOT NULL
            )
          ''');
            await db.insert('staff_table_service_consumptions', {
              'request_id': '20000000-0000-4000-8000-000000000099',
              'service_id': '10000000-0000-4000-8000-000000000099',
              'actor_id': 'old-actor',
              'billar_id': 'A',
              'product_id': 9,
              'product_name': 'Anterior',
              'quantity': 2.0,
              'price': 3.0,
              'recorded_at': '2026-01-01T00:00:00.000Z',
            });
            await db.execute(
              "CREATE TABLE existing_data (value TEXT NOT NULL)",
            );
            await db.insert('existing_data', {'value': 'preserved'});
          },
        ),
      );
      await previous.close();

      const actor = '00000000-0000-4000-8000-000000000001';
      const serviceId = '10000000-0000-4000-8000-000000000001';
      const item1 = '20000000-0000-4000-8000-000000000001';
      const item2 = '20000000-0000-4000-8000-000000000002';
      final auth =
          Session.fromJson({
            'access_token': 'token',
            'token_type': 'bearer',
            'user': {
              'id': actor,
              'aud': 'authenticated',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2025-01-01T00:00:00Z',
            },
          })!;
      final SyncSession session = (
        actorId: actor,
        billarId: 'A',
        token: 'token',
        authSession: auth,
        scopeGeneration: 1,
      );
      var sessionValid = true;
      var loseOpen = true;
      var invalidateOpen = true;
      var loseFirstItem = true;
      var alterSecondReceipt = true;
      var loseItemBeforeClose = true;
      final remote = <String, Map<String, dynamic>>{};
      final calls = <String>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer token');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final isOpen = request.url.path.endsWith('/staff_table_open');
          final key =
              body[isOpen ? 'requested_service_id' : 'requested_request_id']
                  as String;
          calls.add(key);
          final receipt = remote.putIfAbsent(
            key,
            () =>
                isOpen
                    ? {
                      'service_id': key,
                      'actor_id': actor,
                      'billar_id': body['requested_billar_id'],
                      'table_id': body['requested_table_id'],
                      'table_type': body['requested_table_type'],
                      'opened_at': body['requested_opened_at'],
                      'state':
                          body['requested_table_id'] == 8
                              ? 'active'
                              : 'conflict',
                    }
                    : {
                      'request_id': key,
                      'service_id': body['requested_service_id'],
                      'actor_id': actor,
                      'billar_id': body['requested_billar_id'],
                      'product_id': body['requested_product_id'],
                      'product_name': body['requested_product_name'],
                      'quantity': body['requested_quantity'],
                      'price': body['requested_price'],
                      'recorded_at': body['requested_recorded_at'],
                      'service_state':
                          remote[body['requested_service_id']]!['state'],
                      'late':
                          remote[body['requested_service_id']]!['state'] ==
                          'closed',
                    },
          );
          if (isOpen && loseOpen) {
            loseOpen = false;
            throw http.ClientException('Lost open response');
          }
          if (isOpen && invalidateOpen) {
            invalidateOpen = false;
            sessionValid = false;
          }
          if (key == item1 && loseFirstItem) {
            loseFirstItem = false;
            throw http.ClientException('Lost item response');
          }
          if (key == '20000000-0000-4000-8000-000000000004' &&
              loseItemBeforeClose) {
            loseItemBeforeClose = false;
            throw http.ClientException('Lost response before close');
          }
          var delivered =
              isOpen
                  ? receipt
                  : {
                    ...receipt,
                    'service_state':
                        remote[body['requested_service_id']]!['state'],
                  };
          if (key == item2 && alterSecondReceipt) {
            alterSecondReceipt = false;
            delivered = {...receipt, 'price': 999};
          }
          return http.Response(
            jsonEncode(delivered),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      void requireSession(SyncSession value) {
        if (!sessionValid || value != session) {
          throw StateError('La sesión cambió.');
        }
      }

      var db = await DatabaseHelper.instance.database;
      try {
        expect(await db.getVersion(), 61);
        expect((await db.query('existing_data')).single['value'], 'preserved');
        final migrated =
            (await db.query(
              'staff_table_service_consumptions',
              where: 'actor_id = ?',
              whereArgs: ['old-actor'],
            )).single;
        expect(migrated['product_name'], 'Anterior');
        expect(migrated['quantity'], 2.0);
        expect(migrated['confirmed'], 0);
        expect(migrated['late'], 0);
        var outbox = StaffTableServiceOutbox(db, requireSession);
        var sync = StaffTableServiceSync(client, outbox);
        final time = DateTime.utc(2026, 11, 17, 18);
        await outbox.open(
          session: session,
          serviceId: serviceId,
          tableId: 7,
          tableType: 'Billar',
          openedAt: time,
        );
        for (final (id, product) in [(item1, 1), (item2, 2)]) {
          await outbox.addConsumption(
            session: session,
            requestId: id,
            serviceId: serviceId,
            productId: product,
            productName: 'Producto $product',
            quantity: 1,
            price: 10,
            recordedAt: time,
          );
        }

        await expectLater(
          sync.synchronize(session, serviceId),
          throwsA(isA<http.ClientException>()),
        );
        expect((await outbox.drafts(session)).single.state, 'pending');
        await expectLater(
          sync.synchronize(session, serviceId),
          throwsStateError,
        );
        sessionValid = true;
        expect((await outbox.drafts(session)).single.state, 'pending');
        await expectLater(
          sync.synchronize(session, serviceId),
          throwsA(isA<http.ClientException>()),
        );
        expect((await outbox.drafts(session)).single.state, 'conflict');
        expect(
          (await outbox.consumptions(
            session,
            serviceId,
          )).every((item) => !item.confirmed),
          isTrue,
        );
        await expectLater(
          sync.synchronize(session, serviceId),
          throwsFormatException,
        );
        var items = await outbox.consumptions(session, serviceId);
        expect(items.map((item) => item.confirmed), [true, false]);

        await db.close();
        db = await ffi.databaseFactoryFfi.openDatabase(dbPath);
        outbox = StaffTableServiceOutbox(db, requireSession);
        sync = StaffTableServiceSync(client, outbox);
        sessionValid = false;
        await expectLater(
          sync.synchronize(session, serviceId),
          throwsStateError,
        );
        sessionValid = true;
        expect((await sync.synchronize(session, serviceId)).state, 'conflict');
        items = await outbox.consumptions(session, serviceId);
        expect(items.map((item) => item.confirmed), [true, true]);
        expect(items.map((item) => item.productName), [
          'Producto 1',
          'Producto 2',
        ]);
        expect(remote.length, 3);
        expect(calls.where((key) => key == serviceId).length, 3);
        expect(calls.where((key) => key == item1).length, 2);
        expect(calls.where((key) => key == item2).length, 2);
        await sync.synchronize(session, serviceId);
        expect(calls.length, 7);
        const winnerId = '10000000-0000-4000-8000-000000000002';
        const winnerItem = '20000000-0000-4000-8000-000000000003';
        await outbox.open(
          session: session,
          serviceId: winnerId,
          tableId: 8,
          tableType: 'Billar',
          openedAt: time,
        );
        await outbox.addConsumption(
          session: session,
          requestId: winnerItem,
          serviceId: winnerId,
          productId: 3,
          productName: 'Producto 3',
          quantity: 1,
          price: 10,
          recordedAt: time,
        );
        expect((await sync.synchronize(session, winnerId)).state, 'active');
        expect(
          (await outbox.consumptions(session, winnerId)).single.confirmed,
          isTrue,
        );
        for (final (id, product) in [
          ('20000000-0000-4000-8000-000000000004', 4),
          ('20000000-0000-4000-8000-000000000005', 5),
        ]) {
          await outbox.addConsumption(
            session: session,
            requestId: id,
            serviceId: winnerId,
            productId: product,
            productName: 'Producto $product',
            quantity: 1,
            price: 10,
            recordedAt: time,
          );
        }
        await expectLater(
          sync.synchronize(session, winnerId),
          throwsA(isA<http.ClientException>()),
        );
        remote[winnerId]!['state'] = 'closed';
        final afterClose = await sync.synchronize(session, winnerId);
        expect(afterClose.state, 'conflict');
        final saved = await outbox.consumptions(session, winnerId);
        expect(saved.map((item) => item.confirmed), [true, true, true]);
        expect(saved.map((item) => item.late), [false, false, true]);
        await db.close();
        db = await ffi.databaseFactoryFfi.openDatabase(dbPath);
        outbox = StaffTableServiceOutbox(db, requireSession);
        expect((await outbox.drafts(session)).last.state, 'conflict');
        expect(
          (await outbox.consumptions(session, winnerId)).last.late,
          isTrue,
        );
        const closedId = '10000000-0000-4000-8000-000000000003';
        await outbox.open(
          session: session,
          serviceId: closedId,
          tableId: 9,
          tableType: 'Billar',
          openedAt: time,
        );
        remote[closedId] = {
          'service_id': closedId,
          'actor_id': actor,
          'billar_id': 'A',
          'table_id': 9,
          'table_type': 'Billar',
          'opened_at': time.toIso8601String(),
          'state': 'closed',
        };
        sync = StaffTableServiceSync(client, outbox);
        expect((await sync.synchronize(session, closedId)).state, 'closed');
        expect(
          (await outbox.drafts(session)).any((d) => d.id == closedId),
          isFalse,
        );
        const closedWithPendingId = '10000000-0000-4000-8000-000000000004';
        await outbox.open(
          session: session,
          serviceId: closedWithPendingId,
          tableId: 10,
          tableType: 'Billar',
          openedAt: time,
        );
        await outbox.addConsumption(
          session: session,
          requestId: '20000000-0000-4000-8000-000000000006',
          serviceId: closedWithPendingId,
          productId: 6,
          productName: 'Producto 6',
          quantity: 1,
          price: 10,
          recordedAt: time,
        );
        remote[closedWithPendingId] = {
          ...remote[closedId]!,
          'service_id': closedWithPendingId,
          'table_id': 10,
        };
        expect(
          (await sync.synchronize(session, closedWithPendingId)).state,
          'conflict',
        );
        final pending = await outbox.consumptions(session, closedWithPendingId);
        expect(pending.single.confirmed, isTrue);
        expect(pending.single.late, isTrue);
      } finally {
        await client.dispose();
        await db.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
