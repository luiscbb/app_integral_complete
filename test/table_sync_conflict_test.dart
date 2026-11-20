import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/core/services/sync_service.dart';
import 'package:app_integral_complete/core/services/table_sync_conflicts.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/features/sales/data/repositories/billiard_table_repository.dart';
import 'package:app_integral_complete/features/sales/data/repositories/sales_repository.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_checkout_outbox.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_checkout_snapshot_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rejected table updates retain both snapshots and cannot be charged',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'table_conflict_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const path = MethodChannel('plugins.flutter.io/path_provider');
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity',
      );
      const connectivityEvents = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      messenger.setMockMethodCallHandler(path, (_) async => directory.path);
      messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
      messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
      SharedPreferences.setMockInitialValues({'billar_id': 'A'});
      await PreferencesService().init();

      final started = Completer<void>();
      final proceed = Completer<void>();
      final successStarted = Completer<void>();
      final releaseSuccess = Completer<void>();
      final deletedUploadStarted = Completer<void>();
      final releaseDeletedUpload = Completer<void>();
      var uploads = 0;
      var competingUploads = 0;
      var downloads = 0;
      var remoteTables = <Map<String, dynamic>>[
        {
          'id': 9,
          'billar_id': 'A',
          'name': 'Eliminada',
          'table_type': 'Billar',
          'is_occupied': 0,
          'orders': '[]',
          'is_deleted': 1,
        },
      ];
      List<List<Map<String, dynamic>>>? nextResponses;
      int? pauseDownload;
      Completer<void>? downloadStarted;
      Completer<void>? releaseDownload;
      final expires = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      const actor = '00000000-0000-0000-0000-000000000001';
      final jwtBody = base64Url
          .encode(utf8.encode(jsonEncode({'sub': actor, 'exp': expires})))
          .replaceAll('=', '');
      final client = MockClient((request) async {
        if (request.url.path == '/auth/v1/token') {
          return http.Response(
            jsonEncode({
              'access_token': 'eyJhbGciOiJub25lIn0.$jwtBody.signature',
              'token_type': 'bearer',
              'expires_in': 3600,
              'refresh_token': 'refresh',
              'user': {
                'id': actor,
                'aud': 'authenticated',
                'app_metadata': <String, dynamic>{},
                'user_metadata': <String, dynamic>{},
                'created_at': '2025-01-01T00:00:00Z',
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/rest/v1/billiard_tables' &&
            request.method == 'POST') {
          uploads++;
          if ([19, 24, 25].contains((jsonDecode(request.body) as Map)['id'])) {
            return http.Response('', 204, request: request);
          }
          if ((jsonDecode(request.body) as Map)['id'] == 16) {
            deletedUploadStarted.complete();
            await releaseDeletedUpload.future;
            return http.Response('', 204, request: request);
          }
          if ((jsonDecode(request.body) as Map)['id'] == 10) {
            competingUploads++;
            if (competingUploads == 1) {
              successStarted.complete();
              await releaseSuccess.future;
              return http.Response('', 204, request: request);
            }
            return http.Response(
              jsonEncode({'code': 'PST01', 'message': 'Mesa en conflicto'}),
              400,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          started.complete();
          await proceed.future;
          return http.Response(
            jsonEncode({'code': 'PST01', 'message': 'Mesa en conflicto'}),
            400,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (request.url.path == '/rest/v1/billiard_tables' &&
            request.method == 'GET') {
          downloads++;
          final response =
              nextResponses == null ? remoteTables : nextResponses.removeAt(0);
          if (downloads == pauseDownload) {
            downloadStarted!.complete();
            await releaseDownload!.future;
          }
          return http.Response(
            jsonEncode(response),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.url.path}',
        );
      });

      Database? db;
      try {
        await Supabase.initialize(
          url: 'http://localhost:54321',
          publishableKey: 'test-key',
          httpClient: client,
          authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
          ),
        );
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        db = await DatabaseHelper.instance.database;
        await db.insert('billiard_tables', {
          'id': 9,
          'billar_id': 'A',
          'name': 'Mesa en conflicto',
          'table_type': 'Billar',
          'is_occupied': 1,
          'orders': '[{"productId":1,"quantity":1}]',
          'synced': 0,
        });
        final table = (await db.query('billiard_tables')).single;
        final pending = SyncService().pushTableToCloud(table);
        await started.future.timeout(const Duration(seconds: 5));
        await db.update(
          'billiard_tables',
          {'orders': '[{"productId":1,"quantity":2}]', 'synced': 1},
          where: 'id = ? AND billar_id = ?',
          whereArgs: [9, 'A'],
        );
        proceed.complete();
        expect(await pending, isFalse);
        final conflict = (await db.query('table_sync_conflicts')).single;
        expect(conflict['actor_id'], actor);
        expect(conflict['billar_id'], 'A');
        expect(
          (jsonDecode(conflict['payload'] as String) as Map)['orders'],
          '[{"productId":1,"quantity":1}]',
        );
        var local = (await db.query('billiard_tables')).single;
        expect(local['orders'], '[{"productId":1,"quantity":2}]');
        expect(local['synced'], 0);
        expect(await SalesRepository().getTableSyncConflictIds(), {9});
        expect(
          await TableSyncConflicts.tableIds(db, 'otro-actor', 'A'),
          isEmpty,
        );
        final sessionGuard = SyncSessionGuard(
          Supabase.instance.client,
          PreferencesService(),
        );
        final session = sessionGuard.capture();
        final checkoutOutbox = StaffTableCheckoutOutbox(
          db,
          sessionGuard.require,
        );
        await expectLater(
          checkoutOutbox.prepare(
            session: session,
            snapshot: StaffTableCheckoutSnapshot(
              serviceId: '10000000-0000-4000-8000-000000000001',
              tableId: 9,
              tableType: 'Billar',
              actorId: actor,
              openedAt: DateTime.utc(2026, 11, 18, 17),
              revision: 0,
              quotedAt: DateTime.utc(2026, 11, 18, 18),
              timeCost: 10,
              total: 10,
              items: const [],
            ),
            paymentMethod: 'Efectivo',
            paid: 10,
          ),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          SalesRepository().saveSale(
            items: [],
            total: 10,
            paid: 10,
            paymentMethod: 'Efectivo',
            saleType: 'Billar',
            origin: SaleOrigin.billiardTables,
          ),
          throwsA(isA<SaleScopeException>()),
        );
        await expectLater(
          SalesRepository().saveSale(
            items: [],
            total: 10,
            paid: 10,
            paymentMethod: 'Efectivo',
            saleType: 'Billar',
            origin: SaleOrigin.billiardTables,
            tableId: 9,
          ),
          throwsA(isA<SaleScopeException>()),
        );
        expect(await db.query('sales_history'), isEmpty);
        await SyncService().pullTablesFromCloud(forceApply: true);
        expect(downloads, 2);
        expect(uploads, 1);
        local = (await db.query('billiard_tables')).single;
        expect(local['orders'], '[{"productId":1,"quantity":2}]');
        expect(local['is_deleted'], 0);
        await db.insert('billiard_tables', {
          'id': 10,
          'billar_id': 'A',
          'name': 'Mesa simultánea',
          'table_type': 'Billar',
          'is_occupied': 1,
          'orders': '[]',
          'synced': 0,
        });
        final competingTable =
            (await db.query(
              'billiard_tables',
              where: 'id = ?',
              whereArgs: [10],
            )).single;
        final firstUpload = SyncService().pushTableToCloud(competingTable);
        await successStarted.future.timeout(const Duration(seconds: 5));
        expect(await SyncService().pushTableToCloud(competingTable), isFalse);
        releaseSuccess.complete();
        expect(await firstUpload, isFalse);
        final afterRace =
            (await db.query(
              'billiard_tables',
              where: 'id = ?',
              whereArgs: [10],
            )).single;
        expect(afterRace['synced'], 0);

        Map<String, dynamic> tombstone(int id) => {
          'id': id,
          'billar_id': 'A',
          'name': 'Eliminada $id',
          'table_type': 'Billar',
          'is_occupied': 0,
          'orders': '[]',
          'is_deleted': 1,
        };
        await db.insert('billiard_tables', {
          'id': 12,
          'billar_id': 'A',
          'name': 'Pendiente',
          'table_type': 'Billar',
          'is_occupied': 1,
          'orders': '[{"productId":2,"quantity":3}]',
          'synced': 0,
        });
        await db.insert('billiard_tables', {
          'id': 13,
          'billar_id': 'A',
          'name': 'Sin cambios',
          'table_type': 'Billar',
          'is_occupied': 0,
          'orders': '[]',
          'synced': 1,
        });
        remoteTables = [tombstone(12), tombstone(13)];
        final uploadsBeforeDelete = uploads;
        await SyncService().pullTablesFromCloud(forceApply: true);
        expect(downloads, 4);
        expect(uploads, uploadsBeforeDelete);
        final preserved =
            (await db.query(
              'billiard_tables',
              where: 'id = ?',
              whereArgs: [12],
            )).single;
        expect(preserved['orders'], '[{"productId":2,"quantity":3}]');
        expect(preserved['is_deleted'], 0);
        expect(preserved['synced'], 0);
        final deletionConflict =
            (await db.query(
              'table_sync_conflicts',
              where: 'table_id = ?',
              whereArgs: [12],
            )).single;
        final evidence =
            jsonDecode(deletionConflict['payload'] as String) as Map;
        expect(evidence['kind'], 'remote_deleted');
        expect((evidence['local'] as Map)['orders'], preserved['orders']);
        expect((evidence['remote'] as Map)['is_deleted'], 1);
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ?',
            whereArgs: [13],
          )).single['is_deleted'],
          1,
        );
        await SyncService().pullTablesFromCloud(forceApply: true);
        expect(
          await db.query(
            'table_sync_conflicts',
            where: 'table_id = ?',
            whereArgs: [12],
          ),
          hasLength(1),
        );
        expect(uploads, uploadsBeforeDelete);
        await expectLater(
          SalesRepository().saveSale(
            items: [],
            total: 10,
            paid: 10,
            paymentMethod: 'Efectivo',
            saleType: 'Billar',
            origin: SaleOrigin.billiardTables,
            tableId: 12,
          ),
          throwsA(isA<SaleScopeException>()),
        );

        nextResponses = [
          [],
          [tombstone(15)],
        ];
        pauseDownload = downloads + 2;
        downloadStarted = Completer<void>();
        releaseDownload = Completer<void>();
        final secondDownload = SyncService().pullTablesFromCloud(
          forceApply: true,
        );
        await downloadStarted.future.timeout(const Duration(seconds: 5));
        await db.insert('billiard_tables', {
          'id': 15,
          'billar_id': 'A',
          'name': 'Pendiente en segunda descarga',
          'table_type': 'Billar',
          'is_occupied': 1,
          'orders': '[1]',
          'synced': 0,
        });
        releaseDownload.complete();
        await secondDownload;
        expect(downloads, 8);
        expect(
          await db.query(
            'table_sync_conflicts',
            where: 'table_id = ?',
            whereArgs: [15],
          ),
          hasLength(1),
        );
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ?',
            whereArgs: [15],
          )).single['orders'],
          '[1]',
        );
        nextResponses = null;
        pauseDownload = null;

        await db.insert('billiard_tables', {
          'id': 16,
          'billar_id': 'A',
          'name': 'Envío simultáneo',
          'table_type': 'Billar',
          'is_occupied': 1,
          'orders': '[2]',
          'synced': 0,
        });
        final deletedTable =
            (await db.query(
              'billiard_tables',
              where: 'id = ?',
              whereArgs: [16],
            )).single;
        final pendingDeletedUpload = SyncService().pushTableToCloud(
          deletedTable,
        );
        await deletedUploadStarted.future.timeout(const Duration(seconds: 5));
        remoteTables = [tombstone(16)];
        await SyncService().pullTablesFromCloud(forceApply: true);
        releaseDeletedUpload.complete();
        expect(await pendingDeletedUpload, isFalse);
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ?',
            whereArgs: [16],
          )).single['orders'],
          '[2]',
        );
        expect(
          await db.query(
            'table_sync_conflicts',
            where: 'table_id = ?',
            whereArgs: [16],
          ),
          hasLength(1),
        );

        await db.insert('billiard_tables', {
          'id': 17,
          'billar_id': 'A',
          'name': 'Cambio de sesión',
          'table_type': 'Billar',
          'is_occupied': 1,
          'orders': '[3]',
          'synced': 0,
        });
        nextResponses = [
          [tombstone(17)],
        ];
        pauseDownload = downloads + 1;
        downloadStarted = Completer<void>();
        releaseDownload = Completer<void>();
        final stalePull = SyncService().pullTablesFromCloud(forceApply: true);
        await downloadStarted.future.timeout(const Duration(seconds: 5));
        await PreferencesService().setBillarId('B');
        await PreferencesService().setBillarId('A');
        releaseDownload.complete();
        await stalePull;
        expect(
          await db.query(
            'table_sync_conflicts',
            where: 'table_id = ?',
            whereArgs: [17],
          ),
          isEmpty,
        );
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ?',
            whereArgs: [17],
          )).single['orders'],
          '[3]',
        );

        await db.insert('billiard_tables', {
          'id': 18,
          'billar_id': 'A',
          'name': 'Mesa ocupada',
          'table_type': 'Billar',
          'is_occupied': 1,
          'start_time': '2026-11-17T18:00:00Z',
          'orders': '[{"productId":1,"quantity":2}]',
          'synced': 0,
        });
        await db.insert('billiard_tables', {
          'id': 19,
          'billar_id': 'A',
          'name': 'Mesa libre',
          'table_type': 'Billar',
          'is_occupied': 0,
          'orders': '[]',
          'synced': 1,
        });
        await db.insert('billiard_tables', {
          'id': 19,
          'billar_id': 'B',
          'name': 'Otro billar',
          'table_type': 'Billar',
          'is_occupied': 1,
          'orders': '[1]',
          'synced': 1,
        });
        await db.insert('billiard_tables', {
          'id': 20,
          'billar_id': 'A',
          'name': 'Consumos pendientes',
          'table_type': 'Comanda',
          'is_occupied': 0,
          'orders': '[1]',
          'synced': 0,
        });
        await db.insert('billiard_tables', {
          'id': 21,
          'billar_id': 'A',
          'name': 'Consumos inválidos',
          'table_type': 'Billar',
          'is_occupied': 0,
          'orders': 'inválido',
          'synced': 0,
        });
        await db.insert('billiard_tables', {
          'id': 22,
          'billar_id': 'A',
          'name': 'Conflicto pendiente',
          'table_type': 'Billar',
          'is_occupied': 0,
          'orders': '[]',
          'synced': 0,
        });
        await TableSyncConflicts.record(db, actor, 'A', 22, {'id': 22});
        await db.insert('billiard_tables', {
          'id': 26,
          'billar_id': 'A',
          'name': 'Tiempo iniciado',
          'table_type': 'Billar',
          'is_occupied': 0,
          'start_time': '2026-11-17T18:00:00Z',
          'orders': '[]',
          'synced': 0,
        });
        await db.insert('billiard_tables', {
          'id': 27,
          'billar_id': 'A',
          'name': 'Ocupada sin consumos',
          'table_type': 'Billar',
          'is_occupied': 1,
          'orders': '[]',
          'synced': 0,
        });
        final tableRepo = BilliardTableRepository();
        for (final id in [18, 20, 21, 22, 26, 27]) {
          await expectLater(tableRepo.delete(id), throwsStateError);
        }
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ? AND billar_id = ?',
            whereArgs: [18, 'A'],
          )).single['orders'],
          '[{"productId":1,"quantity":2}]',
        );
        final beforeDeleteAll = await db.query(
          'billiard_tables',
          where: 'billar_id = ?',
          whereArgs: ['A'],
          orderBy: 'id',
        );
        await expectLater(tableRepo.deleteAll(), throwsStateError);
        expect(
          await db.query(
            'billiard_tables',
            where: 'billar_id = ?',
            whereArgs: ['A'],
            orderBy: 'id',
          ),
          beforeDeleteAll,
        );
        await tableRepo.delete(19);
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ? AND billar_id = ?',
            whereArgs: [19, 'A'],
          )).single['is_deleted'],
          1,
        );
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ? AND billar_id = ?',
            whereArgs: [19, 'B'],
          )).single['orders'],
          '[1]',
        );

        await db.insert('billiard_tables', {
          'id': 23,
          'billar_id': 'A',
          'name': 'Cambio de cuenta',
          'table_type': 'Billar',
          'is_occupied': 0,
          'orders': '[]',
          'synced': 0,
        });
        var deletingActor = actor;
        final scopedRepo = BilliardTableRepository(
          currentActorId: () => deletingActor,
        );
        final locked = Completer<void>();
        final releaseLock = Completer<void>();
        final blockingTransaction = db.transaction((_) async {
          locked.complete();
          await releaseLock.future;
        });
        await locked.future;
        final interruptedDelete = scopedRepo.delete(23);
        final rejectedDelete = expectLater(interruptedDelete, throwsStateError);
        deletingActor = 'otro-actor';
        releaseLock.complete();
        await blockingTransaction;
        await rejectedDelete;
        expect(
          (await db.query(
            'billiard_tables',
            where: 'id = ? AND billar_id = ?',
            whereArgs: [23, 'A'],
          )).single['is_deleted'],
          0,
        );

        for (final id in [24, 25]) {
          await db.insert('billiard_tables', {
            'id': id,
            'billar_id': 'C',
            'name': 'Libre $id',
            'table_type': 'Billar',
            'is_occupied': 0,
            'orders': '[]',
            'synced': 1,
          });
        }
        await PreferencesService().setBillarId('C');
        await tableRepo.deleteAll(billarId: 'C');
        final deletedTables = await db.query(
          'billiard_tables',
          where: 'billar_id = ?',
          whereArgs: ['C'],
        );
        expect(
          deletedTables.map((table) => table['is_deleted']),
          everyElement(1),
        );
        expect(deletedTables.map((table) => table['synced']), everyElement(1));
        await PreferencesService().setBillarId('A');

        await db.insert('billiard_tables', {
          'id': 11,
          'billar_id': 'A',
          'name': 'Mesa sin conflicto',
          'table_type': 'Billar',
          'is_occupied': 1,
          'orders': '[]',
          'synced': 0,
        });
        for (final origin in [SaleOrigin.billiardTables, SaleOrigin.dineIn]) {
          for (final paid in [9.0, double.nan, double.infinity]) {
            await expectLater(
              SalesRepository().saveSale(
                items: [],
                total: 10,
                paid: paid,
                paymentMethod: 'Efectivo',
                saleType: 'Mesa',
                origin: origin,
                tableId: 11,
              ),
              throwsA(isA<SaleScopeException>()),
            );
          }
        }
        expect(await db.query('sales_history'), isEmpty);
        final saleId = await SalesRepository().saveSale(
          items: [],
          total: 10,
          paid: 10,
          paymentMethod: 'Efectivo',
          saleType: 'Billar',
          origin: SaleOrigin.billiardTables,
          tableId: 11,
        );
        expect(saleId, greaterThan(0));
        expect(await db.query('sales_history'), hasLength(1));
        await PreferencesService().setBillarId('B');
        expect(await SalesRepository().getTableSyncConflictIds(), isEmpty);
      } finally {
        SyncService().dispose();
        await Supabase.instance.dispose();
        await db?.close();
        client.close();
        messenger.setMockMethodCallHandler(path, null);
        messenger.setMockMethodCallHandler(connectivity, null);
        messenger.setMockMethodCallHandler(connectivityEvents, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
