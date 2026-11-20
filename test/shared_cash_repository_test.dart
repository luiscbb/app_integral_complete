import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/storage/account_storage.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/features/cash/data/repositories/shared_cash_repository.dart';
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
    'cash requests survive lost responses and are reconciled without a new id',
    () async {
      const actor = '00000000-0000-0000-0000-000000000001';
      final directory = await Directory.systemTemp.createTemp('shared_cash_');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      SharedPreferences.setMockInitialValues({});
      await PreferencesService().init();
      final requests = <Map<String, dynamic>>[];
      final committed = <String, Map<String, Object?>>{};
      var loseResponse = true;
      var deny = false;
      var foreignMovement = false;
      Database? openedDatabase;
      final transport = MockClient((request) async {
        Object? data;
        if (request.url.path == '/auth/v1/token') {
          final payload = base64Url
              .encode(
                utf8.encode(
                  jsonEncode({
                    'sub': actor,
                    'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
                  }),
                ),
              )
              .replaceAll('=', '');
          data = {
            'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'test',
            'user': {
              'id': actor,
              'aud': 'authenticated',
              'created_at': '2025-01-01T00:00:00Z',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
            },
          };
        } else if (request.url.path == '/rest/v1/rpc/cash_shared_apply') {
          final params = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(params);
          if (deny) {
            return http.Response(
              jsonEncode({'code': '42501', 'message': 'Sin permiso.'}),
              403,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          final id = params['requested_id'] as String;
          committed.putIfAbsent(
            id,
            () => {
              'billar_id': 'A',
              if (params['operation'] == 'cancel')
                'cancelled': true
              else
                'id': committed.length + 1,
            },
          );
          if (loseResponse) throw http.ClientException('Respuesta perdida.');
          data = committed[id];
        } else if (request.url.path == '/rest/v1/rpc/cash_shared_state') {
          data = {
            'billar_id': 'A',
            'session': null,
            'summary': <String, Object?>{},
            'sessions': [],
            'more_sessions': false,
            'more_movements': false,
            'movements': [
              {
                'id': 1,
                'billar_id': foreignMovement ? 'B' : 'A',
                'session_id': 1,
                'kind': 'contribution',
                'amount': 7,
                'description': 'Aporte',
                'payment_method': 'Efectivo',
                'created_by': actor,
                'created_at': '2030-01-15T12:00:00Z',
              },
            ],
          };
        } else {
          throw StateError(
            'Solicitud inesperada: ${request.method} ${request.url.path}',
          );
        }
        return http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      try {
        await Supabase.initialize(
          url: 'https://example.supabase.co',
          publishableKey: 'test-key',
          httpClient: transport,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        );
        await Supabase.instance.client.auth.signInWithPassword(
          email: 'a@example.test',
          password: 'test',
        );
        AccountStorage.initialize(Supabase.instance.client);
        await AccountStorage.instance.activate(
          billarId: 'A',
          migrateLegacyOwner: false,
        );
        openedDatabase = await DatabaseHelper.instance.database;
        final repo = SharedCashRepository();
        await expectLater(
          repo.openSession(openingAmount: 100),
          throwsA(isA<http.ClientException>()),
        );
        final first = await repo.pending();
        expect(first, isNotNull);
        final restarted = SharedCashRepository();
        expect(
          (await restarted.pending())?['request_id'],
          first!['request_id'],
        );
        await expectLater(
          restarted.openSession(openingAmount: 100),
          throwsStateError,
        );
        expect(requests, hasLength(1));
        loseResponse = false;
        await restarted.resolvePending(cancel: false);
        expect(requests[1]['requested_id'], requests[0]['requested_id']);
        expect(requests[1]['payload'], requests[0]['payload']);
        expect(committed, hasLength(1));
        expect(await restarted.pending(), isNull);

        loseResponse = true;
        await expectLater(
          restarted.addMovement(
            sessionId: 1,
            kind: 'contribution',
            amount: 7,
            description: 'Aporte',
          ),
          throwsA(isA<http.ClientException>()),
        );
        loseResponse = false;
        await restarted.resolvePending(cancel: true);
        expect(committed, hasLength(2));
        expect(await restarted.pending(), isNull);
        expect(requests.last['operation'], 'cancel');

        deny = true;
        await expectLater(
          restarted.openSession(openingAmount: 0),
          throwsA(isA<PostgrestException>()),
        );
        expect(await restarted.pending(), isNull);
        deny = false;
        foreignMovement = true;
        await expectLater(
          restarted.state(DateTime.utc(2030, 1), DateTime.utc(2030, 2)),
          throwsFormatException,
        );
        final db = await DatabaseHelper.instance.database;
        expect(await db.query('cash_shared_movement_cache'), isEmpty);
        foreignMovement = false;
        await restarted.state(DateTime.utc(2030, 1), DateTime.utc(2030, 2));
        await restarted.state(DateTime.utc(2030, 1), DateTime.utc(2030, 2));
        final cached = await db.query('cash_shared_movement_cache');
        expect(cached, hasLength(1));
        expect(cached.single['amount'], 7);
        AccountStorage.instance.retire();
        await expectLater(restarted.pending(), throwsStateError);
      } finally {
        await openedDatabase?.close();
        await AccountStorage.instance.dispose();
        await Supabase.instance.dispose();
        transport.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
