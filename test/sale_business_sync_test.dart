import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/inventory_movement_sync_service.dart';
import 'package:app_integral_complete/core/services/sync_service.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/features/players/domain/entities/player_stats.dart';
import 'package:app_integral_complete/features/reports/data/repositories/reports_repository.dart';
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
    'pending sales, outflows and movements stay with their business',
    () async {
      final directory = await Directory.systemTemp.createTemp('sale_business_');
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

      final sales = <Map<String, dynamic>>[];
      final outflows = <Map<String, dynamic>>[];
      final movements = <Map<String, dynamic>>[];
      final movementTokens = <String?>[];
      var remoteMovements = <Map<String, dynamic>>[];
      Completer<void>? movementStarted;
      Completer<void>? allowMovement;
      Completer<void>? movementDownloadStarted;
      Completer<void>? allowMovementDownload;
      final players = <Map<String, dynamic>>[];
      final playerTokens = <String?>[];
      final detailTokens = <String?>[];
      final purchaseDetailTokens = <String?>[];
      final purchases = <Map<String, dynamic>>[];
      final purchaseDownloadTokens = <String?>[];
      var remotePurchases = <Map<String, dynamic>>[];
      var remoteSales = <Map<String, dynamic>>[];
      var remoteOutflows = <Map<String, dynamic>>[];
      var remoteTables = <Map<String, dynamic>>[
        {
          'id': 1, 'billar_id': 'A', 'name': 'Eliminada',
          'table_type': 'Billar', 'is_occupied': 0, 'orders': '[]', 'is_deleted': 1,
        },
      ];
      final tableUploads = <Map<String, dynamic>>[];
      final tableUploadTokens = <String?>[];
      Completer<void>? tableDownloadStarted;
      Completer<void>? allowTableDownload;
      Completer<void>? tableUploadStarted;
      Completer<void>? allowTableUpload;
      final downloadTokens = <String, String?>{};
      String? pausedDownload;
      Completer<void>? downloadStarted;
      Completer<void>? allowDownload;
      final tokens = <String, String>{};
      Completer<void>? uploadStarted;
      Completer<void>? allowUpload;
      Completer<void>? purchaseStarted;
      Completer<void>? allowPurchase;
      Completer<void>? playerStarted;
      Completer<void>? allowPlayer;
      Completer<void>? purchaseDownloadStarted;
      Completer<void>? allowPurchaseDownload;
      var loseSaleResponse = false;
      var losePurchaseResponse = false;
      var missingPaymentRpc = false;
      final saleRequests = <String, int>{};
      final purchaseRequests = <String, int>{};
      final saleAttempts = <Map<String, dynamic>>[];
      final purchaseAttempts = <Map<String, dynamic>>[];
      final expiresAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final client = MockClient((request) async {
        Object data = [];
        if (request.url.path == '/auth/v1/token') {
          final email = (jsonDecode(request.body) as Map)['email'] as String;
          final userId =
              email == 'a@example.com'
                  ? '00000000-0000-0000-0000-000000000001'
                  : '00000000-0000-0000-0000-000000000002';
          final payload = base64Url
              .encode(
                utf8.encode(
                  jsonEncode({
                    'sub': userId,
                    'exp': expiresAt,
                  }),
                ),
              )
              .replaceAll('=', '');
          final token = 'eyJhbGciOiJub25lIn0.$payload.signature';
          tokens[email] = token;
          data = {
            'access_token': token,
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'refresh-$userId',
            'user': {
              'id': userId,
              'aud': 'authenticated',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2025-01-01T00:00:00Z',
            },
          };
        } else if (request.url.path == '/rest/v1/billiard_tables' &&
            request.method == 'GET' &&
            request.url.queryParameters['billar_id'] == 'eq.A') {
          if (tableDownloadStarted != null) {
            tableDownloadStarted!.complete();
            await allowTableDownload!.future;
            tableDownloadStarted = null;
          }
          data = remoteTables;
        } else if (request.url.path == '/rest/v1/billiard_tables' &&
            request.method == 'POST') {
          tableUploads.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
          tableUploadTokens.add(request.headers['authorization']);
          if (tableUploadStarted != null) {
            tableUploadStarted!.complete();
            await allowTableUpload!.future;
            tableUploadStarted = null;
          }
        } else if (request.url.path == '/rest/v1/rpc/sync_owner_sale' &&
            request.method == 'POST') {
          final args = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
          final requestId = args['p_request_id'] as String;
          saleAttempts.add(args);
          final details = args['p_details'] as List;
          if (details.isNotEmpty) detailTokens.add(request.headers['authorization']);
          final id = saleRequests.putIfAbsent(requestId, () {
            final id = (args['p_cloud_id'] as int?) ?? sales.length + 1;
            if (args['p_cloud_id'] == null) {
              sales.add({...Map<String, dynamic>.from(args['p_sale'] as Map), 'billar_id': args['p_billar_id']});
            }
            return id;
          });
          if (uploadStarted != null) {
            uploadStarted!.complete();
            await allowUpload!.future;
            uploadStarted = null;
          }
          if (loseSaleResponse) {
            loseSaleResponse = false;
            throw http.ClientException('Respuesta perdida');
          }
          data = id;
        } else if ((request.url.path == '/rest/v1/sales_history' ||
                request.url.path == '/rest/v1/cash_outflows') &&
            request.method == 'GET') {
          downloadTokens[request.url.path] = request.headers['authorization'];
          if (pausedDownload == request.url.path) {
            downloadStarted!.complete();
            await allowDownload!.future;
            pausedDownload = null;
          }
          data = request.url.path.endsWith('sales_history') ? remoteSales : remoteOutflows;
        } else if ((request.url.path == '/rest/v1/rpc/sync_owner_purchase' ||
                request.url.path == '/rest/v1/rpc/sync_owner_purchase_with_payment') &&
            request.method == 'POST') {
          final args = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
          expect(request.url.path.endsWith('_with_payment'),
              (args['p_purchase'] as Map).containsKey('payment_condition'));
          final requestId = args['p_request_id'] as String;
          purchaseAttempts.add(args);
          if (missingPaymentRpc && request.url.path.endsWith('_with_payment')) {
            return http.Response(
              jsonEncode({'code': 'PGRST202', 'message': 'Function not found'}),
              404, headers: {'content-type': 'application/json'}, request: request,
            );
          }
          final details = args['p_details'] as List;
          if (details.isNotEmpty) purchaseDetailTokens.add(request.headers['authorization']);
          final id = purchaseRequests.putIfAbsent(requestId, () {
            final id = (args['p_cloud_id'] as int?) ?? purchases.length + 42;
            if (args['p_cloud_id'] == null) {
              purchases.add({...Map<String, dynamic>.from(args['p_purchase'] as Map), 'billar_id': args['p_billar_id']});
            }
            return id;
          });
          if (purchaseStarted != null) {
            purchaseStarted!.complete();
            await allowPurchase!.future;
            purchaseStarted = null;
          }
          if (losePurchaseResponse) {
            losePurchaseResponse = false;
            throw http.ClientException('Respuesta perdida');
          }
          data = id;
        } else if (request.url.path == '/rest/v1/purchases' &&
            request.method == 'GET') {
          purchaseDownloadTokens.add(request.headers['authorization']);
          if (purchaseDownloadStarted != null) {
            purchaseDownloadStarted!.complete();
            await allowPurchaseDownload!.future;
            purchaseDownloadStarted = null;
          }
          data = remotePurchases;
        } else if (request.url.path == '/rest/v1/cash_outflows' &&
            request.method == 'POST') {
          outflows.add(
            Map<String, dynamic>.from(jsonDecode(request.body) as Map),
          );
          data = [
            {'id': outflows.length},
          ];
        } else if (request.url.path == '/rest/v1/inventory_movements' &&
            request.method == 'POST') {
          movements.add(
            Map<String, dynamic>.from(jsonDecode(request.body) as Map),
          );
          movementTokens.add(request.headers['authorization']);
          if (movementStarted != null) {
            movementStarted!.complete();
            await allowMovement!.future;
            movementStarted = null;
          }
          data = {'id': movements.length};
        } else if (request.url.path == '/rest/v1/inventory_movements' &&
            request.method == 'GET') {
          movementTokens.add(request.headers['authorization']);
          if (movementDownloadStarted != null) {
            movementDownloadStarted!.complete();
            await allowMovementDownload!.future;
            movementDownloadStarted = null;
          }
          data = remoteMovements;
        } else if (request.url.path == '/rest/v1/players' &&
            request.method == 'POST') {
          players.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
          playerTokens.add(request.headers['authorization']);
          if (playerStarted != null) {
            playerStarted!.complete();
            await allowPlayer!.future;
            playerStarted = null;
          }
          data = {'id': players.length};
        } else if (request.method != 'GET') {
          throw StateError(
            'Unexpected request: ${request.method} ${request.url.path}',
          );
        }
        return http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
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
        final purchaseIds = <String, int>{};
        for (final business in ['A', 'B']) {
          purchaseIds[business] = await db.insert('purchases', {
            'billar_id': business,
            'total': 10.0,
            'date': '2026-01-01',
            'reference': business,
            'synced': 0,
          });
        }
        final legacyPurchaseId = await db.insert('purchases', {
          'total': 15.0,
          'date': '2026-01-01',
          'reference': 'SIN BILLAR',
          'synced': 0,
        });
        await expectLater(SyncService().markPurchasePending(purchaseIds['B']!), throwsStateError);
        await expectLater(SyncService().markPurchasePending(legacyPurchaseId), throwsStateError);
        expect(
          await SyncService().pushPurchaseToCloud(
            localPurchaseId: purchaseIds['B']!,
            billarId: 'A',
            accessToken: tokens['a@example.com']!,
          ),
          isNull,
        );
        expect(purchases, isEmpty);
        for (final id in [1, 2]) {
          await db.insert('billiard_tables', {
            'id': id,
            'billar_id': 'A',
            'name': 'Mesa $id',
            'table_type': 'Billar',
            'synced': 1,
            'is_deleted': 0,
          });
        }
        for (final business in ['A', 'B']) {
          await db.insert('sales_history', {
            'billar_id': business,
            'total': 10.0,
            'paid': 10.0,
            'date': '2026-01-01',
            'type': 'Venta Rápida',
            'payment_method': 'Efectivo',
            'synced': 0,
          });
          await db.insert('cash_outflows', {
            'billar_id': business,
            'outflow_type': 'gasto',
            'amount': 5.0,
            'created_at': '2026-01-01',
            'synced': 0,
          });
          await db.insert('inventory_movements', {
            'billar_id': business,
            'product_id': 1,
            'movement_type': 'sale',
            'quantity': -1,
            'created_at': '2026-01-01',
            'synced': 0,
          });
          await db.insert('players', {
            'billar_id': business,
            'name': 'Jugador $business',
            'client_id': 'player-$business',
            'synced': 0,
          });
        }

        final otherSale = (await db.query(
          'sales_history',
          columns: ['id'],
          where: 'billar_id = ?',
          whereArgs: ['B'],
        )).single;
        expect(
          await SyncService().pushSaleToCloud(
            localSaleId: otherSale['id'] as int,
            billarId: 'A',
            accessToken: tokens['a@example.com']!,
          ),
          isNull,
        );
        expect(sales, isEmpty);

        await SyncService().syncAllPending();
        final tables = await db.query(
          'billiard_tables',
          where: 'billar_id = ?',
          whereArgs: ['A'],
          orderBy: 'id',
        );
        expect(tables.map((row) => row['id']), [1, 2]);
        expect(tables.map((row) => row['is_deleted']), [1, 0]);
        expect(PreferencesService().tableCount, 1);
        for (final records in [sales, outflows, movements, players]) {
          expect(records.map((record) => record['billar_id']), ['A']);
        }
        expect(purchases.map((row) => row['billar_id']), ['A']);
        expect((await db.query('purchases', where: 'id = ?', whereArgs: [purchaseIds['B']])).single['synced'], 0);
        expect(
          await SyncService().pushPlayerToCloud(
            const PlayerEntity(name: 'Otro billar', billarId: 'B'),
          ),
          isNull,
        );
        expect(players, hasLength(1));
        for (final table in [
          'sales_history',
          'cash_outflows',
          'inventory_movements',
          'players',
        ]) {
          final pending = await db.query(
            table,
            where: 'billar_id = ?',
            whereArgs: ['B'],
          );
          expect(pending.single['synced'], 0);
        }

        await PreferencesService().setBillarId('B');
        await SyncService().syncAllPending();
        for (final records in [sales, outflows, movements, players]) {
          expect(records.map((record) => record['billar_id']), ['A', 'B']);
        }
        expect(purchases.map((row) => row['billar_id']), ['A', 'B']);
        expect((await db.query('purchases', where: 'id = ?', whereArgs: [purchaseIds['B']])).single['synced'], 1);
        final legacyPurchase = (await db.query(
          'purchases',
          where: 'id = ?',
          whereArgs: [legacyPurchaseId],
        )).single;
        expect(legacyPurchase['billar_id'], isNull);
        expect(legacyPurchase['synced'], 0);
        for (final table in [
          'sales_history',
          'cash_outflows',
          'inventory_movements',
          'players',
        ]) {
          final synced = await db.query(
            table,
            where: 'billar_id = ?',
            whereArgs: ['B'],
          );
          expect(synced.single['synced'], 1);
        }

        await PreferencesService().setBillarId('A');
        final saleId = await db.insert('sales_history', {
          'billar_id': 'A',
          'total': 10.0,
          'paid': 10.0,
          'date': '2026-01-02',
          'type': 'Venta Rápida',
          'payment_method': 'Efectivo',
          'synced': 0,
        });
        await db.insert('sale_details', {
          'sale_id': saleId,
          'product_name': 'Producto',
          'quantity': 1,
          'price_at_sale': 10,
        });
        await db.insert('cash_outflows', {
          'billar_id': 'A',
          'outflow_type': 'gasto',
          'amount': 5.0,
          'created_at': '2026-01-02',
          'synced': 0,
        });
        uploadStarted = Completer<void>();
        allowUpload = Completer<void>();
        final syncing = SyncService().syncAllPending();
        await uploadStarted!.future;
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com',
          password: 'test',
        );
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        allowUpload.complete();
        await syncing;
        expect(detailTokens, ['Bearer ${tokens['a@example.com']}']);
        expect(outflows, hasLength(2));
        expect(
          (await db.query('sales_history', where: 'id = ?', whereArgs: [saleId]))
              .single['synced'],
          0,
        );
        final pending = await db.query(
          'cash_outflows',
          where: 'billar_id = ? AND synced = 0',
          whereArgs: ['A'],
        );
        expect(pending, hasLength(1));

        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        final purchaseId = await db.insert('purchases', {
          'billar_id': 'A',
          'total': 10.0,
          'date': '2026-01-03',
          'reference': 'COMPRA',
          'synced': 0,
        });
        await db.insert('purchase_details', {
          'purchase_id': purchaseId,
          'product_id': 1,
          'quantity': 1,
          'cost_per_unit': 10.0,
        });
        purchaseStarted = Completer<void>();
        allowPurchase = Completer<void>();
        final purchaseSync = SyncService().syncAllPending();
        await purchaseStarted!.future;
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com',
          password: 'test',
        );
        allowPurchase.complete();
        await purchaseSync;
        expect(purchaseDetailTokens, ['Bearer ${tokens['a@example.com']}']);
        expect(outflows, hasLength(2));
        expect(
          (await db.query('purchases', where: 'id = ?', whereArgs: [purchaseId]))
              .single['synced'],
          0,
        );

        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        final playerId = await db.insert('players', {
          'billar_id': 'A',
          'name': 'Jugador pendiente',
          'client_id': 'player-pending',
          'synced': 0,
        });
        playerStarted = Completer<void>();
        allowPlayer = Completer<void>();
        final playerSync = SyncService().syncAllPending();
        await playerStarted!.future.timeout(const Duration(seconds: 5));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com',
          password: 'test',
        );
        allowPlayer.complete();
        await playerSync;
        expect(playerTokens.last, 'Bearer ${tokens['a@example.com']}');
        expect(
          (await db.query('players', where: 'id = ?', whereArgs: [playerId]))
              .single['synced'],
          0,
        );

        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        remotePurchases = [
          {
            'id': 100, 'billar_id': 'A', 'total': 10, 'date': '2026-01-03',
            'purchase_details': [
              {'product_id': 1, 'quantity': 1, 'cost_per_unit': 10},
            ],
          },
        ];
        purchaseDownloadStarted = Completer<void>();
        allowPurchaseDownload = Completer<void>();
        final download = SyncService().pullPurchasesFromCloud();
        await purchaseDownloadStarted!.future.timeout(const Duration(seconds: 5));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com',
          password: 'test',
        );
        allowPurchaseDownload.complete();
        await download;
        expect(purchaseDownloadTokens.last, 'Bearer ${tokens['a@example.com']}');
        expect(await db.query('purchases', where: 'cloud_id = ?', whereArgs: ['100']), isEmpty);

        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        remotePurchases.add({'id': 101, 'billar_id': 'B', 'total': 3, 'date': '2026-01-03'});
        await SyncService().pullPurchasesFromCloud();
        expect(await db.query('purchases', where: 'cloud_id = ?', whereArgs: ['100']), isEmpty);
        remotePurchases.removeLast();
        final unassignedId = await db.insert('purchases', {
          'total': 10,
          'date': '2026-01-03',
          'reference': 'ANTIGUA',
          'cloud_id': '100',
          'synced': 0,
        });
        remotePurchases.first['cancelled'] = true;
        await SyncService().pullPurchasesFromCloud();
        var existing = (await db.query('purchases', where: 'id = ?', whereArgs: [unassignedId])).single;
        expect(existing['cancelled'], 0);
        expect(existing['billar_id'], isNull);
        expect(existing['synced'], 0);
        await db.delete('purchases', where: 'id = ?', whereArgs: [unassignedId]);
        final otherBusinessId = await db.insert('purchases', {
          'billar_id': 'B',
          'total': 10,
          'date': '2026-01-03',
          'reference': 'OTRO',
          'cloud_id': '100',
          'synced': 0,
        });
        await SyncService().pullPurchasesFromCloud();
        existing = (await db.query('purchases', where: 'id = ?', whereArgs: [otherBusinessId])).single;
        expect(existing['cancelled'], 0);
        expect(existing['synced'], 0);
        await db.delete('purchases', where: 'id = ?', whereArgs: [otherBusinessId]);
        remotePurchases.first.remove('cancelled');
        await Future.wait([
          SyncService().pullPurchasesFromCloud(),
          SyncService().pullPurchasesFromCloud(),
        ]);
        final downloaded = await db.query('purchases', where: 'cloud_id = ?', whereArgs: ['100']);
        expect(downloaded.single['billar_id'], 'A');
        expect(downloaded, hasLength(1));
        expect(await db.query('purchase_details', where: 'purchase_id = ?', whereArgs: [downloaded.single['id']]), hasLength(1));
        remotePurchases.first['cancelled'] = true;
        await SyncService().pullPurchasesFromCloud();
        expect((await db.query('purchases', where: 'cloud_id = ?', whereArgs: ['100'])).single['cancelled'], 1);
        expect((await db.query('purchase_details', where: 'purchase_id = ?', whereArgs: [downloaded.single['id']])).single['cancelled'], 1);

        final reports = ReportsRepository();
        final reportDate = DateTime(2026, 1, 3);
        final cashBeforeCredit = await reports.getCashFlowSummary(reportDate, reportDate);
        remotePurchases.add({
          'id': 102, 'billar_id': 'A', 'provider_id': 1, 'total': 250,
          'date': '2026-01-03T12:00:00Z', 'cash_source': null,
          'payment_condition': 'credito', 'payment_method': null,
          'credit_days': 30, 'due_date': '2026-02-02', 'paid_amount': 0, 'balance_due': 250,
          'purchase_details': [{'product_id': 1, 'quantity': 1, 'cost_per_unit': 250}],
        });
        await SyncService().pullPurchasesFromCloud();
        final creditPurchase = (await db.query('purchases', where: 'cloud_id = ?', whereArgs: ['102'])).single;
        expect(creditPurchase['payment_condition'], 'credito');
        expect(creditPurchase['cash_source'], isNull);
        expect(creditPurchase['credit_days'], 30);
        expect(creditPurchase['due_date'], '2026-02-02');
        expect(creditPurchase['paid_amount'], 0);
        expect(creditPurchase['balance_due'], 250);
        expect(await reports.getCashFlowSummary(reportDate, reportDate), cashBeforeCredit);
        remotePurchases.removeLast();

        remoteSales = [{
          'id': 200, 'billar_id': 'A', 'total': 10, 'paid': 10,
          'date': '2026-01-03', 'type': 'Venta Rápida',
          'sale_details': [{'product_name': 'Producto', 'quantity': 1, 'price_at_sale': 10}],
        }];
        remoteOutflows = [{
          'id': 300, 'billar_id': 'A', 'outflow_type': 'gasto',
          'amount': 5, 'created_at': '2026-01-03',
        }];
        for (final entry in [
          ('/rest/v1/sales_history', 'sales_history', '200', SyncService().pullSalesFromCloud),
          ('/rest/v1/cash_outflows', 'cash_outflows', '300', SyncService().pullOutflowsFromCloud),
        ]) {
          pausedDownload = entry.$1;
          downloadStarted = Completer<void>();
          allowDownload = Completer<void>();
          final pendingDownload = entry.$4();
          await downloadStarted.future.timeout(const Duration(seconds: 5));
          await PreferencesService().setBillarId('B');
          await PreferencesService().setBillarId('A');
          allowDownload.complete();
          await pendingDownload;
          expect(downloadTokens[entry.$1], 'Bearer ${tokens['a@example.com']}');
          expect(await db.query(entry.$2, where: 'cloud_id = ?', whereArgs: [entry.$3]), isEmpty);
        }
        remoteSales.add({'id': 201, 'billar_id': 'B'});
        remoteOutflows.add({'id': 301, 'billar_id': 'B'});
        await SyncService().pullSalesFromCloud();
        await SyncService().pullOutflowsFromCloud();
        expect(await db.query('sales_history', where: 'cloud_id = ?', whereArgs: ['200']), isEmpty);
        expect(await db.query('cash_outflows', where: 'cloud_id = ?', whereArgs: ['300']), isEmpty);
        remoteSales.removeLast();
        remoteOutflows.removeLast();
        await Future.wait([
          SyncService().pullSalesFromCloud(), SyncService().pullSalesFromCloud(),
          SyncService().pullOutflowsFromCloud(), SyncService().pullOutflowsFromCloud(),
        ]);
        final downloadedSales = await db.query('sales_history', where: 'cloud_id = ?', whereArgs: ['200']);
        expect(downloadedSales, hasLength(1));
        expect(await db.query('cash_outflows', where: 'cloud_id = ?', whereArgs: ['300']), hasLength(1));
        remoteSales.first['cancelled'] = true;
        await SyncService().pullSalesFromCloud();
        expect((await db.query('sales_history', where: 'cloud_id = ?', whereArgs: ['200'])).single['cancelled'], 1);
        expect((await db.query('sale_details', where: 'sale_id = ?', whereArgs: [downloadedSales.single['id']])).single['cancelled'], 1);

        const tableId = 3;
        await db.insert('billiard_tables', {
          'id': tableId, 'billar_id': 'A', 'name': 'Pendiente',
          'table_type': 'Billar', 'synced': 0, 'is_deleted': 0,
        });
        tableDownloadStarted = Completer<void>();
        allowTableDownload = Completer<void>();
        final tablePull = SyncService().pullTablesFromCloud();
        await tableDownloadStarted!.future.timeout(const Duration(seconds: 5));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com', password: 'test',
        );
        allowTableDownload.complete();
        await tablePull;
        expect(tableUploads, isEmpty);
        final table = (await db.query('billiard_tables', where: 'id = ?', whereArgs: [tableId])).single;
        expect(table['synced'], 0);
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com', password: 'test',
        );
        tableUploadStarted = Completer<void>();
        allowTableUpload = Completer<void>();
        final tablePush = SyncService().pushTableToCloud(table);
        await tableUploadStarted!.future.timeout(const Duration(seconds: 5));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com', password: 'test',
        );
        allowTableUpload.complete();
        expect(await tablePush, isFalse);
        expect(tableUploadTokens, ['Bearer ${tokens['a@example.com']}']);
        expect((await db.query('billiard_tables', where: 'id = ?', whereArgs: [tableId])).single['synced'], 0);
        await PreferencesService().setBillarId('B');
        expect(await SyncService().pushTableToCloud(table), isFalse);
        expect(tableUploads, hasLength(1));
        await PreferencesService().setBillarId('A');
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com', password: 'test',
        );
        expect(await SyncService().pushTableToCloud(table), isTrue);
        expect((await db.query('billiard_tables', where: 'id = ?', whereArgs: [tableId])).single['synced'], 1);
        await db.update('billiard_tables', {'name': 'Edición 1', 'synced': 0},
            where: 'id = ?', whereArgs: [tableId]);
        final edited = (await db.query('billiard_tables', where: 'id = ?', whereArgs: [tableId])).single;
        tableUploadStarted = Completer<void>();
        allowTableUpload = Completer<void>();
        final editedPush = SyncService().pushTableToCloud(edited);
        await tableUploadStarted!.future.timeout(const Duration(seconds: 5));
        await db.update('billiard_tables', {'name': 'Edición 2', 'synced': 0},
            where: 'id = ?', whereArgs: [tableId]);
        allowTableUpload.complete();
        expect(await editedPush, isTrue);
        final changed = (await db.query('billiard_tables', where: 'id = ?', whereArgs: [tableId])).single;
        expect(changed['name'], 'Edición 2');
        expect(changed['synced'], 0);

        final uploadCount = tableUploads.length;
        remoteTables = [{'id': 3, 'billar_id': 'B', 'is_deleted': 1}];
        await SyncService().pullTablesFromCloud();
        expect(tableUploads, hasLength(uploadCount));
        expect((await db.query('billiard_tables', where: 'id = ?', whereArgs: [tableId])).single['is_deleted'], 0);

        await db.insert('billiard_tables', {
          'id': 4, 'billar_id': 'B', 'name': 'Mesa B',
          'is_occupied': 1, 'orders': '[{"productId":99,"quantity":1}]',
          'synced': 0,
        });
        remoteTables = [{
          'id': 4, 'billar_id': 'A', 'name': 'Mesa A',
          'table_type': 'Billar', 'is_occupied': 1, 'orders': '[]', 'is_deleted': 0,
        }];
        await SyncService().pullTablesFromCloud();
        final sameNumber = await db.query('billiard_tables', where: 'id = ?', whereArgs: [4]);
        expect(sameNumber, hasLength(2));
        expect(sameNumber.singleWhere((row) => row['billar_id'] == 'A')['name'], 'Mesa A');
        expect(
          sameNumber.singleWhere((row) => row['billar_id'] == 'B')['orders'],
          '[{"productId":99,"quantity":1}]',
        );

        final movementId = await db.insert('inventory_movements', {
          'billar_id': 'A', 'product_id': 1, 'movement_type': 'adjustment',
          'quantity': 1, 'created_at': '2026-01-03T12:00:00', 'synced': 0,
        });
        final movementCount = movements.length;
        movementStarted = Completer<void>();
        allowMovement = Completer<void>();
        final movementSync = InventoryMovementSyncService.instance.sync();
        await movementStarted!.future.timeout(const Duration(seconds: 5));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com', password: 'test',
        );
        allowMovement.complete();
        await movementSync;
        expect(movementTokens.last, 'Bearer ${tokens['a@example.com']}');
        final pendingMovement = (await db.query('inventory_movements', where: 'id = ?', whereArgs: [movementId])).single;
        expect(pendingMovement['synced'], 0);
        final requestId = pendingMovement['client_id'];
        expect(requestId, isNotNull);
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com', password: 'test',
        );
        await InventoryMovementSyncService.instance.sync();
        expect(movements.skip(movementCount).map((m) => m['client_id']), [requestId, requestId]);
        expect((await db.query('inventory_movements', where: 'id = ?', whereArgs: [movementId])).single['synced'], 1);

        remoteMovements = [{
          'id': 1000, 'billar_id': 'A', 'product_id': 1, 'movement_type': 'sale',
          'quantity': -1, 'unit_cost': 0, 'unit_price': 1,
          'created_at': '2026-01-03T12:00:00',
        }];
        movementDownloadStarted = Completer<void>();
        allowMovementDownload = Completer<void>();
        final movementPull = InventoryMovementSyncService.instance.sync();
        await movementDownloadStarted!.future.timeout(const Duration(seconds: 5));
        await PreferencesService().setBillarId('B');
        allowMovementDownload.complete();
        await movementPull;
        expect(await db.query('inventory_movements', where: 'cloud_id = ?', whereArgs: ['1000']), isEmpty);
        await PreferencesService().setBillarId('A');
        remoteMovements.add({'id': 1001, 'billar_id': 'B'});
        await InventoryMovementSyncService.instance.sync();
        expect(await db.query('inventory_movements', where: 'cloud_id = ?', whereArgs: ['1000']), isEmpty);
        remoteMovements.removeLast();
        await InventoryMovementSyncService.instance.sync();
        expect((await db.query('inventory_movements', where: 'cloud_id = ?', whereArgs: ['1000'])).single['billar_id'], 'A');

        final retrySaleId = await db.insert('sales_history', {
          'billar_id': 'A',
          'total': 10.0,
          'paid': 10.0,
          'date': '2026-01-04',
          'type': 'Venta Rápida',
          'payment_method': 'Efectivo',
          'synced': 0,
        });
        final saleCount = sales.length;
        await db.insert('sale_details', {
          'sale_id': retrySaleId, 'product_name': 'Producto',
          'quantity': 1, 'price_at_sale': 10,
        });
        loseSaleResponse = true;
        Future<String?> pushRetrySale() =>
            SyncService().pushSaleToCloud(
              localSaleId: retrySaleId,
              billarId: 'A',
              accessToken: tokens['a@example.com']!,
            );
        expect(await pushRetrySale(), isNull);
        final pendingSale = (await db.query(
          'sales_history',
          where: 'id = ?',
          whereArgs: [retrySaleId],
        )).single;
        expect(pendingSale['synced'], 0);
        expect(pendingSale['cloud_id'], isNull);
        final saleRequest = saleAttempts.last;
        remoteSales = [{
          ...Map<String, dynamic>.from(saleRequest['p_sale'] as Map),
          'id': saleRequests[saleRequest['p_request_id']],
          'billar_id': 'A',
          'sync_client_id': saleRequest['p_request_id'],
          'sale_details': saleRequest['p_details'],
        }];
        await SyncService().pullSalesFromCloud();
        expect(
          await db.query('sales_history', where: 'cloud_id = ?', whereArgs: [
            saleRequests[saleRequest['p_request_id']].toString(),
          ]),
          isEmpty,
        );
        remoteSales = [];
        final saleAttemptCount = saleAttempts.length;
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com', password: 'test',
        );
        expect(
          await SyncService().pushSaleToCloud(
            localSaleId: retrySaleId,
            billarId: 'A',
            accessToken: tokens['b@example.com']!,
          ),
          isNull,
        );
        expect(saleAttempts, hasLength(saleAttemptCount));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com', password: 'test',
        );
        await db.update(
          'sales_history', {'cancelled': 1},
          where: 'id = ?', whereArgs: [retrySaleId],
        );
        expect(await pushRetrySale(), isNotNull);
        expect(saleAttempts.last['p_request_id'], saleRequest['p_request_id']);
        final retrySaleCloudId = (await db.query(
          'sales_history', where: 'id = ?', whereArgs: [retrySaleId],
        )).single['cloud_id'] as String;
        expect((await db.query(
          'sales_history', where: 'id = ?', whereArgs: [retrySaleId],
        )).single['synced'], 0);
        expect(await pushRetrySale(), retrySaleCloudId);
        expect(saleAttempts.last['p_request_id'], isNot(saleRequest['p_request_id']));
        expect(saleAttempts.last['p_cloud_id'].toString(), retrySaleCloudId);
        expect((saleAttempts.last['p_sale'] as Map)['cancelled'], true);
        expect(sales.length, saleCount + 1);
        await SyncService().markSalePending(retrySaleId);
        final markedSale = (await db.query(
          'sales_history',
          where: 'id = ?',
          whereArgs: [retrySaleId],
        )).single;
        expect(markedSale['synced'], 0);
        expect(markedSale['cloud_id'], retrySaleCloudId);

        final retryPurchaseId = await db.insert('purchases', {
          'billar_id': 'A',
          'provider_id': 1,
          'total': 10.0,
          'date': '2026-01-04T12:00:00Z',
          'cash_source': null,
          'payment_condition': 'credito', 'payment_method': null,
          'credit_days': 30, 'due_date': '2026-02-03',
          'paid_amount': 0, 'balance_due': 10,
          'synced': 0,
        });
        final purchaseCount = purchases.length;
        await db.insert('purchase_details', {
          'purchase_id': retryPurchaseId, 'product_id': 1,
          'quantity': 1, 'cost_per_unit': 10,
        });
        missingPaymentRpc = true;
        Future<String?> pushRetryPurchase() =>
            SyncService().pushPurchaseToCloud(
              localPurchaseId: retryPurchaseId,
              billarId: 'A',
              accessToken: tokens['a@example.com']!,
            );
        expect(await pushRetryPurchase(), isNull);
        expect(purchases.length, purchaseCount);
        final unsupportedRequest = purchaseAttempts.last;
        missingPaymentRpc = false;
        losePurchaseResponse = true;
        expect(await pushRetryPurchase(), isNull);
        expect(purchaseAttempts.last, unsupportedRequest);
        final pendingPurchase = (await db.query(
          'purchases',
          where: 'id = ?',
          whereArgs: [retryPurchaseId],
        )).single;
        expect(pendingPurchase['synced'], 0);
        expect(pendingPurchase['cloud_id'], isNull);
        final purchaseRequest = purchaseAttempts.last;
        final paymentHeader = purchaseRequest['p_purchase'] as Map;
        expect(paymentHeader['cash_source'], isNull);
        expect(paymentHeader['payment_condition'], 'credito');
        expect(paymentHeader['credit_days'], 30);
        expect(paymentHeader['paid_amount'], 0);
        expect(paymentHeader['balance_due'], 10);
        expect(paymentHeader['due_date'], '2026-02-03');
        remotePurchases = [{
          ...Map<String, dynamic>.from(purchaseRequest['p_purchase'] as Map),
          'id': purchaseRequests[purchaseRequest['p_request_id']],
          'billar_id': 'A',
          'sync_client_id': purchaseRequest['p_request_id'],
          'purchase_details': purchaseRequest['p_details'],
        }];
        await SyncService().pullPurchasesFromCloud();
        expect(
          await db.query('purchases', where: 'cloud_id = ?', whereArgs: [
            purchaseRequests[purchaseRequest['p_request_id']].toString(),
          ]),
          isEmpty,
        );
        remotePurchases = [];
        await db.update(
          'purchases', {'reference': 'ACTUALIZADA'},
          where: 'id = ?', whereArgs: [retryPurchaseId],
        );
        expect(await pushRetryPurchase(), isNotNull);
        expect(purchaseAttempts.last['p_request_id'], purchaseRequest['p_request_id']);
        final retryPurchaseCloudId = (await db.query(
          'purchases', where: 'id = ?', whereArgs: [retryPurchaseId],
        )).single['cloud_id'] as String;
        expect((await db.query(
          'purchases', where: 'id = ?', whereArgs: [retryPurchaseId],
        )).single['synced'], 0);
        expect(await pushRetryPurchase(), retryPurchaseCloudId);
        expect(purchaseAttempts.last['p_request_id'], isNot(purchaseRequest['p_request_id']));
        expect(purchaseAttempts.last['p_cloud_id'].toString(), retryPurchaseCloudId);
        expect((purchaseAttempts.last['p_purchase'] as Map)['reference'], 'ACTUALIZADA');
        expect(purchases.length, purchaseCount + 1);
        await SyncService().markPurchasePending(retryPurchaseId);
        final markedPurchase = (await db.query(
          'purchases',
          where: 'id = ?',
          whereArgs: [retryPurchaseId],
        )).single;
        expect(markedPurchase['synced'], 0);
        expect(markedPurchase['cloud_id'], retryPurchaseCloudId);
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
