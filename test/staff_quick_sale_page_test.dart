import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/quick_sale/data/staff_quick_sale_outbox.dart';
import 'package:app_integral_complete/features/quick_sale/data/staff_sale_cache.dart';
import 'package:app_integral_complete/features/quick_sale/presentation/controllers/staff_quick_sale_controller.dart';
import 'package:app_integral_complete/features/quick_sale/presentation/pages/staff_quick_sale_page.dart';
import 'package:flutter/material.dart';
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
  late StaffSaleCache cache;
  late StaffQuickSaleController controller;
  late List<Map<String, dynamic>> submissions;
  late Map<String, Map<String, dynamic>> remoteSales;
  var loseResponse = false;
  var membershipActive = true;
  var catalogCalls = 0;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('staff_sale_page_');
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    database = await DatabaseHelper.instance.database;
  });

  tearDownAll(() async {
    await database.close();
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  StaffQuickSaleController newController() => StaffQuickSaleController(
    client: client,
    cache: cache,
    captureSession: () => session,
  );

  setUp(() async {
    loseResponse = false;
    membershipActive = true;
    catalogCalls = 0;
    submissions = [];
    remoteSales = {};
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
      } else {
        expect(request.headers['authorization'], 'Bearer ${session.token}');
        if (request.url.path == '/rest/v1/business_memberships') {
          data = {
            'billar_id': 'A',
            'role': 'manager',
            'is_active': membershipActive,
            'must_change_password': false,
            'username': 'caja',
            'allowed_modules': ['quick_sale'],
          };
        } else if (request.url.path == '/rest/v1/rpc/staff_sale_products') {
          catalogCalls++;
          data = [
            {
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
            },
            {
              'id': 10,
              'billar_id': 'A',
              'name': 'Promocion',
              'price': 15,
              'stock': 5,
              'inventory_stock': 0,
              'stock_revision': 1,
              'is_promo': 1,
              'parent_id': null,
              'pieces_per_unit': 1,
              'components': [
                {'product_id': 1, 'quantity': 2},
              ],
            },
          ];
        } else if (request.url.path == '/rest/v1/rpc/record_staff_sale') {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          submissions.add(payload);
          final id = payload['p_request_id'] as String;
          final previous = remoteSales[id];
          if (previous != null) expect(payload, previous);
          remoteSales.putIfAbsent(id, () => payload);
          if (loseResponse) throw http.ClientException('Respuesta perdida');
          data = 12;
        } else if (request.url.path ==
            '/rest/v1/rpc/get_staff_sale_reconciliation') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final payload = remoteSales[body['p_request_id']]!;
          data = {
            'request_id': body['p_request_id'],
            'billar_id': 'A',
            'sale_id': 12,
            'date': payload['p_sale_date'],
            'payment_method': payload['p_payment_method'],
            'total': payload['p_total'],
            'paid': payload['p_paid'],
            'cancelled': false,
            'items': [
              for (final item in payload['p_items'] as List)
                {
                  ...item as Map<String, dynamic>,
                  'product_name': 'Producto confirmado',
                  'cancelled': false,
                },
            ],
            'stock': [
              {'product_id': 1, 'stock': 9, 'stock_revision': 2},
            ],
          };
        } else {
          throw StateError(
            'Unexpected request: ${request.method} ${request.url}',
          );
        }
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
    cache = StaffSaleCache(database, (expected) {
      if (!identical(client.auth.currentSession, expected.authSession) ||
          expected.actorId != actor ||
          expected.billarId != 'A' ||
          expected.scopeGeneration != 1) {
        throw StateError('La sesión o el billar cambió.');
      }
    });
    controller = newController();
    await database.insert('products', {
      'id': 1,
      'billar_id': 'A',
      'name': 'Inventario del administrador',
      'stock': 500,
      'cost': 77,
      'stock_revision': 100,
      'synced': 1,
    });
  });

  tearDown(() async {
    controller.dispose();
    await client.dispose();
    transport.close();
    for (final table in [
      'sale_details',
      'sales_history',
      'reconciled_staff_sales',
      'pending_staff_sales',
      'staff_sale_cart',
      'staff_sale_catalog',
      'products',
    ]) {
      await database.delete(table);
    }
  });

  Widget page({bool enabled = true}) => MaterialApp(
    home: StaffQuickSalePage(
      enableForIntegration: enabled,
      controller: controller,
    ),
  );

  Future<void> tapAndWait(WidgetTester tester, Finder target) async {
    await tester.runAsync(() async {
      await tester.tap(target);
      await tester.pump();
      await Future<void>.delayed(Duration.zero);
      await (() async {
        while (controller.busy) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          await tester.pump(const Duration(milliseconds: 10));
        }
      })().timeout(const Duration(seconds: 10));
    });
    await tester.pumpAndSettle();
  }

  Future<void> openCart(WidgetTester tester) async {
    await tester.runAsync(controller.load);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tapAndWait(tester, find.byKey(const ValueKey('add-1')));
    expect(controller.cart, {1: 1});
  }

  testWidgets('staff sale screen stays disabled by default', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: StaffQuickSalePage(controller: controller)),
    );
    expect(
      find.text('El acceso de personal aún no está habilitado.'),
      findsOneWidget,
    );
    expect(catalogCalls, 0);
    expect(submissions, isEmpty);
    expect(await tester.runAsync(() => cache.cart(session)), isEmpty);
  });

  testWidgets('screen confirms a sale using the receipt without owner writes', (
    tester,
  ) async {
    await openCart(tester);
    await tester.tap(find.text('COBRAR \$10.00'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'NaN');
    await tester.tap(find.text('CONFIRMAR'));
    await tester.pumpAndSettle();
    expect(find.text('Ingresa un monto válido.'), findsOneWidget);
    expect(submissions, isEmpty);
    await tester.enterText(find.byType(TextField), '20');
    await tapAndWait(tester, find.text('CONFIRMAR'));
    expect(find.text('Venta confirmada #12'), findsOneWidget);
    expect(controller.receipt!.items.single.productName, 'Producto confirmado');
    expect(controller.receipt!.paid, 20);
    expect(controller.cart, isEmpty);
    expect(
      (await tester.runAsync(
        () => cache.catalog(session),
      ))!.first.inventoryStock,
      9,
    );
    final owner =
        (await tester.runAsync(() => database.query('products')))!.single;
    expect(owner['stock'], 500);
    expect(owner['cost'], 77);
    expect(remoteSales, hasLength(1));
    expect(
      (await tester.runAsync(
        () => database.query('sale_details'),
      ))!.single['cost_available'],
      0,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'reopening a pending screen freezes the cart and recovers the same request',
    (tester) async {
      await openCart(tester);
      loseResponse = true;
      await tester.tap(find.text('COBRAR \$10.00'));
      await tester.pumpAndSettle();
      await tapAndWait(tester, find.text('CONFIRMAR'));
      expect(controller.error, isNotNull);
      final request = await tester.runAsync(
        () => StaffQuickSaleOutbox.staffCache(cache).pending(session),
      );
      expect(request, isNotNull);
      expect(
        await tester.runAsync(() => database.query('sales_history')),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      controller = newController();
      await tester.runAsync(controller.load);
      expect(catalogCalls, 1);
      expect(controller.pending, isTrue);
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('RECUPERAR VENTA'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('add-1')))
            .onPressed,
        isNull,
      );
      loseResponse = false;
      await tapAndWait(tester, find.text('RECUPERAR VENTA'));
      expect(find.text('Venta confirmada #12'), findsOneWidget);
      expect(remoteSales, hasLength(1));
      expect(submissions, hasLength(2));
      expect(submissions.first, submissions.last);
      expect(submissions.last['p_request_id'], request!.requestId);
      expect(await tester.runAsync(() => cache.cart(session)), isEmpty);
      expect(
        await tester.runAsync(() => database.query('sales_history')),
        hasLength(1),
      );
      expect(
        (await tester.runAsync(
          () => database.query('products'),
        ))!.single['stock'],
        500,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'payment rejects a changed cart even when its total is unchanged',
    (tester) async {
      await openCart(tester);
      await tester.runAsync(() => controller.setQuantity(1, 3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('COBRAR \$30.00'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await cache.saveCart(session, {10: 2});
        await controller.load();
      });
      expect(controller.total, 30);
      await tapAndWait(tester, find.text('CONFIRMAR'));
      expect(controller.error, contains('El carrito cambió'));
      expect(submissions, isEmpty);
      expect(
        await tester.runAsync(() => database.query('pending_staff_sales')),
        isEmpty,
      );
      expect(await tester.runAsync(() => cache.cart(session)), {10: 2});
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('revoked access cannot charge or expose the previous catalog', (
    tester,
  ) async {
    await openCart(tester);
    membershipActive = false;
    await tester.tap(find.text('COBRAR \$10.00'));
    await tester.pumpAndSettle();
    await tapAndWait(tester, find.text('CONFIRMAR'));
    expect(controller.error, isNotNull);
    expect(controller.ready, isFalse);
    expect(find.text('Producto'), findsNothing);
    expect(submissions, isEmpty);
    expect(await tester.runAsync(() => cache.cart(session)), {1: 1});
    expect(
      await tester.runAsync(() => database.query('pending_staff_sales')),
      isEmpty,
    );
    expect(
      await tester.runAsync(() => database.query('sales_history')),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
