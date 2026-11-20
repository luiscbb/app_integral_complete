import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_service_outbox.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'offline table drafts retain ordered consumptions and isolate sessions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'staff_table_outbox_',
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
          version: 54,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE existing_data (value TEXT NOT NULL)',
            );
            await db.insert('existing_data', {'value': 'preserved'});
          },
        ),
      );
      await previous.close();

      var actor = 'mesero1';
      var billar = 'A';
      var generation = 1;
      SyncSession capture() {
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
        return (
          actorId: actor,
          billarId: billar,
          token: 'token',
          authSession: auth,
          scopeGeneration: generation,
        );
      }

      void requireSession(SyncSession session) {
        if (session.actorId != actor ||
            session.billarId != billar ||
            session.scopeGeneration != generation) {
          throw StateError('La sesión o el billar cambió.');
        }
      }

      final firstService = '10000000-0000-4000-8000-000000000001';
      final secondService = '10000000-0000-4000-8000-000000000002';
      final request = '20000000-0000-4000-8000-000000000001';
      final secondRequest = '20000000-0000-4000-8000-000000000002';
      final now = DateTime.utc(2026, 11, 17, 18);
      var db = await DatabaseHelper.instance.database;
      try {
        expect(await db.getVersion(), 61);
        expect((await db.query('existing_data')).single['value'], 'preserved');
        var outbox = StaffTableServiceOutbox(db, requireSession);
        final first = capture();
        Future<StaffTableServiceDraft> openFirst() => outbox.open(
          session: first,
          serviceId: firstService,
          tableId: 7,
          tableType: 'Billar',
          openedAt: now,
        );
        final opened = await openFirst();
        expect((await openFirst()).id, opened.id);
        await expectLater(
          outbox.open(
            session: first,
            serviceId: firstService,
            tableId: 8,
            tableType: 'Billar',
            openedAt: now,
          ),
          throwsStateError,
        );
        await expectLater(
          outbox.open(
            session: first,
            serviceId: secondService,
            tableId: 7,
            tableType: 'Billar',
            openedAt: now,
          ),
          throwsStateError,
        );
        Future<StaffTableConsumption> add({double quantity = 2}) =>
            outbox.addConsumption(
              session: first,
              requestId: request,
              serviceId: firstService,
              productId: 3,
              productName: 'Agua',
              quantity: quantity,
              price: 12,
              recordedAt: now,
            );
        await add();
        await add();
        await expectLater(add(quantity: 3), throwsStateError);
        await expectLater(
          outbox.addConsumption(
            session: first,
            requestId: secondRequest,
            serviceId: firstService,
            productId: 3,
            productName: 'Agua',
            quantity: double.nan,
            price: 12,
            recordedAt: now,
          ),
          throwsArgumentError,
        );
        await expectLater(
          outbox.addConsumption(
            session: first,
            requestId: secondRequest,
            serviceId: firstService,
            productId: 3,
            productName: 'x' * 256,
            quantity: 1,
            price: 12,
            recordedAt: now,
          ),
          throwsArgumentError,
        );
        await outbox.addConsumption(
          session: first,
          requestId: secondRequest,
          serviceId: firstService,
          productId: 4,
          productName: 'Refresco',
          quantity: 1,
          price: 18,
          recordedAt: now,
        );

        actor = 'mesero2';
        generation++;
        final second = capture();
        expect(await outbox.drafts(second), isEmpty);
        expect(await outbox.consumptions(second, firstService), isEmpty);
        await expectLater(
          outbox.addConsumption(
            session: second,
            requestId: '20000000-0000-4000-8000-000000000003',
            serviceId: firstService,
            productId: 3,
            productName: 'Agua',
            quantity: 1,
            price: 12,
            recordedAt: now,
          ),
          throwsStateError,
        );
        await outbox.open(
          session: second,
          serviceId: secondService,
          tableId: 7,
          tableType: 'Billar',
          openedAt: now,
        );
        await expectLater(outbox.drafts(first), throwsStateError);
        var checks = 0;
        final interrupted = StaffTableServiceOutbox(db, (session) {
          requireSession(session);
          if (++checks == 2) {
            throw StateError('Sesión cambiada durante escritura.');
          }
        });
        await expectLater(
          interrupted.addConsumption(
            session: second,
            requestId: '20000000-0000-4000-8000-000000000004',
            serviceId: secondService,
            productId: 3,
            productName: 'Agua',
            quantity: 1,
            price: 12,
            recordedAt: now,
          ),
          throwsStateError,
        );
        expect(await outbox.consumptions(second, secondService), isEmpty);

        await db.close();
        db = await ffi.databaseFactoryFfi.openDatabase(dbPath);
        outbox = StaffTableServiceOutbox(db, requireSession);
        expect((await outbox.drafts(second)).single.id, secondService);
        actor = 'mesero1';
        generation = 1;
        final restored = await outbox.consumptions(first, firstService);
        expect(restored.map((item) => item.productName), ['Agua', 'Refresco']);
        expect(restored.first.quantity, 2);
        await db.update(
          'staff_table_service_drafts',
          {'state': 'conflict'},
          where: 'service_id = ?',
          whereArgs: [firstService],
        );
        expect((await outbox.drafts(first)).single.state, 'conflict');
        await expectLater(
          outbox.addConsumption(
            session: first,
            requestId: '20000000-0000-4000-8000-000000000005',
            serviceId: firstService,
            productId: 3,
            productName: 'Agua',
            quantity: 1,
            price: 12,
            recordedAt: now,
          ),
          throwsStateError,
        );
        expect(await outbox.consumptions(first, firstService), hasLength(2));

        actor = 'mesero3';
        generation++;
        final third = capture();
        const thirdService = '10000000-0000-4000-8000-000000000003';
        await outbox.open(
          session: third,
          serviceId: thirdService,
          tableId: 8,
          tableType: 'Billar',
          openedAt: now,
        );
        final visibleItems = [
          {
            'request_id': '20000000-0000-4000-8000-000000000006',
            'productId': 5,
            'productName': 'Café',
            'quantity': 1.0,
            'price': 8.0,
            'recorded_at': now.toIso8601String(),
          },
        ];
        final adopted = await outbox.adoptVisibleActive(
          session: third,
          serviceId: thirdService,
          serviceActorId: third.actorId,
          tableId: 8,
          tableType: 'Billar',
          openedAt: now,
          items: visibleItems,
        );
        expect(adopted.state, 'active');
        expect(
          (await outbox.consumptions(third, thirdService)).single.confirmed,
          isTrue,
        );
        expect(
          (await outbox.adoptVisibleActive(
            session: third,
            serviceId: thirdService,
            serviceActorId: third.actorId,
            tableId: 8,
            tableType: 'Billar',
            openedAt: now,
            items: visibleItems,
          )).state,
          'active',
        );
        await expectLater(
          outbox.adoptVisibleActive(
            session: third,
            serviceId: '10000000-0000-4000-8000-000000000004',
            serviceActorId: 'otro-actor',
            tableId: 9,
            tableType: 'Billar',
            openedAt: now,
            items: const [],
          ),
          throwsFormatException,
        );
      } finally {
        await db.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
