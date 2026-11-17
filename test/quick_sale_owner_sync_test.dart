import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/features/quick_sale/data/quick_sale_local_data_source.dart'
    as local;
import 'package:app_integral_complete/features/quick_sale/data/quick_sale_repository_impl.dart';
import 'package:app_integral_complete/features/quick_sale/domain/entities/pending_sale.dart';
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
    'pending quick sales keep their account and survive session changes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'quick_sale_owner_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      SharedPreferences.setMockInitialValues({'billar_id': 'A'});
      await PreferencesService().init();
      const first = '00000000-0000-0000-0000-000000000001';
      const second = '00000000-0000-0000-0000-000000000002';
      final uploads = <Map<String, dynamic>>[];
      final tokens = <String?>[];
      final started = Completer<void>();
      final resume = Completer<void>();
      var pause = true;
      final client = MockClient((request) async {
        Object data = [];
        if (request.url.path == '/auth/v1/token') {
          final email = (jsonDecode(request.body) as Map)['email'];
          final id = email == 'b@example.com' ? second : first;
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
        } else if (request.url.path == '/rest/v1/pending_sales' &&
            request.method == 'POST') {
          uploads.add(
            Map<String, dynamic>.from(jsonDecode(request.body) as Map),
          );
          tokens.add(request.headers['authorization']);
          if (pause) {
            pause = false;
            started.complete();
            await resume.future;
          }
        } else {
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
        final supabase = Supabase.instance.client;
        Future<void> signIn(String email) => supabase.auth
            .signInWithPassword(email: email, password: 'test')
            .then((_) {});
        await signIn('a@example.com');
        final token = supabase.auth.currentSession!.accessToken;
        db = await DatabaseHelper.instance.database;
        Future<int> insertSale(String product, String? actor, String? billar) =>
            db!.insert('pending_sales', {
              'product': product,
              'actor_id': actor,
              'billar_id': billar,
              'quantity': 1,
              'price': 10.0,
              'created_at': '2026-01-01T10:00:00',
              'synced': 0,
            });
        final firstId = await insertSale('A', first, 'A');
        final secondId = await insertSale('B', second, 'A');
        final otherBusinessId = await insertSale('OTRO', first, 'B');
        final legacyId = await insertSale('ANTERIOR', null, null);
        final repository = QuickSaleRepositoryImpl();
        expect(await repository.pendingSyncCount(), 1);
        final interrupted = repository.syncPendingSales();
        await started.future.timeout(const Duration(seconds: 5));
        await signIn('b@example.com');
        resume.complete();
        await interrupted;
        expect(tokens.single, 'Bearer $token');
        expect(
          (await db.query(
            'pending_sales',
            where: 'id = ?',
            whereArgs: [firstId],
          )).single['synced'],
          0,
        );
        final clientId = uploads.first['client_id'];
        expect(clientId, isNotNull);
        expect(uploads.first['created_at'], '2026-01-01T10:00:00');
        await repository.syncPendingSales();
        expect(uploads.map((row) => row['product']), ['A', 'B']);
        expect(
          (await db.query(
            'pending_sales',
            where: 'id = ?',
            whereArgs: [secondId],
          )).single['synced'],
          1,
        );
        await expectLater(
          local.QuickSaleLocalDataSource().markPendingSaleSynced(firstId),
          throwsStateError,
        );
        await signIn('a@example.com');
        await repository.syncPendingSales();
        expect(uploads.map((row) => row['product']), ['A', 'B', 'A']);
        expect(uploads.last['client_id'], clientId);
        expect(
          (await db.query(
            'pending_sales',
            where: 'id = ?',
            whereArgs: [firstId],
          )).single['synced'],
          1,
        );
        expect(
          (await db.query(
            'pending_sales',
            where: 'id = ?',
            whereArgs: [otherBusinessId],
          )).single['synced'],
          0,
        );
        final legacy =
            (await db.query(
              'pending_sales',
              where: 'id = ?',
              whereArgs: [legacyId],
            )).single;
        expect(legacy['synced'], 0);
        expect(legacy['actor_id'], isNull);
        expect(legacy['billar_id'], isNull);
        await local.QuickSaleLocalDataSource().savePendingSale(
          PendingSale(
            product: 'NUEVA',
            quantity: 1,
            price: 5,
            createdAt: DateTime(2026, 1, 1),
            synced: false,
          ),
        );
        final saved =
            (await db.query(
              'pending_sales',
              where: 'product = ?',
              whereArgs: ['NUEVA'],
            )).single;
        expect(saved['actor_id'], first);
        expect(saved['billar_id'], 'A');
        await signIn('b@example.com');
        expect(
          await local.QuickSaleLocalDataSource().loadPendingSales(),
          isEmpty,
        );
      } finally {
        await Supabase.instance.dispose();
        await db?.close();
        client.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
