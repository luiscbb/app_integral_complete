import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_service.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/features/inventory/data/repositories/owner_promo_outbox.dart';
import 'package:app_integral_complete/features/inventory/data/repositories/product_repository.dart';
import 'package:app_integral_complete/features/inventory/domain/entities/product_entity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path_utils;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('atomic promo queue recovers a lost response and later edits', () async {
    final directory = await Directory.systemTemp.createTemp('owner_promo_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const path = MethodChannel('plugins.flutter.io/path_provider');
    const connectivity = MethodChannel(
      'dev.fluttercommunity.plus/connectivity',
    );
    const events = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(path, (_) async => directory.path);
    messenger.setMockMethodCallHandler(connectivity, (_) async => ['none']);
    messenger.setMockMethodCallHandler(events, (_) async => null);
    SharedPreferences.setMockInitialValues({'billar_id': 'A'});
    await PreferencesService().init();
    const actor = '00000000-0000-0000-0000-000000000001';
    final tokenBody = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'sub': actor,
              'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
            }),
          ),
        )
        .replaceAll('=', '');
    final calls = <Map<String, dynamic>>[];
    final accepted = <String, (String, int)>{};
    var revision = -1;
    var loseResponse = true;
    var conflict = false;
    var changeScopeOnResponse = false;
    var legacyProductWrites = 0;
    final uploadedImages = <String>[];
    final mock = MockClient((request) async {
      if (request.url.path.startsWith('/storage/v1/object/product_images/') &&
          request.method == 'POST') {
        expect(request.headers['authorization'], startsWith('Bearer '));
        uploadedImages.add(request.url.path);
        return http.Response(
          jsonEncode({'Key': request.url.path}),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      if (request.url.path == '/auth/v1/token') {
        return http.Response(
          jsonEncode({
            'access_token': 'eyJhbGciOiJub25lIn0.$tokenBody.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'test',
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
          request: request,
        );
      }
      if (request.url.path == '/rest/v1/rpc/sync_owner_promo') {
        expect(request.headers['authorization'], startsWith('Bearer '));
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        calls.add(payload);
        final id = payload['p_request_id'] as String;
        if (conflict) {
          return http.Response(
            jsonEncode({'code': '40001', 'message': 'La promoción cambió'}),
            409,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        final existing = accepted[id];
        if (existing != null) {
          expect(request.body, existing.$1);
          return http.Response(
            '${existing.$2}',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        expect(payload['p_expected_revision'], revision < 0 ? null : revision);
        revision++;
        accepted[id] = (request.body, revision);
        if (loseResponse) {
          loseResponse = false;
          throw http.ClientException('Lost response');
        }
        if (changeScopeOnResponse) {
          changeScopeOnResponse = false;
          await PreferencesService().setBillarId('B');
        }
        return http.Response(
          '$revision',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      if (request.url.path == '/rest/v1/products') {
        legacyProductWrites++;
      }
      throw StateError(
        'Unexpected request: ${request.method} ${request.url.path}',
      );
    });
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'key',
      httpClient: mock,
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
    );
    var db = await DatabaseHelper.instance.database;
    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: 'a@example.com',
        password: 'test',
      );
      await db.insert('products', {
        'id': 1,
        'billar_id': 'A',
        'name': 'PRODUCTO',
        'price': 10,
        'cost': 3,
        'stock': 10,
        'synced': 1,
        'stock_revision': 1,
      });
      final repo = ProductRepository(atomicPromoSync: true);
      await repo.insertPromo(
        const ProductEntity(
          name: 'PROMO',
          price: 20,
          cost: 6,
          stock: 0,
          isPromo: 1,
        ),
        {1: 2},
      );
      final created =
          (await db.query('products', where: 'is_promo = 1')).single;
      final id = created['id'] as int;
      expect(created['synced'], 0);
      expect(
        (await db.query('pending_owner_promos')).single['request_id'],
        calls.first['p_request_id'],
      );
      await ProductRepository().syncProductById(id);
      expect(legacyProductWrites, 0);
      await expectLater(ProductRepository().archive(id), throwsStateError);
      await expectLater(
        ProductRepository().updatePromo(
          ProductEntity(
            id: id,
            name: 'NO AUTORIZADO',
            price: 20,
            cost: 6,
            stock: 0,
            isPromo: 1,
          ),
          {1: 2},
        ),
        throwsStateError,
      );
      await db.update(
        'products',
        {'is_active': 0},
        where: 'id = ?',
        whereArgs: [1],
      );
      await repo.updatePromo(
        ProductEntity(
          id: id,
          name: 'PROMO EDITADA',
          price: 30,
          cost: 9,
          stock: 0,
          isPromo: 1,
        ),
        {1: 3},
      );
      expect(calls, hasLength(2));
      expect(calls[0], calls[1]);
      var local =
          (await db.query('products', where: 'id = ?', whereArgs: [id])).single;
      expect(local['stock_revision'], 0);
      expect(local['synced'], 0);
      await db.update(
        'products',
        {'is_active': 1},
        where: 'id = ?',
        whereArgs: [1],
      );
      await repo.syncPendingProducts();
      expect(calls, hasLength(3));
      expect(calls[2]['p_expected_revision'], 0);
      expect(calls[2]['p_product']['name'], 'PROMO EDITADA');
      expect(calls[2]['p_components'], [
        {'product_id': 1, 'quantity': 3},
      ]);
      local =
          (await db.query('products', where: 'id = ?', whereArgs: [id])).single;
      expect(local['stock_revision'], 1);
      expect(local['synced'], 1);
      expect(await db.query('pending_owner_promos'), isEmpty);

      await repo.archive(id);
      await repo.syncPendingProducts();
      expect(calls.last['p_product']['is_active'], false);
      expect(calls.last['p_expected_revision'], 1);
      expect(
        (await db.query(
          'products',
          where: 'id = ?',
          whereArgs: [id],
        )).single['synced'],
        1,
      );

      conflict = true;
      await repo.updatePromo(
        ProductEntity(
          id: id,
          name: 'CONFLICTO',
          price: 35,
          cost: 9,
          stock: 0,
          isPromo: 1,
        ),
        {1: 3},
      );
      final firstConflict = calls.last['p_request_id'];
      await repo.syncPendingProducts();
      expect(calls.last['p_request_id'], firstConflict);
      local =
          (await db.query('products', where: 'id = ?', whereArgs: [id])).single;
      expect(local['synced'], 0);
      expect(local['stock_conflict'], 0);
      expect(
        (await db.query('pending_owner_promos')).single['request_id'],
        firstConflict,
      );
      await db.update('pending_owner_promos', {'actor_id': 'other'});
      final previousCalls = calls.length;
      await expectLater(
        repo.updatePromo(
          ProductEntity(
            id: id,
            name: 'NO AUTORIZADO',
            price: 35,
            cost: 9,
            stock: 0,
            isPromo: 1,
          ),
          {1: 3},
        ),
        throwsStateError,
      );
      await expectLater(repo.archive(id), throwsStateError);
      await repo.syncPendingProducts();
      expect(calls, hasLength(previousCalls));
      expect(
        (await db.query(
          'products',
          where: 'id = ?',
          whereArgs: [id],
        )).single['name'],
        'CONFLICTO',
      );
      await db.update('pending_owner_promos', {'actor_id': actor});
      conflict = false;
      changeScopeOnResponse = true;
      await repo.syncPendingProducts();
      expect(
        (await db.query(
          'products',
          where: 'id = ?',
          whereArgs: [id],
        )).single['stock_revision'],
        2,
      );
      expect(
        (await db.query('pending_owner_promos')).single['request_id'],
        firstConflict,
      );
      await PreferencesService().setBillarId('A');
      await repo.syncPendingProducts();
      expect(calls.last['p_request_id'], firstConflict);
      expect(await db.query('pending_owner_promos'), isEmpty);
      local =
          (await db.query('products', where: 'id = ?', whereArgs: [id])).single;
      expect(local['stock_revision'], 3);
      expect(local['synced'], 1);

      final firstImage = File(path_utils.join(directory.path, 'first.jpg'));
      final secondImage = File(path_utils.join(directory.path, 'second.jpg'));
      await firstImage.writeAsBytes([1, 2, 3]);
      await secondImage.writeAsBytes([4, 5, 6]);
      loseResponse = true;
      await repo.updatePromo(
        ProductEntity(
          id: id,
          name: 'FOTO UNO',
          price: 35,
          cost: 9,
          stock: 0,
          isPromo: 1,
          imagePath: firstImage.path,
        ),
        {1: 3},
      );
      final firstImageRequest = calls.last;
      expect(uploadedImages, hasLength(1));
      expect(
        firstImageRequest['p_product']['image_path'],
        startsWith('http://'),
      );
      await repo.updatePromo(
        ProductEntity(
          id: id,
          name: 'FOTO DOS',
          price: 35,
          cost: 9,
          stock: 0,
          isPromo: 1,
          imagePath: secondImage.path,
        ),
        {1: 3},
      );
      expect(uploadedImages, hasLength(2));
      expect(calls.last, firstImageRequest);
      local =
          (await db.query('products', where: 'id = ?', whereArgs: [id])).single;
      expect(local['stock_revision'], 4);
      expect(local['synced'], 0);
      await repo.syncPendingProducts();
      expect(calls.last['p_expected_revision'], 4);
      expect(calls.last['p_product']['name'], 'FOTO DOS');
      expect(
        calls.last['p_product']['image_path'],
        isNot(firstImageRequest['p_product']['image_path']),
      );
      expect(await db.query('pending_owner_promos'), isEmpty);
      local =
          (await db.query('products', where: 'id = ?', whereArgs: [id])).single;
      expect(local['stock_revision'], 5);
      expect(local['synced'], 1);

      loseResponse = true;
      await repo.updatePromo(
        ProductEntity(
          id: id,
          name: 'ANTES DE REINICIAR',
          price: 37,
          cost: 9,
          stock: 0,
          isPromo: 1,
        ),
        {1: 2},
      );
      final requestBeforeRestart = Map<String, dynamic>.from(calls.last);
      final dbPath = db.path;
      SyncService().dispose();
      await db.close();
      db = await ffi.databaseFactoryFfi.openDatabase(
        dbPath,
        options: ffi.OpenDatabaseOptions(singleInstance: false),
      );
      final guard = SyncSessionGuard(
        Supabase.instance.client,
        PreferencesService(),
      );
      final session = guard.capture();
      final outbox = OwnerPromoOutbox(db, guard.require);
      final recovered = await outbox.prepare(session: session, productId: id);
      expect(recovered.requestId, requestBeforeRestart.remove('p_request_id'));
      expect(requestBeforeRestart.remove('p_billar_id'), 'A');
      expect(recovered.payload, requestBeforeRestart);
      final response = await Supabase.instance.client
          .rpc(
            'sync_owner_promo',
            params: {
              'p_request_id': recovered.requestId,
              'p_billar_id': session.billarId,
              ...recovered.payload,
            },
          )
          .setHeader('Authorization', 'Bearer ${session.token}');
      expect(response, 6);
      expect(
        await outbox.acknowledge(
          session: session,
          productId: id,
          request: recovered,
          revision: response as int,
        ),
        isTrue,
      );
      expect(await db.query('pending_owner_promos'), isEmpty);
      expect(
        (await db.query(
          'products',
          where: 'id = ?',
          whereArgs: [id],
        )).single['stock_revision'],
        6,
      );
    } finally {
      SyncService().dispose();
      await db.close();
      await Supabase.instance.dispose();
      mock.close();
      messenger.setMockMethodCallHandler(path, null);
      messenger.setMockMethodCallHandler(connectivity, null);
      messenger.setMockMethodCallHandler(events, null);
      await directory.delete(recursive: true);
    }
  });
}
