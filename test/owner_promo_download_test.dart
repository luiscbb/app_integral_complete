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
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'downloads coherent promo snapshots without overwriting local changes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'promo_download_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      SharedPreferences.setMockInitialValues({'billar_id': 'A'});
      await PreferencesService().init();
      const actor = '00000000-0000-0000-0000-000000000001';
      final jwt = base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'sub': actor,
                'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
              }),
            ),
          )
          .replaceAll('=', '');
      final child = <String, dynamic>{
        'id': 1,
        'billar_id': 'A',
        'name': 'PRODUCTO',
        'price': 5,
        'cost': 2,
        'stock': 10,
        'stock_revision': 1,
        'is_promo': 0,
        'parent_id': null,
        'pieces_per_unit': 1,
        'is_active': true,
      };
      final promo = <String, dynamic>{
        'id': 10,
        'billar_id': 'A',
        'name': 'PROMO',
        'price': 20,
        'cost': 4,
        'stock': 0,
        'stock_revision': 1,
        'is_promo': 1,
        'parent_id': null,
        'pieces_per_unit': 1,
        'is_active': true,
      };
      var components = <Map<String, int>>[
        {'child_id': 1, 'quantity': 2},
      ];
      var invalidResponse = false;
      Completer<void>? started;
      Completer<void>? release;
      final mock = MockClient((request) async {
        const headers = {'content-type': 'application/json'};
        if (request.url.path == '/auth/v1/token') {
          return http.Response(
            jsonEncode({
              'access_token': 'eyJhbGciOiJub25lIn0.$jwt.signature',
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
            headers: headers,
            request: request,
          );
        }
        if (request.url.path == '/rest/v1/products') {
          return http.Response(
            jsonEncode([
              child,
              {...promo, 'price': 1, 'stock_revision': 0},
            ]),
            200,
            headers: headers,
            request: request,
          );
        }
        if (request.url.path == '/rest/v1/rpc/read_owner_promo_snapshot') {
          expect(request.headers['authorization'], startsWith('Bearer '));
          expect(jsonDecode(request.body), {
            'p_billar_id': 'A',
            'p_product_id': 10,
          });
          final response = jsonEncode({
            'product': promo,
            'components': invalidResponse ? [] : components,
          });
          if (started != null && !started!.isCompleted) {
            started!.complete();
            await release!.future;
            started = null;
            release = null;
          }
          return http.Response(
            response,
            200,
            headers: headers,
            request: request,
          );
        }
        throw StateError('Unexpected request: ${request.url.path}');
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
      final db = await DatabaseHelper.instance.database;
      try {
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.com',
          password: 'test',
        );
        final repo = ProductRepository(atomicPromoSync: true);
        final first = await repo.refreshFromCloud();
        expect(first.singleWhere((p) => p.id == 10).stock, 5);
        expect(
          (await db.query('products', where: 'id = 10')).single['price'],
          20,
        );
        expect(await repo.getPromoComponents(10), {1: 2});

        promo['stock_revision'] = 2;
        promo['price'] = 30;
        promo['barcode'] = 'CODE-2';
        components = [
          {'child_id': 1, 'quantity': 3},
        ];
        await db.update('products', {
          'name': 'LOCAL',
          'synced': 0,
        }, where: 'id = 10');
        await db.update('promo_items', {
          'quantity': 4,
        }, where: 'parent_id = 10');
        await repo.refreshFromCloud();
        expect(
          (await db.query('products', where: 'id = 10')).single['name'],
          'LOCAL',
        );
        expect(await repo.getPromoComponents(10), {1: 4});

        await db.update('products', {
          'synced': 1,
          'stock_revision': 5,
        }, where: 'id = 10');
        await repo.refreshFromCloud();
        expect(
          (await db.query(
            'products',
            where: 'id = 10',
          )).single['stock_revision'],
          5,
        );
        expect(await repo.getPromoComponents(10), {1: 4});

        await db.update('products', {'stock_revision': 1}, where: 'id = 10');
        started = Completer<void>();
        release = Completer<void>();
        final refresh = repo.refreshFromCloud();
        await started!.future;
        await db.update('products', {
          'name': 'EDICION',
          'synced': 0,
        }, where: 'id = 10');
        release!.complete();
        await refresh;
        expect(
          (await db.query('products', where: 'id = 10')).single['name'],
          'EDICION',
        );
        expect(await repo.getPromoComponents(10), {1: 4});

        await db.update('products', {'synced': 1}, where: 'id = 10');
        await repo.refreshFromCloud();
        expect(
          (await db.query('products', where: 'id = 10')).single['price'],
          30,
        );
        expect(await repo.getPromoComponents(10), {1: 3});
        expect(
          (await db.query('products', where: 'id = 10')).single['barcode'],
          'CODE-2',
        );

        started = Completer<void>();
        release = Completer<void>();
        final olderRefresh = repo.refreshFromCloud();
        await started!.future;
        promo['stock_revision'] = 3;
        promo['price'] = 40;
        components = [
          {'child_id': 1, 'quantity': 1},
        ];
        await repo.refreshFromCloud();
        expect(await repo.getPromoComponents(10), {1: 1});
        release!.complete();
        await olderRefresh;
        expect(
          (await db.query('products', where: 'id = 10')).single['price'],
          40,
        );
        expect(await repo.getPromoComponents(10), {1: 1});

        await db.insert('pending_owner_promos', {
          'product_id': 10,
          'actor_id': actor,
          'billar_id': 'A',
          'is_new': 0,
        });
        promo['stock_revision'] = 4;
        promo['price'] = 50;
        await repo.refreshFromCloud();
        expect(
          (await db.query('products', where: 'id = 10')).single['price'],
          40,
        );
        await db.delete('pending_owner_promos', where: 'product_id = 10');

        invalidResponse = true;
        await expectLater(repo.refreshFromCloud(), throwsStateError);
        expect(await repo.getPromoComponents(10), {1: 1});
        invalidResponse = false;
        components = [
          {'child_id': 999, 'quantity': 1},
        ];
        promo['stock_revision'] = 4;
        await expectLater(repo.refreshFromCloud(), throwsStateError);
        expect(
          (await db.query(
            'products',
            where: 'id = 10',
          )).single['stock_revision'],
          3,
        );
        expect(await repo.getPromoComponents(10), {1: 1});

        components = [
          {'child_id': 1, 'quantity': 1},
        ];
        started = Completer<void>();
        release = Completer<void>();
        final changedSession = repo.refreshFromCloud();
        await started!.future;
        await PreferencesService().setBillarId('B');
        release!.complete();
        await expectLater(changedSession, throwsStateError);
        expect(
          (await db.query(
            'products',
            where: 'id = 10',
          )).single['stock_revision'],
          3,
        );
        expect(await repo.getPromoComponents(10), {1: 1});
      } finally {
        await db.close();
        await Supabase.instance.dispose();
        mock.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
