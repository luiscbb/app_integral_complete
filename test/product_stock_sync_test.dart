import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/features/inventory/data/repositories/product_repository.dart';
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
    'preserves local changes during uploads and conflict resolution',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'product_stock_sync_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(
        pathChannel,
        (call) async => directory.path,
      );
      SharedPreferences.setMockInitialValues({'billar_id': 'TEST'});
      await PreferencesService().init();
      var remoteStock = 10.0;
      var remoteRevision = 0;
      var loseNextResponse = false;
      var remoteArchived = false;
      var emptyProductsResponse = false;
      Completer<void>? downloadStarted;
      Completer<void>? allowDownload;
      Completer<void>? requestStarted;
      Completer<void>? allowResponse;
      Completer<void>? archiveStarted;
      Completer<void>? allowArchive;
      var confirmArchive = false;
      final archiveRequests = <({String? billar, String? token})>[];
      String? uploadToken;
      String? imageUploadPath;
      String? imageUploadToken;
      var productUploads = 0;

      final client = MockClient((request) async {
        final headers = {'content-type': 'application/json'};
        if (request.url.path.startsWith('/storage/v1/object/product_images/') &&
            request.method == 'POST') {
          imageUploadPath = request.url.path;
          imageUploadToken = request.headers['authorization'];
          return http.Response(
            jsonEncode({'Key': request.url.path}),
            200,
            headers: headers,
            request: request,
          );
        } else if (request.url.path == '/auth/v1/token') {
          final email = (jsonDecode(request.body) as Map)['email'];
          final userId = email == 'other@example.com'
              ? '00000000-0000-0000-0000-000000000002'
              : '00000000-0000-0000-0000-000000000001';
          final payload = base64Url
              .encode(
                utf8.encode(
                  jsonEncode({
                    'sub': userId,
                    'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
                  }),
                ),
              )
              .replaceAll('=', '');
          return http.Response(
            jsonEncode({
              'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
              'token_type': 'bearer',
              'expires_in': 3600,
              'refresh_token': 'test-refresh',
              'user': {
                'id': userId,
                'aud': 'authenticated',
                'app_metadata': <String, dynamic>{},
                'user_metadata': <String, dynamic>{},
                'created_at': '2025-01-01T00:00:00Z',
              },
            }),
            200,
            headers: headers,
            request: request,
          );
        } else if (request.url.path == '/rest/v1/products' &&
            request.method == 'GET') {
          if (request.url.queryParameters['select'] == '*') {
            if (downloadStarted != null) {
              downloadStarted!.complete();
              await allowDownload!.future;
              downloadStarted = null;
              allowDownload = null;
            }
            return http.Response(
              jsonEncode(emptyProductsResponse ? [] : [
                {
                  'id': 1,
                  'billar_id': 'TEST',
                  'name': 'PRODUCTO',
                  'description': '',
                  'price': 1,
                  'cost': 0,
                  'stock': remoteStock,
                  'stock_revision': remoteRevision,
                  'is_promo': 0,
                  'pieces_per_unit': 1,
                  'is_active': !remoteArchived,
                },
              ]),
              200,
              headers: headers,
              request: request,
            );
          }
          return http.Response(
            jsonEncode({
              'stock': remoteStock,
              'stock_revision': remoteRevision,
            }),
            200,
            headers: headers,
            request: request,
          );
        } else if (request.url.path == '/rest/v1/products' &&
            request.method == 'PATCH') {
          archiveRequests.add((
            billar: request.url.queryParameters['billar_id'],
            token: request.headers['authorization'],
          ));
          if (archiveStarted != null) {
            archiveStarted!.complete();
            await allowArchive!.future;
            archiveStarted = null;
          }
          return http.Response(
            jsonEncode(confirmArchive ? {'id': 901} : null),
            200,
            headers: headers,
            request: request,
          );
        } else if ((request.url.path == '/rest/v1/products' ||
                request.url.path ==
                    '/rest/v1/rpc/resolve_product_stock_conflict') &&
            request.method == 'POST') {
          if (request.url.path == '/rest/v1/products') {
            uploadToken = request.headers['authorization'];
            productUploads++;
          }
          final data = jsonDecode(request.body) as Map<String, dynamic>;
          final isResolution = request.url.path.contains('/rpc/');
          final stock =
              (data[isResolution ? 'p_stock' : 'stock'] as num).toDouble();
          final expected =
              isResolution
                  ? data['p_expected_revision']
                  : data['stock_revision'] - 1;
          if (expected != remoteRevision) {
            return http.Response(
              jsonEncode({'code': '40001', 'message': 'Inventario cambió'}),
              409,
              headers: headers,
              request: request,
            );
          } else {
            if (requestStarted != null) {
              requestStarted!.complete();
              await allowResponse!.future;
              requestStarted = null;
              allowResponse = null;
            }
            remoteStock = stock;
            remoteRevision++;
            if (loseNextResponse) {
              loseNextResponse = false;
              throw http.ClientException('Respuesta perdida');
            }
            return http.Response(
              jsonEncode(
                isResolution
                    ? remoteRevision
                    : {...data, 'stock_revision': remoteRevision},
              ),
              200,
              headers: headers,
              request: request,
            );
          }
        }
        return http.Response('{}', 404, headers: headers, request: request);
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
          email: 'test@example.com',
          password: 'test-password',
        );
        db = await DatabaseHelper.instance.database;
        final database = db;
        await database.insert('products', {
          'id': 1,
          'billar_id': 'TEST',
          'name': 'PRODUCTO',
          'price': 1,
          'stock': 9,
          'stock_revision': 0,
          'synced': 0,
        });
        await database.insert('products', {
          'id': 2,
          'billar_id': 'TEST',
          'name': 'PENDIENTE',
          'price': 1,
          'stock': 3,
          'synced': 0,
        });
        await database.insert('products', {
          'id': 3,
          'billar_id': 'TEST',
          'name': 'AUSENTE EN RESPUESTA',
          'price': 1,
          'stock': 4,
          'synced': 1,
        });
        final repo = ProductRepository();
        await repo.refreshFromCloud();
        expect(
          (await database.query(
            'products',
            where: 'id = ?',
            whereArgs: [2],
          )).single['stock'],
          3,
        );
        expect(
          (await database.query('products', where: 'id = ?', whereArgs: [3])),
          hasLength(1),
        );
        emptyProductsResponse = true;
        await repo.refreshFromCloud();
        expect(
          (await database.query('products', where: 'id = ?', whereArgs: [3])),
          hasLength(1),
        );
        emptyProductsResponse = false;
        await database.update(
          'products',
          {'synced': 1, 'stock': 8, 'stock_revision': 1},
          where: 'id = 1',
        );
        await repo.refreshFromCloud();
        final newer = (await database.query('products', where: 'id = 1')).single;
        expect(newer['stock'], 8);
        expect(newer['stock_revision'], 1);
        await database.update(
          'products',
          {'stock': remoteStock, 'stock_revision': remoteRevision},
          where: 'id = 1',
        );
        remoteArchived = true;
        await repo.refreshFromCloud();
        expect(
          (await database.query('products', where: 'id = 1')).single['is_active'],
          0,
        );
        remoteArchived = false;
        downloadStarted = Completer<void>();
        allowDownload = Completer<void>();
        final download = repo.refreshFromCloud();
        await downloadStarted!.future.timeout(const Duration(seconds: 5));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'other@example.com',
          password: 'test-password',
        );
        allowDownload!.complete();
        await download;
        expect(
          (await database.query('products', where: 'id = 1')).single['is_active'],
          0,
        );
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'test@example.com',
          password: 'test-password',
        );
        await database.update(
          'products',
          {'synced': 0, 'is_active': 1, 'stock': 9},
          where: 'id = 1',
        );

        requestStarted = Completer<void>();
        allowResponse = Completer<void>();
        final firstUpload = repo.syncProductById(1);
        await requestStarted!.future.timeout(const Duration(seconds: 5));
        await database.rawUpdate(
          'UPDATE products SET stock = 8, synced = 0 WHERE id = 1',
        );
        allowResponse!.complete();
        await firstUpload;
        var local =
            (await database.query(
              'products',
              where: 'id = ?',
              whereArgs: [1],
            )).single;
        expect(local['stock'], 8);
        expect(local['synced'], 0);
        expect(local['stock_revision'], 1);
        await repo.syncProductById(1);
        local =
            (await database.query(
              'products',
              where: 'id = ?',
              whereArgs: [1],
            )).single;
        expect(local['synced'], 1);
        expect(remoteStock, 8);
        expect(remoteRevision, 2);

        remoteStock = 7;
        remoteRevision = 3;
        await database.rawUpdate(
          'UPDATE products SET stock = 6, synced = 0 WHERE id = 1',
        );
        await repo.syncProductById(1);
        local =
            (await database.query(
              'products',
              where: 'id = ?',
              whereArgs: [1],
            )).single;
        expect(local['stock'], 6);
        expect(local['stock_conflict'], 1);
        expect((await repo.getStockConflicts()).single.name, 'PRODUCTO');
        var snapshot = await repo.getStockConflictSnapshot(1);
        expect(snapshot.remoteStock, 7);
        expect(snapshot.product.stock, 6);

        requestStarted = Completer<void>();
        allowResponse = Completer<void>();
        final resolution = repo.resolveStockConflict(snapshot, 4);
        await requestStarted!.future.timeout(const Duration(seconds: 5));
        await database.rawUpdate(
          'UPDATE products SET stock = 5, synced = 0 WHERE id = 1',
        );
        allowResponse!.complete();
        await expectLater(resolution, throwsStateError);
        local =
            (await database.query(
              'products',
              where: 'id = ?',
              whereArgs: [1],
            )).single;
        expect(local['stock'], 5);
        expect(local['stock_conflict'], 1);
        expect(remoteStock, 4);

        snapshot = await repo.getStockConflictSnapshot(1);
        await repo.resolveStockConflict(snapshot, 3);
        local =
            (await database.query(
              'products',
              where: 'id = ?',
              whereArgs: [1],
            )).single;
        expect(local['stock'], 3);
        expect(local['stock_conflict'], 0);
        expect(local['synced'], 1);
        expect(remoteStock, 3);

        await database.rawUpdate(
          'UPDATE products SET stock = 2, synced = 0 WHERE id = 1',
        );
        loseNextResponse = true;
        await repo.syncProductById(1);
        expect(remoteStock, 2);
        await repo.syncProductById(1);
        local =
            (await database.query(
              'products',
              where: 'id = ?',
              whereArgs: [1],
            )).single;
        expect(local['stock'], 2);
        expect(local['synced'], 0);
        expect(local['stock_conflict'], 1);

        await database.insert('products', {
          'id': 50,
          'billar_id': 'OTRO',
          'name': 'PRODUCTO AJENO',
          'synced': 0,
        });
        expect(
          (await repo.getAll(syncRemote: false, includeArchived: true))
              .map((product) => product.name),
          isNot(contains('PRODUCTO AJENO')),
        );
        final uploadsBeforeForeign = productUploads;
        await repo.syncProductById(50);
        expect(productUploads, uploadsBeforeForeign);
        await database.insert('pending_product_deletions', {
          'billar_id': 'TEST', 'product_id': 901,
        });
        await database.insert('pending_product_deletions', {
          'billar_id': 'OTRO', 'product_id': 902,
        });
        await repo.syncPendingProductDeletions();
        expect(archiveRequests.map((request) => request.billar), ['eq.TEST']);
        expect(await database.query('pending_product_deletions'), hasLength(2));
        confirmArchive = true;
        archiveStarted = Completer<void>();
        allowArchive = Completer<void>();
        final token = Supabase.instance.client.auth.currentSession!.accessToken;
        final interruptedArchive = repo.syncPendingProductDeletions();
        await archiveStarted!.future.timeout(const Duration(seconds: 5));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'other@example.com',
          password: 'test-password',
        );
        allowArchive.complete();
        await interruptedArchive;
        expect(archiveRequests.last.token, 'Bearer $token');
        expect(await database.query('pending_product_deletions'), hasLength(2));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'test@example.com',
          password: 'test-password',
        );
        await repo.syncPendingProductDeletions();
        final remaining = await database.query('pending_product_deletions');
        expect(remaining.single['billar_id'], 'OTRO');

        await database.update('products', {
          'stock': 6,
          'stock_conflict': 0,
          'stock_revision': remoteRevision,
          'synced': 0,
        }, where: 'id = ?', whereArgs: [1]);
        requestStarted = Completer<void>();
        allowResponse = Completer<void>();
        final uploadStartToken = Supabase.instance.client.auth.currentSession!.accessToken;
        final interruptedUpload = repo.syncProductById(1);
        await requestStarted!.future.timeout(const Duration(seconds: 5));
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'other@example.com',
          password: 'test-password',
        );
        allowResponse!.complete();
        await interruptedUpload;
        expect(uploadToken, 'Bearer $uploadStartToken');
        local = (await database.query('products', where: 'id = 1')).single;
        expect(local['synced'], 0);
        expect(local['stock_revision'], remoteRevision - 1);
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'test@example.com',
          password: 'test-password',
        );
        final image = File('${directory.path}${Platform.pathSeparator}image.jpg');
        await image.writeAsBytes([1, 2, 3]);
        await database.update('products', {
          'stock_revision': remoteRevision,
          'image_path': image.path,
          'synced': 0,
        }, where: 'id = ?', whereArgs: [1]);
        final imageToken = Supabase.instance.client.auth.currentSession!.accessToken;
        await repo.syncProductById(1);
        expect(imageUploadPath, startsWith('/storage/v1/object/product_images/TEST/products/'));
        expect(imageUploadToken, 'Bearer $imageToken');
        local = (await database.query('products', where: 'id = 1')).single;
        expect(local['image_path'], contains('/product_images/TEST/products/'));
      } finally {
        await Supabase.instance.dispose();
        client.close();
        await db?.close();
        messenger.setMockMethodCallHandler(pathChannel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
