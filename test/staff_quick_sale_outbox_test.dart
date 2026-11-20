import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/quick_sale/data/staff_quick_sale_outbox.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('staff sale survives uncertain response and database reopening', () async {
    final directory = await Directory.systemTemp.createTemp('staff_sales_');
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
        version: 46,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE providers (id INTEGER PRIMARY KEY)');
          await db.execute('CREATE TABLE purchases (id INTEGER PRIMARY KEY)');
          await db.execute('CREATE TABLE existing_data (value TEXT)');
          await db.insert('existing_data', {'value': 'preserved'});
          await db.execute(
            'CREATE TABLE sale_details (id INTEGER PRIMARY KEY)',
          );
          await db.execute(
            'CREATE TABLE products (id INTEGER PRIMARY KEY, billar_id TEXT NOT NULL)',
          );
          await db.execute('''
              CREATE TABLE temp_reservations (
                id INTEGER PRIMARY KEY, source TEXT NOT NULL, source_id INTEGER NOT NULL,
                source_key TEXT, product_id INTEGER NOT NULL, quantity REAL NOT NULL,
                created_at TEXT NOT NULL
              )
            ''');
          await db.insert('products', {'id': 1, 'billar_id': 'A'});
          await db.insert('temp_reservations', {
            'source': 'quick_sale',
            'source_id': 0,
            'product_id': 1,
            'quantity': 1,
            'created_at': '2026-01-01',
          });
          await db.execute('''
              CREATE TABLE pending_staff_sales (
                actor_id TEXT NOT NULL, billar_id TEXT NOT NULL,
                request_id TEXT NOT NULL UNIQUE, payload TEXT NOT NULL,
                remote_sale_id INTEGER, PRIMARY KEY (actor_id, billar_id)
              )
            ''');
          await db.insert('pending_staff_sales', {
            'actor_id': 'other',
            'billar_id': 'A',
            'request_id': 'old',
            'payload': '{}',
            'remote_sale_id': 12,
          });
        },
      ),
    );
    await previous.close();

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
    final submitted = <Map<String, dynamic>>[];
    var failResponse = true;
    var changeScopeOnResponse = false;
    var currentBillar = 'A';
    final mock = MockClient((request) async {
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
      if (request.url.path == '/rest/v1/rpc/record_staff_sale') {
        expect(request.headers['authorization'], startsWith('Bearer '));
        submitted.add(jsonDecode(request.body) as Map<String, dynamic>);
        if (failResponse) throw http.ClientException('Lost response');
        if (changeScopeOnResponse) currentBillar = 'B';
        return http.Response(
          '12',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      throw StateError('Unexpected request: ${request.url.path}');
    });
    final client = SupabaseClient(
      'http://localhost:54321',
      'key',
      httpClient: mock,
    );
    var db = await DatabaseHelper.instance.database;
    try {
      expect((await db.query('existing_data')).single['value'], 'preserved');
      expect(
        (await db.query('pending_staff_sales')).single['remote_sale_id'],
        12,
      );
      expect(await db.query('reconciled_staff_sales'), isEmpty);
      expect(await db.getVersion(), 61);
      await client.auth.signInWithPassword(
        email: 'a@example.com',
        password: 'test',
      );
      final auth = client.auth.currentSession!;
      SyncSession session = (
        actorId: actor,
        billarId: 'A',
        token: auth.accessToken,
        authSession: auth,
        scopeGeneration: 1,
      );
      void requireSession(SyncSession value) {
        if (value.billarId != currentBillar ||
            !identical(client.auth.currentSession, value.authSession)) {
          throw StateError('La sesión o el billar cambió.');
        }
      }

      var outbox = StaffQuickSaleOutbox(db, requireSession);
      const item = StaffQuickSaleItem(
        productId: 1,
        productName: 'Producto',
        quantity: 1,
        price: 10,
      );
      Future<PendingStaffQuickSale> prepare({double paid = 10}) =>
          outbox.prepare(
            session: session,
            saleDate: '2026-01-01',
            paymentMethod: 'Efectivo',
            total: 10,
            paid: paid,
            items: [item],
          );
      await expectLater(
        outbox.prepare(
          session: session,
          saleDate: '2026-01-01',
          paymentMethod: 'Efectivo',
          total: 9,
          paid: 10,
          items: [item],
        ),
        throwsArgumentError,
      );
      expect(await outbox.pending(session), isNull);
      final attempts = await Future.wait([prepare(), prepare()]);
      expect(attempts[0].requestId, attempts[1].requestId);
      await expectLater(prepare(paid: 20), throwsStateError);
      final sender = StaffQuickSaleSender(client, outbox);
      await db.update('temp_reservations', {'quantity': 2});
      await expectLater(
        sender.send(session: session, request: attempts.first),
        throwsStateError,
      );
      expect(submitted, isEmpty);
      await db.update('temp_reservations', {'quantity': 1});
      await expectLater(
        sender.send(session: session, request: attempts.first),
        throwsA(isA<http.ClientException>()),
      );
      expect((await outbox.pending(session))!.remoteSaleId, isNull);
      await db.close();
      db = await ffi.databaseFactoryFfi.openDatabase(dbPath);
      outbox = StaffQuickSaleOutbox(db, requireSession);
      final recovered = (await outbox.pending(session))!;
      expect(recovered.requestId, attempts.first.requestId);
      failResponse = false;
      final resumed = StaffQuickSaleSender(client, outbox);
      changeScopeOnResponse = true;
      await expectLater(
        resumed.send(session: session, request: recovered),
        throwsStateError,
      );
      currentBillar = 'A';
      changeScopeOnResponse = false;
      expect((await outbox.pending(session))!.remoteSaleId, isNull);
      expect(await resumed.send(session: session, request: recovered), 12);
      expect(submitted, hasLength(3));
      expect(submitted[0], submitted[1]);
      expect(submitted[0], submitted[2]);
      expect(submitted[0]['p_request_id'], recovered.requestId);
      expect(submitted[0]['p_billar_id'], 'A');
      expect((await outbox.pending(session))!.remoteSaleId, 12);
      expect(await resumed.send(session: session, request: recovered), 12);
      expect(submitted, hasLength(3));
      await expectLater(
        outbox.acknowledge(
          session: session,
          request: recovered,
          remoteSaleId: 13,
        ),
        throwsStateError,
      );
      currentBillar = 'B';
      await expectLater(outbox.pending(session), throwsStateError);
      final otherSession = (
        actorId: actor,
        billarId: 'B',
        token: auth.accessToken,
        authSession: auth,
        scopeGeneration: 1,
      );
      expect(await outbox.pending(otherSession), isNull);
      await expectLater(
        outbox.acknowledge(
          session: otherSession,
          request: recovered,
          remoteSaleId: 12,
        ),
        throwsStateError,
      );
    } finally {
      await db.close();
      await client.dispose();
      mock.close();
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    }
  });
}
