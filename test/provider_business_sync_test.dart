import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_service.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/features/purchases/data/repositories/purchases_repository.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/provider_entity.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/purchase_entity.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/purchase_payment_terms.dart';
import 'package:app_integral_complete/features/reports/data/repositories/reports_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'provider sync preserves business boundaries and partial local data',
    () async {
      final directory = await Directory.systemTemp.createTemp('provider_sync_');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const path = MethodChannel('plugins.flutter.io/path_provider');
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity',
      );
      const connectivityEvents = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      var online = true;
      messenger.setMockMethodCallHandler(path, (_) async => directory.path);
      messenger.setMockMethodCallHandler(
        connectivity,
        (_) async => [online ? 'wifi' : 'none'],
      );
      messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
      SharedPreferences.setMockInitialValues({'billar_id': 'A'});
      await PreferencesService().init();

      final remote = <int, Map<String, dynamic>>{
        1: {'id': 1, 'billar_id': 'B', 'name': 'Otro negocio'},
        2: {
          'id': 2, 'billar_id': 'A', 'name': 'Proveedor A',
          'credit_days': 30, 'preferred_payment_method': 'credito',
        },
      };
      var relations = <Map<String, int>>[
        {'provider_id': 2, 'product_id': 1},
        {'provider_id': 2, 'product_id': 3},
      ];
      var providerName = 'Proveedor A';
      String? relationFilter;
      var relationWrites = 0;
      var rpcInstalled = false;
      var loseRpcResponse = false;
      var rejectRpc = false;
      final rpcRequests = <Map<String, dynamic>>[];
      final completedDeletes = <String, Map<String, dynamic>>{};
      final remoteRelations = <int, Set<int>>{};
      final rejectedProviders = <int>{};
      final providerLookups = <int>[];
      final authorization = <String?>[];
      Completer<void>? downloadStarted;
      Completer<void>? allowDownload;
      Completer<void>? insertStarted;
      Completer<void>? allowInsert;
      final client = MockClient((request) async {
        final headers = {'content-type': 'application/json'};
        Object? data = [];
        var status = 200;
        if (request.url.path == '/auth/v1/token') {
          final email = (jsonDecode(request.body) as Map)['email'];
          final id =
              email == 'b@example.com'
                  ? '00000000-0000-0000-0000-000000000002'
                  : '00000000-0000-0000-0000-000000000001';
          final payload = base64Url
              .encode(
                utf8.encode(
                  jsonEncode({
                    'sub': id,
                    'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
                  }),
                ),
              )
              .replaceAll('=', '');
          data = {
            'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'refresh-$id',
            'user': {
              'id': id,
              'aud': 'authenticated',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2025-01-01T00:00:00Z',
            },
          };
        } else if (request.url.path ==
            '/rest/v1/rpc/archive_provider_idempotent') {
          authorization.add(request.headers['authorization']);
          final body = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          rpcRequests.add(body);
          if (!rpcInstalled) {
            status = 404;
            data = {'code': 'PGRST202', 'message': 'Función no instalada'};
          } else if (rejectRpc) {
            status = 403;
            data = {'code': '42501', 'message': 'Sin permiso'};
          } else {
            final id = body['p_provider_id'] as int;
            final business = body['p_billar_id'] as String;
            final requestId = body['p_request_id'] as String;
            final previous = completedDeletes[requestId];
            if (previous != null) {
              data = previous;
            } else if (remote[id]?['billar_id'] != business) {
              status = 403;
              data = {'code': '42501', 'message': 'Proveedor no disponible'};
            } else {
              remote[id]!['is_active'] = false;
              data = {
                'request_id': requestId,
                'billar_id': business,
                'provider_id': id,
                'archived': true,
              };
              completedDeletes[requestId] = data as Map<String, dynamic>;
              if (loseRpcResponse) {
                loseRpcResponse = false;
                throw http.ClientException('Respuesta RPC perdida');
              }
            }
          }
        } else if (request.url.path == '/rest/v1/providers') {
          authorization.add(request.headers['authorization']);
          if (request.method == 'GET') {
            if (request.url.queryParameters.containsKey('id')) {
              final id = int.parse(
                request.url.queryParameters['id']!.substring(3),
              );
              providerLookups.add(id);
              final business = request.url.queryParameters['billar_id']!
                  .substring(3);
              data = remote[id]?['billar_id'] == business ? {'id': id} : null;
            } else {
              if (downloadStarted != null) {
                downloadStarted!.complete();
                await allowDownload!.future;
                downloadStarted = null;
              }
              data = [
                {...remote[2]!, 'name': providerName},
              ];
            }
          } else if (request.method == 'PATCH') {
            final id = int.parse(
              request.url.queryParameters['id']!.substring(3),
            );
            final business = request.url.queryParameters['billar_id']!
                .substring(3);
            if (rejectedProviders.contains(id)) {
              status = 503;
              data = {'message': 'Temporalmente no disponible'};
            } else if (remote[id]?['billar_id'] == business) {
              remote[id]!.addAll(Map<String, dynamic>.from(
                jsonDecode(request.body) as Map,
              ));
              data = [
                {'id': id},
              ];
            }
          } else if (request.method == 'POST') {
            final row = Map<String, dynamic>.from(
              jsonDecode(request.body) as Map,
            );
            final id = row['id'] as int;
            if (insertStarted != null) {
              insertStarted!.complete();
              await allowInsert!.future;
              insertStarted = null;
            }
            if (remote.containsKey(id)) {
              status = 409;
              data = {'code': '23505', 'message': 'duplicate key'};
            } else {
              remote[id] = row;
            }
          } else if (request.method == 'DELETE') {
            throw StateError('No se deben borrar proveedores físicamente');
          }
        } else if (request.url.path == '/rest/v1/provider_products') {
          authorization.add(request.headers['authorization']);
          if (request.method == 'GET') {
            relationFilter = request.url.queryParameters['provider_id'];
            data = relations;
          } else {
            relationWrites++;
            if (request.method == 'DELETE') {
              final id = int.parse(
                request.url.queryParameters['provider_id']!.substring(3),
              );
              remoteRelations.remove(id);
            } else if (request.method == 'POST') {
              final row = jsonDecode(request.body) as Map;
              (remoteRelations[row['provider_id'] as int] ??= <int>{}).add(
                row['product_id'] as int,
              );
            }
          }
        } else if (request.method == 'GET' &&
            request.url.path.startsWith('/rest/v1/')) {
          data = [];
        } else {
          throw StateError(
            'Unexpected request ${request.method} ${request.url.path}',
          );
        }
        return http.Response(
          jsonEncode(data),
          status,
          headers: headers,
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
        final token = Supabase.instance.client.auth.currentSession!.accessToken;
        db = await DatabaseHelper.instance.database;
        await db.insert('providers', {'id': 2, 'name': 'Local'});
        for (final product in [
          {'id': 1, 'billar_id': 'A', 'name': 'Uno'},
          {'id': 2, 'billar_id': 'A', 'name': 'Dos'},
          {'id': 3, 'billar_id': 'B', 'name': 'Otro billar'},
        ]) {
          await db.insert('products', {...product, 'synced': 1});
        }
        await db.insert('provider_products', {
          'provider_id': 2,
          'product_id': 2,
        });

        expect(
          await SyncService().pushProviderToCloud({'name': 'No reasignar'}, 1),
          isFalse,
        );
        expect(remote[1]!['billar_id'], 'B');
        expect(remote[1]!['name'], 'Otro negocio');
        expect(
          await SyncService().pushProviderToCloud({'name': 'Actualizado'}, 2),
          isTrue,
        );
        expect(remote[2]!['name'], 'Actualizado');
        expect(
          await SyncService().pushProviderToCloud({'name': 'Nuevo'}, 4),
          isTrue,
        );
        expect(remote[4]!['billar_id'], 'A');
        expect(await SyncService().pushProviderProductsToCloud(1), isFalse);
        expect(await SyncService().archiveProviderInCloud(1, 'request'), isFalse);
        expect(relationWrites, 0);
        expect(remote[1]!['name'], 'Otro negocio');

        await SyncService().pullProvidersFromCloud();
        expect(relationFilter, 'in.(2)');
        expect((await db.query('providers', where: 'id = 2')).single['credit_days'], 30);
        expect((await db.query('providers', where: 'id = 2')).single['preferred_payment_method'], 'credito');
        remote[2]!.remove('credit_days');
        remote[2]!.remove('preferred_payment_method');
        await SyncService().pullProvidersFromCloud();
        expect((await db.query('providers', where: 'id = 2')).single['credit_days'], 30);
        remote[2]!['credit_days'] = null;
        remote[2]!['preferred_payment_method'] = null;
        await SyncService().pullProvidersFromCloud();
        expect((await db.query('providers', where: 'id = 2')).single['credit_days'], isNull);
        expect((await db.query('providers', where: 'id = 2')).single['preferred_payment_method'], isNull);
        final rows = await db.query('provider_products', orderBy: 'product_id');
        expect(rows.map((row) => row['product_id']), [1, 2]);
        await db.insert('provider_products', {
          'provider_id': 2,
          'product_id': 3,
        });
        expect(await SyncService().pushProviderProductsToCloud(2), isFalse);
        expect(relationWrites, 0);
        await db.delete(
          'provider_products',
          where: 'provider_id = ? AND product_id = ?',
          whereArgs: [2, 3],
        );
        expect(await SyncService().pushProviderProductsToCloud(2), isTrue);
        expect(relationWrites, 3);
        insertStarted = Completer<void>();
        allowInsert = Completer<void>();
        final newProvider = SyncService().pushProviderToCloud({
          'name': 'En cola',
        }, 5);
        await insertStarted!.future.timeout(const Duration(seconds: 5));
        final newRelations = SyncService().pushProviderProductsToCloud(5);
        await Future<void>.delayed(Duration.zero);
        expect(providerLookups, isNot(contains(5)));
        allowInsert.complete();
        expect(await newProvider, isTrue);
        expect(await newRelations, isTrue);
        expect(providerLookups, contains(5));

        insertStarted = Completer<void>();
        allowInsert = Completer<void>();
        final oldSessionProvider = SyncService().pushProviderToCloud({
          'name': 'Sesión anterior',
        }, 6);
        await insertStarted!.future.timeout(const Duration(seconds: 5));
        final oldSessionRelations = SyncService().pushProviderProductsToCloud(
          6,
        );
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com',
          password: 'test',
        );
        allowInsert.complete();
        expect(await oldSessionProvider, isFalse);
        expect(await oldSessionRelations, isFalse);
        expect(providerLookups, isNot(contains(6)));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        expect(
          authorization.every((value) => value == 'Bearer $token'),
          isTrue,
        );

        providerName = 'No aplicar';
        relations = [
          {'provider_id': 1, 'product_id': 1},
        ];
        await SyncService().pullProvidersFromCloud();
        expect(
          (await db.query('providers', where: 'id = 2')).single['name'],
          'Proveedor A',
        );
        expect(await db.query('provider_products'), hasLength(2));

        relations = [];
        downloadStarted = Completer<void>();
        allowDownload = Completer<void>();
        final download = SyncService().pullProvidersFromCloud();
        await downloadStarted!.future.timeout(const Duration(seconds: 5));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com',
          password: 'test',
        );
        allowDownload.complete();
        await download;
        expect(
          (await db.query('providers', where: 'id = 2')).single['name'],
          'Proveedor A',
        );
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        online = false;
        final repository = PurchasesRepository();
        final offlineId = await repository.saveProvider(
          const ProviderEntity(
            name: 'Guardado sin conexión', creditDays: 45,
            preferredPaymentMethod: 'credito',
          ),
          [1, 2],
        );
        var pending = await db.query(
          'pending_provider_operations',
          where: 'provider_id = ?',
          whereArgs: [offlineId],
          orderBy: 'id',
        );
        expect(pending.map((row) => row['operation']), ['save', 'products']);
        final savedPayload = jsonDecode(pending.first['payload'] as String) as Map;
        expect(savedPayload['credit_days'], 45);
        expect(savedPayload['preferred_payment_method'], 'credito');
        expect(pending.map((row) => row['actor_id']).toSet(), {
          Supabase.instance.client.auth.currentUser!.id,
        });
        expect(pending.map((row) => row['billar_id']).toSet(), {'A'});
        await expectLater(
          repository.saveProvider(const ProviderEntity(name: 'Inválido'), [3]),
          throwsStateError,
        );
        expect(
          await db.query(
            'providers',
            where: 'name = ?',
            whereArgs: ['Inválido'],
          ),
          isEmpty,
        );
        final separate = await ffi.databaseFactoryFfi.openDatabase(
          db.path,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
        );
        try {
          expect(
            await separate.query(
              'pending_provider_operations',
              where: 'provider_id = ?',
              whereArgs: [offlineId],
            ),
            hasLength(2),
          );
        } finally {
          await separate.close();
        }

        await SyncService().syncAllPending();
        expect(remote.containsKey(offlineId), isFalse);
        online = true;
        await PreferencesService().setBillarId('B');
        await SyncService().syncAllPending();
        expect(remote.containsKey(offlineId), isFalse);
        await PreferencesService().setBillarId('A');
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com',
          password: 'test',
        );
        await SyncService().syncAllPending();
        expect(remote.containsKey(offlineId), isFalse);
        expect(
          await db.query(
            'pending_provider_operations',
            where: 'provider_id = ?',
            whereArgs: [offlineId],
          ),
          hasLength(2),
        );
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        rejectedProviders.add(offlineId);
        final otherId = await repository.saveProvider(
          const ProviderEntity(name: 'Otro pendiente'),
          [],
        );
        await SyncService().syncAllPending();
        expect(remote.containsKey(offlineId), isFalse);
        expect(remote[otherId]!['name'], 'Otro pendiente');
        expect(
          await db.query(
            'pending_provider_operations',
            where: 'provider_id = ?',
            whereArgs: [offlineId],
          ),
          hasLength(2),
        );
        rejectedProviders.clear();
        await SyncService().syncAllPending();
        expect(remote[offlineId]!['name'], 'Guardado sin conexión');
        expect(remote[offlineId]!['credit_days'], 45);
        expect(remote[offlineId]!['preferred_payment_method'], 'credito');
        expect(remoteRelations[offlineId], {1, 2});
        expect(await db.query('pending_provider_operations'), isEmpty);

        await repository.saveProvider(
          const ProviderEntity(id: 2, name: 'Edición local'),
          [2],
        );
        providerName = 'Versión remota anterior';
        relations = [
          {'provider_id': 2, 'product_id': 1},
        ];
        await SyncService().pullProvidersFromCloud();
        expect(
          (await db.query('providers', where: 'id = 2')).single['name'],
          'Edición local',
        );
        expect(
          (await db.query(
            'provider_products',
            where: 'provider_id = 2',
          )).map((row) => row['product_id']),
          [2],
        );
        await SyncService().syncAllPending();
        expect(remote[2]!['name'], 'Edición local');
        expect(await db.query('pending_provider_operations'), isEmpty);

        await repository.setProductProviders(2, []);
        pending = await db.query('pending_provider_operations');
        expect(pending.map((row) => row['provider_id']).toSet(), {
          2,
          offlineId,
        });
        final payloads = {
          for (final row in pending)
            row['provider_id'] as int: jsonDecode(row['payload'] as String),
        };
        expect(payloads[2], isEmpty);
        expect(payloads[offlineId], [1]);
        await SyncService().syncAllPending();
        expect(await db.query('pending_provider_operations'), isEmpty);
        expect(remoteRelations[offlineId], {1});
        expect(remoteRelations[2], isNull);

        online = false;
        await db.insert('purchases', {
          'billar_id': 'A',
          'provider_id': offlineId,
          'total': 10,
          'date': '2025-01-01',
          'synced': 1,
        });
        await repository.deleteProvider(offlineId);
        expect(remote.containsKey(offlineId), isTrue);
        expect(await db.query('pending_provider_operations'), hasLength(1));
        expect((await db.query('providers', where: 'id = ?', whereArgs: [offlineId])).single['is_active'], 0);
        expect((await repository.getProviders()).map((p) => p.id), isNot(contains(offlineId)));
        expect(await repository.getProviderProductIds(offlineId), [1]);
        expect(await repository.getProductProviderIds(1), isNot(contains(offlineId)));
        expect((await repository.getHistory()).single['provider_name'], 'Guardado sin conexión');
        await repository.setProductProviders(1, []);
        expect(await repository.getProviderProductIds(offlineId), [1]);
        online = true;
        await SyncService().syncAllPending();
        expect(remote[offlineId]!['is_active'], isNot(false));
        expect(await db.query('pending_provider_operations'), hasLength(1));
        rpcInstalled = true;
        await SyncService().syncAllPending();
        expect(remote[offlineId]!['is_active'], false);
        expect(remoteRelations[offlineId], {1});
        expect(await db.query('pending_provider_operations'), isEmpty);

        final raceId = await repository.saveProvider(
          const ProviderEntity(name: 'Interrumpido'),
          [],
        );
        insertStarted = Completer<void>();
        allowInsert = Completer<void>();
        final interruptedSync = SyncService().syncAllPending();
        await insertStarted!.future.timeout(const Duration(seconds: 5));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com',
          password: 'test',
        );
        allowInsert.complete();
        await interruptedSync;
        expect(
          await db.query(
            'pending_provider_operations',
            where: 'provider_id = ?',
            whereArgs: [raceId],
          ),
          hasLength(2),
        );
        await SyncService().syncAllPending();
        expect(
          await db.query(
            'pending_provider_operations',
            where: 'provider_id = ?',
            whereArgs: [raceId],
          ),
          hasLength(2),
        );
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        await SyncService().syncAllPending();
        expect(remote[raceId]!['name'], 'Interrumpido');
        expect(await db.query('pending_provider_operations'), isEmpty);

        final safeId = await repository.saveProvider(
          const ProviderEntity(name: 'Borrado seguro'),
          [],
        );
        await SyncService().syncAllPending();
        await repository.deleteProvider(safeId);
        final safeRow =
            (await db.query(
              'pending_provider_operations',
              where: 'provider_id = ?',
              whereArgs: [safeId],
            )).single;
        final safeRequestId =
            (jsonDecode(safeRow['payload'] as String) as Map)['request_id'];
        expect(
          safeRequestId,
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
        rejectRpc = true;
        final writesBeforeRejection = relationWrites;
        await SyncService().syncAllPending();
        expect(remote.containsKey(safeId), isTrue);
        expect(relationWrites, writesBeforeRejection);
        rejectRpc = false;
        loseRpcResponse = true;
        await SyncService().syncAllPending();
        expect(remote[safeId]!['is_active'], false);
        expect(
          await db.query(
            'pending_provider_operations',
            where: 'provider_id = ?',
            whereArgs: [safeId],
          ),
          hasLength(1),
        );
        final attemptsBeforeOtherUser = rpcRequests.length;
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'b@example.com',
          password: 'test',
        );
        await SyncService().syncAllPending();
        expect(rpcRequests, hasLength(attemptsBeforeOtherUser));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        await SyncService().syncAllPending();
        expect(
          await db.query(
            'pending_provider_operations',
            where: 'provider_id = ?',
            whereArgs: [safeId],
          ),
          isEmpty,
        );
        expect(
          rpcRequests
              .where((body) => body['p_provider_id'] == safeId)
              .map((body) => body['p_request_id'])
              .toSet(),
          {safeRequestId},
        );
        remote[2]!['is_active'] = false;
        await SyncService().pullProvidersFromCloud();
        expect((await db.query('providers', where: 'id = 2')).single['is_active'], 0);

        online = false;
        final otherPurchaseId = await db.insert('purchases', {
          'billar_id': 'B',
          'total': 20,
          'date': '2026-01-01',
          'reference': 'OTRO',
        });
        final legacyPurchaseId = await db.insert('purchases', {
          'total': 15,
          'date': '2026-01-01',
          'reference': 'SIN BILLAR',
        });
        await db.insert('purchase_details', {
          'purchase_id': otherPurchaseId,
          'product_id': 1,
          'quantity': 1,
          'cost_per_unit': 20,
        });
        expect(await repository.getPurchaseDetails(otherPurchaseId), isEmpty);
        expect(await repository.cancelPurchase(otherPurchaseId), isFalse);
        expect(await repository.cancelPurchase(legacyPurchaseId), isFalse);
        expect((await db.query('purchases', where: 'id = ?', whereArgs: [otherPurchaseId])).single['cancelled'], 0);
        expect((await repository.getHistory()).map((row) => row['reference']), isNot(contains('OTRO')));
        expect((await repository.getHistory()).map((row) => row['reference']), isNot(contains('SIN BILLAR')));
        final purchaseId = await repository.savePurchase(
          purchase: const PurchaseEntity(
            reference: 'Compra sin conexión',
            items: [
              PurchaseItemEntity(
                productId: 1,
                productName: 'Uno',
                quantity: 2,
                costPerUnit: 3,
              ),
            ],
          ),
        );
        final purchase = (await db.query(
          'purchases',
          where: 'id = ?',
          whereArgs: [purchaseId],
        )).single;
        expect(purchase['billar_id'], 'A');
        expect(purchase['synced'], 0);
        final creditProviderId = await repository.saveProvider(
          const ProviderEntity(name: 'Crédito', creditDays: 30, preferredPaymentMethod: 'credito'),
          [],
        );
        final today = DateTime.now().toUtc();
        final reports = ReportsRepository();
        final cashBefore = await reports.getCashFlowSummary(today, today);
        final outflowsBefore = await db.query('cash_outflows');
        final session = SyncService().captureProviderSession();
        final creditId = await repository.savePurchase(
          expectedSession: session,
          purchase: PurchaseEntity(
            providerId: creditProviderId, reference: 'Excepción solo para esta compra',
            cashSource: null,
            paymentTerms: PurchasePaymentTerms(option: 'credito', creditDays: 45),
            items: const [PurchaseItemEntity(productId: 1, productName: 'Uno', quantity: 1, costPerUnit: 5)],
          ),
        );
        final credit = await repository.getPurchaseHeader(creditId, session: session);
        expect(credit['cash_source'], isNull);
        expect(credit['paid_amount'], 0);
        expect(credit['balance_due'], 5);
        expect(credit['credit_days'], 45);
        expect(
          credit['due_date'],
          DateTime.utc(today.year, today.month, today.day).add(const Duration(days: 45)).toIso8601String().substring(0, 10),
        );
        expect((await db.query('providers', where: 'id = ?', whereArgs: [creditProviderId])).single['credit_days'], 30);
        expect(await db.query('cash_outflows'), outflowsBefore);
        expect(await reports.getCashFlowSummary(today, today), cashBefore);
        expect(await repository.cancelPurchase(creditId), isTrue);
        final cancelledCredit = await repository.getPurchaseHeader(creditId, session: session);
        expect(cancelledCredit['cancelled'], 1);
        for (final field in ['payment_condition', 'payment_method', 'credit_days', 'due_date', 'paid_amount', 'balance_due', 'cash_source']) {
          expect(cancelledCredit[field], credit[field]);
        }
        final headersBefore = await db.query('purchases');
        final stockBefore = await db.query('products');
        final detailsBefore = await db.query('purchase_details');
        final movementsBefore = await db.query('inventory_movements');
        await db.execute('''
          CREATE TEMP TRIGGER fail_purchase_movement BEFORE INSERT ON inventory_movements
          BEGIN SELECT RAISE(ABORT, 'Movimiento no disponible'); END
        ''');
        await expectLater(
          repository.savePurchase(purchase: PurchaseEntity(
            providerId: creditProviderId, cashSource: null,
            paymentTerms: PurchasePaymentTerms(option: 'credito', creditDays: 30),
            items: const [PurchaseItemEntity(productId: 1, productName: 'Uno', quantity: 1, costPerUnit: 5)],
          )),
          throwsA(isA<DatabaseException>()),
        );
        await db.execute('DROP TRIGGER fail_purchase_movement');
        expect(await db.query('purchases'), headersBefore);
        expect(await db.query('products'), stockBefore);
        expect(await db.query('purchase_details'), detailsBefore);
        expect(await db.query('inventory_movements'), movementsBefore);
        await PreferencesService().setBillarId('B');
        await expectLater(
          repository.savePurchase(expectedSession: session, purchase: const PurchaseEntity(
            items: [PurchaseItemEntity(productId: 1, productName: 'Uno', quantity: 1, costPerUnit: 5)],
          )),
          throwsStateError,
        );
        expect(await repository.getPurchaseDetails(otherPurchaseId), hasLength(1));
        expect((await repository.getHistory()).map((row) => row['reference']), contains('OTRO'));
        expect(await repository.getPurchaseDetails(purchaseId), isEmpty);
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
