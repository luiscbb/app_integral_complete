import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/quick_sale/data/staff_quick_sale_outbox.dart';
import 'package:app_integral_complete/features/quick_sale/data/staff_quick_sale_reconciler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reconciliation is atomic, scoped and idempotent', () async {
    final directory = await Directory.systemTemp.createTemp('staff_reconcile_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
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
    Map<String, dynamic> receipt = {};
    var changedOnResponse = false;
    var billar = 'A';
    var receiptCalls = 0;
    var guardCalls = 0;
    int? failAtGuard;
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
      if (request.url.path == '/rest/v1/rpc/get_staff_sale_reconciliation') {
        receiptCalls++;
        expect(request.headers['authorization'], startsWith('Bearer '));
        expect(jsonDecode(request.body)['p_billar_id'], 'A');
        if (changedOnResponse) billar = 'B';
        return http.Response(
          jsonEncode(receipt),
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
    final db = await DatabaseHelper.instance.database;
    try {
      await client.auth.signInWithPassword(
        email: 'a@example.com',
        password: 'test',
      );
      final auth = client.auth.currentSession!;
      final SyncSession session = (
        actorId: actor,
        billarId: 'A',
        token: auth.accessToken,
        authSession: auth,
        scopeGeneration: 1,
      );
      void requireSession(SyncSession value) {
        guardCalls++;
        if (guardCalls == failAtGuard ||
            value.billarId != billar ||
            !identical(client.auth.currentSession, value.authSession)) {
          throw StateError('La sesión o el billar cambió.');
        }
      }

      for (final product in [
        {'id': 1, 'name': 'Uno', 'stock': 10, 'stock_revision': 2, 'synced': 1},
        {
          'id': 2,
          'name': 'Dos',
          'stock': 20,
          'stock_revision': 10,
          'synced': 0,
        },
        {
          'id': 100,
          'name': 'Promo',
          'stock': 0,
          'stock_revision': 1,
          'synced': 1,
        },
      ]) {
        await db.insert('products', {'billar_id': 'A', ...product});
      }
      final reservationId = await db.insert('temp_reservations', {
        'source': 'quick_sale',
        'source_id': 0,
        'product_id': 100,
        'quantity': 1,
        'created_at': '2026-01-01',
      });
      final outbox = StaffQuickSaleOutbox(db, requireSession);
      final pending = await outbox.prepare(
        session: session,
        saleDate: '2026-01-01',
        paymentMethod: 'Efectivo',
        total: 15,
        paid: 20,
        items: [
          const StaffQuickSaleItem(
            productId: 100,
            productName: 'Promo antigua',
            quantity: 1,
            price: 15,
          ),
        ],
      );
      await outbox.acknowledge(
        session: session,
        request: pending,
        remoteSaleId: 12,
      );
      receipt = {
        'request_id': pending.requestId,
        'billar_id': 'A',
        'sale_id': 12,
        'date': '2026-01-01',
        'payment_method': 'Efectivo',
        'total': 15,
        'paid': 20,
        'cancelled': false,
        'items': [
          {
            'product_id': 100,
            'product_name': 'Promo real',
            'quantity': 1,
            'price_at_sale': 15,
            'cancelled': false,
          },
        ],
        'stock': [
          {'product_id': 1, 'stock': 8, 'stock_revision': 3},
          {'product_id': 2, 'stock': 18, 'stock_revision': 9},
        ],
      };
      final reconciler = StaffQuickSaleReconciler(client, outbox);
      changedOnResponse = true;
      await expectLater(
        reconciler.reconcile(session: session, request: pending),
        throwsStateError,
      );
      billar = 'A';
      changedOnResponse = false;
      await expectLater(
        reconciler.reconcile(session: session, request: pending),
        throwsStateError,
      );
      expect(
        (await db.query(
          'products',
          where: 'id = ?',
          whereArgs: [1],
        )).single['stock'],
        10,
      );
      expect(await db.query('sales_history'), isEmpty);
      expect((await outbox.pending(session))!.remoteSaleId, 12);

      await db.update(
        'products',
        {'synced': 1},
        where: 'id = ?',
        whereArgs: [2],
      );
      receipt['sale_id'] = 999;
      await expectLater(
        reconciler.reconcile(session: session, request: pending),
        throwsStateError,
      );
      receipt['sale_id'] = 12;
      await db.update(
        'temp_reservations',
        {'quantity': 2},
        where: 'id = ?',
        whereArgs: [reservationId],
      );
      await expectLater(
        reconciler.reconcile(session: session, request: pending),
        throwsStateError,
      );
      expect((await db.query('temp_reservations')).single['quantity'], 2);
      await db.update(
        'temp_reservations',
        {'quantity': 1},
        where: 'id = ?',
        whereArgs: [reservationId],
      );

      final pulledId = await db.insert('sales_history', {
        'billar_id': 'A',
        'total': 15,
        'paid': 20,
        'date': '2026-01-01',
        'type': 'Venta Rápida',
        'source_module': 'quick_sale',
        'payment_method': 'Efectivo',
        'cancelled': 1,
        'synced': 1,
        'cloud_id': '12',
      });
      guardCalls = 0;
      failAtGuard = 7;
      await expectLater(
        reconciler.reconcile(session: session, request: pending),
        throwsStateError,
      );
      failAtGuard = null;
      expect((await db.query('products', where: 'id = 1')).single['stock'], 10);
      expect(await db.query('sale_details'), isEmpty);
      expect((await outbox.pending(session))!.remoteSaleId, 12);
      final localId = await reconciler.reconcile(
        session: session,
        request: pending,
      );
      expect(localId, pulledId);
      expect(
        await reconciler.reconcile(session: session, request: pending),
        localId,
      );
      expect(receiptCalls, 6);
      expect(await outbox.pending(session), isNull);
      expect(await db.query('sales_history'), hasLength(1));
      final details = await db.query('sale_details');
      expect(details, hasLength(1));
      expect(details.single['product_name'], 'Promo real');
      expect(details.single['cost_at_sale'], 0);
      expect(details.single['cost_available'], 0);
      expect(details.single['cancelled'], 1);
      final product1 = (await db.query('products', where: 'id = 1')).single;
      final product2 = (await db.query('products', where: 'id = 2')).single;
      expect(product1['stock'], 8);
      expect(product1['stock_revision'], 3);
      expect(product1['synced'], 1);
      expect(product2['stock'], 20);
      expect(product2['stock_revision'], 10);
      expect(await db.query('inventory_movements'), isEmpty);
      expect(await db.query('temp_reservations'), isEmpty);
      await db.insert('temp_reservations', {
        'source': 'quick_sale',
        'source_id': 0,
        'product_id': 100,
        'quantity': 1,
        'created_at': '2026-01-02',
      });
      expect(
        (await db.query('reconciled_staff_sales')).single['local_sale_id'],
        localId,
      );
      final next = await outbox.prepare(
        session: session,
        saleDate: '2026-01-02',
        paymentMethod: 'Efectivo',
        total: 15,
        paid: 20,
        items: [
          const StaffQuickSaleItem(
            productId: 100,
            productName: 'Promo antigua',
            quantity: 1,
            price: 15,
          ),
        ],
      );
      expect(next.requestId, isNot(pending.requestId));
      await outbox.acknowledge(
        session: session,
        request: next,
        remoteSaleId: 13,
      );
      receipt = {
        ...receipt,
        'request_id': next.requestId,
        'sale_id': 13,
        'date': '2026-01-02',
        'items': [
          {
            'product_id': 100,
            'product_name': 'Promo real',
            'quantity': 1,
            'price_at_sale': 15,
            'cancelled': false,
            'cost_at_sale': 3.5,
          },
        ],
        'stock': [
          {'product_id': 1, 'stock': 7, 'stock_revision': 4},
        ],
      };
      final nextId = await reconciler.reconcile(
        session: session,
        request: next,
      );
      final nextDetails =
          (await db.query(
            'sale_details',
            where: 'sale_id = ?',
            whereArgs: [nextId],
          )).single;
      expect(nextDetails['cost_at_sale'], 3.5);
      expect(nextDetails['cost_available'], 1);
    } finally {
      await db.close();
      await client.dispose();
      mock.close();
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    }
  });
}
