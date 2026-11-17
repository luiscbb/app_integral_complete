import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/quick_sale/data/staff_quick_sale_checkout.dart';
import 'package:app_integral_complete/features/quick_sale/data/staff_quick_sale_outbox.dart';
import 'package:app_integral_complete/features/quick_sale/data/staff_sale_cache.dart';
import 'package:app_integral_complete/features/quick_sale/domain/entities/staff_sale_product.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const actor = '00000000-0000-0000-0000-000000000001';
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late Database database;
  late SupabaseClient client;
  late MockClient transport;
  late SyncSession session;
  late StaffQuickSaleOutbox outbox;
  late StaffQuickSaleCheckout checkout;
  late StaffSaleCache cache;
  late Map<String, Object?> membership;
  late List<Map<String, dynamic>> submissions;
  var loseSaleResponse = false;
  var loseReceiptResponse = false;
  var membershipOffline = false;
  var changeScopeOnMembership = false;
  var currentBillar = 'A';
  var receiptCalls = 0;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('staff_checkout_');
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    database = await DatabaseHelper.instance.database;
  });

  tearDownAll(() async {
    await database.close();
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  setUp(() async {
    membership = {
      'billar_id': 'A',
      'role': 'manager',
      'is_active': true,
      'must_change_password': false,
      'username': 'caja',
      'allowed_modules': ['quick_sale'],
    };
    submissions = [];
    loseSaleResponse = false;
    loseReceiptResponse = false;
    membershipOffline = false;
    changeScopeOnMembership = false;
    currentBillar = 'A';
    receiptCalls = 0;
    transport = MockClient((request) async {
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
            'app_metadata': {'account_type': 'staff', 'billar_id': 'A'},
            'user_metadata': <String, dynamic>{},
            'created_at': '2025-01-01T00:00:00Z',
          },
        };
      } else if (request.url.path == '/rest/v1/business_memberships') {
        expect(request.url.queryParameters['user_id'], 'eq.$actor');
        expect(request.url.queryParameters['billar_id'], 'eq.A');
        if (membershipOffline) throw http.ClientException('Sin conexión');
        if (changeScopeOnMembership) currentBillar = 'B';
        data = membership;
      } else if (request.url.path == '/rest/v1/rpc/record_staff_sale') {
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        submissions.add(payload);
        if (loseSaleResponse) throw http.ClientException('Respuesta perdida');
        data = 12;
      } else if (request.url.path ==
          '/rest/v1/rpc/get_staff_sale_reconciliation') {
        receiptCalls++;
        if (loseReceiptResponse) {
          throw http.ClientException('Respuesta perdida');
        }
        final requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        final sale = submissions.last;
        data = {
          'request_id': requestBody['p_request_id'],
          'billar_id': 'A',
          'sale_id': 12,
          'date': sale['p_sale_date'],
          'payment_method': sale['p_payment_method'],
          'total': sale['p_total'],
          'paid': sale['p_paid'],
          'cancelled': false,
          'items': [
            {
              'product_id': 1,
              'product_name': 'Producto',
              'quantity': 1,
              'price_at_sale': 10,
              'cancelled': false,
            },
          ],
          'stock': [
            {'product_id': 1, 'stock': 9, 'stock_revision': 2},
          ],
        };
      } else {
        throw StateError('Unexpected request: ${request.url.path}');
      }
      if (request.url.path != '/auth/v1/token') {
        expect(request.headers['authorization'], 'Bearer ${session.token}');
      }
      return http.Response(
        jsonEncode(data),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      httpClient: transport,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    await client.auth.signInWithPassword(
      email: 'caja@example.test',
      password: 'test',
    );
    final auth = client.auth.currentSession!;
    session = (
      actorId: actor,
      billarId: 'A',
      token: auth.accessToken,
      authSession: auth,
      scopeGeneration: 1,
    );
    void requireSession(SyncSession expected) {
      if (expected.billarId != currentBillar ||
          expected.actorId != client.auth.currentUser?.id ||
          !identical(expected.authSession, client.auth.currentSession)) {
        throw StateError('La sesión o el billar cambió.');
      }
    }

    cache = StaffSaleCache(database, requireSession);
    outbox = StaffQuickSaleOutbox.staffCache(cache);
    checkout = StaffQuickSaleCheckout(client, outbox);
    await cache.replaceCatalog(session, [
      StaffSaleProduct.fromMap({
        'id': 1,
        'billar_id': 'A',
        'name': 'Producto',
        'price': 10,
        'stock': 10,
        'inventory_stock': 10,
        'stock_revision': 1,
        'is_promo': 0,
        'parent_id': null,
        'pieces_per_unit': 1,
        'components': [],
      }, billarId: 'A'),
    ]);
    await cache.saveCart(session, {1: 1});
    await database.insert('products', {
      'id': 1,
      'billar_id': 'A',
      'name': 'Producto',
      'stock': 10,
      'stock_revision': 1,
      'synced': 1,
    });
    await database.insert('temp_reservations', {
      'source': 'quick_sale',
      'source_id': 0,
      'product_id': 1,
      'quantity': 1,
      'created_at': '2026-01-01',
    });
  });

  tearDown(() async {
    await client.dispose();
    transport.close();
    await database.transaction((txn) async {
      for (final table in [
        'sale_details',
        'reconciled_staff_sales',
        'pending_staff_sales',
        'sales_history',
        'temp_reservations',
        'products',
        'staff_sale_cart',
        'staff_sale_catalog',
      ]) {
        await txn.delete(table);
      }
    });
  });

  Future<int> charge() => checkout.checkout(
    session: session,
    saleDate: '2026-01-01',
    paymentMethod: 'Efectivo',
    total: 10,
    paid: 20,
    items: [
      const StaffQuickSaleItem(
        productId: 1,
        productName: 'Producto',
        quantity: 1,
        price: 10,
      ),
    ],
  );

  test(
    'checkout saves the canonical receipt without decrementing twice',
    () async {
      final localId = await charge();
      expect(submissions, hasLength(1));
      expect(submissions.single['p_billar_id'], 'A');
      final sale = (await database.query('sales_history')).single;
      expect(sale['id'], localId);
      expect(sale['cloud_id'], '12');
      expect(sale['total'], 10);
      expect(sale['paid'], 20);
      expect(sale['synced'], 1);
      expect((await cache.catalog(session)).single.inventoryStock, 9);
      expect((await database.query('products')).single['stock'], 10);
      expect(
        (await database.query('sale_details')).single['cost_available'],
        0,
      );
      expect(await cache.cart(session), isEmpty);
      expect(await database.query('temp_reservations'), hasLength(1));
      expect(await database.query('pending_staff_sales'), isEmpty);
      expect(await database.query('reconciled_staff_sales'), hasLength(1));
    },
  );

  test(
    'checkout recovers lost responses without a second local sale',
    () async {
      loseSaleResponse = true;
      await expectLater(charge(), throwsA(isA<http.ClientException>()));
      final original = (await outbox.pending(session))!;
      expect(await database.query('sales_history'), isEmpty);
      expect(await cache.cart(session), {1: 1});

      loseSaleResponse = false;
      loseReceiptResponse = true;
      await expectLater(
        checkout.recover(session),
        throwsA(isA<http.ClientException>()),
      );
      expect(submissions, hasLength(2));
      expect(submissions.first, submissions.last);
      expect(submissions.last['p_request_id'], original.requestId);
      expect((await outbox.pending(session))!.remoteSaleId, 12);
      expect(await database.query('sales_history'), isEmpty);

      loseReceiptResponse = false;
      final localId = await checkout.recover(session);
      expect(submissions, hasLength(2));
      expect((await database.query('sales_history')).single['id'], localId);
      expect(await database.query('sale_details'), hasLength(1));
      expect((await cache.catalog(session)).single.inventoryStock, 9);
      expect((await database.query('products')).single['stock'], 10);
      expect(await cache.cart(session), isEmpty);
      expect(await outbox.pending(session), isNull);
      expect(await checkout.recover(session), isNull);
      expect(receiptCalls, 2);
    },
  );

  test('checkout and recovery reject revoked or unavailable access', () async {
    final valid = Map<String, Object?>.from(membership);
    for (final change in [
      {'is_active': false},
      {'must_change_password': true},
      {'role': 'admin'},
      {'billar_id': 'B'},
      {
        'allowed_modules': ['reports'],
      },
    ]) {
      membership = {...valid, ...change};
      await expectLater(charge(), throwsStateError);
      expect(await outbox.pending(session), isNull);
      expect(submissions, isEmpty);
    }
    membership = valid;
    loseSaleResponse = true;
    await expectLater(charge(), throwsA(isA<http.ClientException>()));
    final pending = (await outbox.pending(session))!;
    membership['is_active'] = false;
    await expectLater(checkout.recover(session), throwsStateError);
    expect(submissions, hasLength(1));
    expect((await outbox.pending(session))!.requestId, pending.requestId);
    expect(await database.query('temp_reservations'), hasLength(1));

    membership['is_active'] = true;
    membershipOffline = true;
    await expectLater(
      checkout.recover(session),
      throwsA(isA<http.ClientException>()),
    );
    expect(submissions, hasLength(1));
    expect(await database.query('sales_history'), isEmpty);
  });

  test('a scope change during authorization cannot prepare a sale', () async {
    changeScopeOnMembership = true;
    await expectLater(charge(), throwsStateError);
    expect(await database.query('pending_staff_sales'), isEmpty);
    expect(await database.query('sales_history'), isEmpty);
    expect(submissions, isEmpty);
    expect(await database.query('temp_reservations'), hasLength(1));
  });
}
