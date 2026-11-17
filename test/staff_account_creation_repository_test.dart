import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/features/auth/data/staff_account_creation_repository.dart';
import 'package:app_integral_complete/features/auth/data/staff_account_request_store.dart';
import 'package:app_integral_complete/features/auth/domain/staff_access.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'creation retries survive lost responses and cannot cross sessions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'staff_creation_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      final sent = <Map<String, dynamic>>[];
      final authorizations = <String?>[];
      var sessionCounter = 0;
      var mode = 'lost';
      Completer<void>? requestArrived;
      Completer<void>? releaseRequest;
      final httpClient = MockClient((request) async {
        if (request.url.path == '/auth/v1/token') {
          final email = (jsonDecode(request.body) as Map)['email'];
          final id = email == 'a@example.com' ? 'admin-a' : 'admin-b';
          final payload = base64Url
              .encode(
                utf8.encode(
                  jsonEncode({
                    'sub': id,
                    'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
                    'nonce': sessionCounter++,
                  }),
                ),
              )
              .replaceAll('=', '');
          return http.Response(
            jsonEncode({
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
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (request.url.path != '/functions/v1/player-admin') {
          throw StateError('Unexpected request: ${request.url.path}');
        }
        final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
        sent.add(body);
        authorizations.add(request.headers['authorization']);
        if (mode == 'lost') throw http.ClientException('response lost');
        if (mode == 'hold') {
          requestArrived!.complete();
          await releaseRequest!.future;
        }
        if (mode == 'error') {
          return http.Response(
            jsonEncode({'error': 'Ya no tienes permiso para crear personal.'}),
            403,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        return http.Response(
          jsonEncode({
            'staff': {
              'user_id': 'staff-1',
              'username': mode == 'invalid' ? 'otra-cuenta' : body['username'],
              'billar_id': body['billar_id'],
            },
            'password_available': mode != 'used' && mode != 'invalid-secret',
            if (mode != 'used') 'temporary_password': 'temporary-secret',
          }),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      final client = SupabaseClient(
        'http://localhost:54321',
        'test-key',
        httpClient: httpClient,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      Database? db;
      try {
        db = await DatabaseHelper.instance.database;
        final store = StaffAccountRequestStore(openDatabase: () async => db!);
        var billar = 'A';
        final repository = StaffAccountCreationRepository(
          client: client,
          requests: store,
          currentBillarId: () => billar,
        );
        Future<void> signIn(String email) async {
          await client.auth.signInWithPassword(email: email, password: 'test');
        }

        StaffAccountDraft draft(String username) => StaffAccountDraft(
          fullName: 'Ana',
          username: username,
          jobTitle: 'Caja',
          modules: {StaffModule.quickSale, StaffModule.inventory},
        );

        await signIn('a@example.com');
        final tokenA = client.auth.currentSession!.accessToken;
        await expectLater(repository.create(draft('cajero')), throwsStateError);
        final pending = (await repository.pending()).single;
        expect(sent.single['request_id'], pending.requestId);
        expect(sent.single['modules'], ['inventory', 'quick_sale']);
        expect(authorizations.single, 'Bearer $tokenA');
        expect(
          (await db.query('pending_staff_account_requests')).single.values,
          isNot(contains('temporary-secret')),
        );

        mode = 'invalid';
        await expectLater(
          repository.retry(pending.requestId),
          throwsStateError,
        );
        expect(await repository.pending(), hasLength(1));
        mode = 'error';
        await expectLater(
          repository.retry(pending.requestId),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'Ya no tienes permiso para crear personal.',
            ),
          ),
        );
        mode = 'success';
        final result = await repository.retry(pending.requestId);
        expect(result.temporaryPassword, 'temporary-secret');
        expect(sent.map((item) => item['request_id']).toSet(), {
          pending.requestId,
        });
        expect(await repository.pending(), hasLength(1));

        mode = 'invalid-secret';
        await expectLater(
          repository.retry(pending.requestId),
          throwsStateError,
        );
        mode = 'used';
        expect(
          (await repository.retry(pending.requestId)).temporaryPassword,
          isNull,
        );
        mode = 'success';

        requestArrived = Completer<void>();
        releaseRequest = Completer<void>();
        mode = 'hold';
        final inFlight = repository.create(draft('cajero2'));
        await requestArrived.future;
        final oldTokenHeader = authorizations.last;
        await signIn('b@example.com');
        releaseRequest.complete();
        await expectLater(inFlight, throwsStateError);
        expect(oldTokenHeader, 'Bearer $tokenA');
        expect(await repository.pending(), isEmpty);
        await expectLater(
          repository.retry(pending.requestId),
          throwsStateError,
        );
        await expectLater(repository.acknowledge(result), throwsStateError);

        await signIn('a@example.com');
        expect(await repository.pending(), hasLength(2));
        requestArrived = Completer<void>();
        releaseRequest = Completer<void>();
        mode = 'hold';
        final changedBillar = repository.retry(pending.requestId);
        await requestArrived.future;
        billar = 'B';
        releaseRequest.complete();
        await expectLater(changedBillar, throwsStateError);
        expect(await repository.pending(), isEmpty);
        billar = 'A';
        mode = 'success';
        final recovered = await repository.retry(pending.requestId);
        await repository.acknowledge(recovered);
        expect(await repository.pending(), hasLength(1));
      } finally {
        await client.dispose();
        httpClient.close();
        if (db?.isOpen == true) await db!.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
