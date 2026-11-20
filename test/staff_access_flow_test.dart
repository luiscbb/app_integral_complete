import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/routes/app_router.dart';
import 'package:app_integral_complete/core/routes/app_routes.dart';
import 'package:app_integral_complete/core/storage/account_storage.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/core/theme/theme_provider.dart';
import 'package:app_integral_complete/features/auth/domain/staff_access.dart';
import 'package:app_integral_complete/features/auth/presentation/pages/login_page.dart';
import 'package:app_integral_complete/features/home/presentation/pages/staff_home_page.dart';
import 'package:app_integral_complete/features/home/presentation/widgets/home_header.dart';
import 'package:app_integral_complete/core/widgets/module_card.dart';
import 'package:app_integral_complete/features/inventory/presentation/pages/staff_inventory_page.dart';
import 'package:app_integral_complete/features/quick_sale/presentation/pages/staff_quick_sale_page.dart';
import 'package:app_integral_complete/features/purchases/presentation/pages/staff_purchases_page.dart';
import 'package:app_integral_complete/features/reports/presentation/pages/staff_reports_page.dart';
import 'package:app_integral_complete/features/sales/presentation/pages/billiard_tables_page.dart';
import 'package:app_integral_complete/features/sales/presentation/pages/staff_table_service_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets(
    'staff integration enforces password, portal permissions and default route gates',
    (tester) async {
      const actor = '00000000-0000-4000-8000-000000000001';
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final directory =
          (await tester.runAsync(
            () => Directory.systemTemp.createTemp('staff_access_flow_'),
          ))!;
      messenger.setMockMethodCallHandler(
        pathChannel,
        (_) async => directory.path,
      );
      SharedPreferences.setMockInitialValues({
        'billar_id': 'ORIGINAL',
        'business_name': 'NEGOCIO ORIGINAL',
      });
      final preferences = PreferencesService();
      await tester.runAsync(preferences.init);
      final rawPreferences =
          (await tester.runAsync(SharedPreferences.getInstance))!;
      var pending = true;
      var modules = ['quick_sale', 'reports'];
      var enableIntegration = true;
      var edgeCalls = 0;
      var catalogCalls = 0;
      var membershipCalls = 0;
      var purchaseReads = 0;
      var denyInventory = false;
      var invalidInventoryResponse = false;
      var brandingBillar = 'A';
      var reportCalls = 0;
      var serviceOpenCalls = 0;
      var serviceConsumptionCalls = 0;
      var conflictListCalls = 0;
      var conflictConsumptionCalls = 0;
      var openingReviewCalls = 0;
      var activeServiceId = '';
      var activeServiceOpenedAt = '';
      var serviceItems = <Map<String, dynamic>>[];
      final navigator = GlobalKey<NavigatorState>();
      Database? database;
      final transport = MockClient((request) async {
        Object? data;
        if (request.url.path == '/auth/v1/token') {
          expectSync(
            jsonDecode(request.body)['email'],
            '63616a61@staff.baumar.invalid',
          );
          expectSync(jsonDecode(request.body)['password'], '  temporal123  ');
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
              'user_metadata': {'full_name': 'Personal'},
              'created_at': '2025-01-01T00:00:00Z',
            },
          };
        } else if (request.url.path == '/auth/v1/logout') {
          return http.Response('', 204, request: request);
        } else if (request.url.path == '/rest/v1/business_memberships') {
          membershipCalls++;
          expectSync(request.url.queryParameters['user_id'], 'eq.$actor');
          expectSync(request.url.queryParameters['billar_id'], 'eq.A');
          data = {
            'billar_id': 'A',
            'role': 'manager',
            'is_active': true,
            'username': 'caja',
            'must_change_password': pending,
            'allowed_modules': modules,
          };
        } else if (request.url.path == '/functions/v1/player-admin') {
          edgeCalls++;
          expectSync(jsonDecode(request.body), {
            'action': 'finish_password_change',
            'password': '  nueva1234  ',
          });
          expectSync(
            request.headers['authorization'],
            'Bearer ${Supabase.instance.client.auth.currentSession!.accessToken}',
          );
          pending = false;
          data = {'ok': true};
        } else if (request.url.path == '/rest/v1/rpc/staff_business_profile') {
          expectSync(pending, isFalse);
          expectSync(jsonDecode(request.body), {'requested_billar_id': 'A'});
          data = {
            'billar_id': brandingBillar,
            'business_name': 'BILLAR DEL PERSONAL',
            'logo_url': '',
            'primary_color': 0x1565C0,
          };
        } else if (request.url.path == '/rest/v1/rpc/staff_purchase_report') {
          reportCalls++;
          data = {
            'billar_id': 'A',
            'count': 0,
            'total': 0,
            'paid': 0,
            'balance': 0,
            'items': [],
            'has_more': false,
          };
        } else if (request.url.path == '/rest/v1/rpc/staff_sale_products') {
          catalogCalls++;
          data = [];
        } else if (request.url.path ==
            '/rest/v1/rpc/staff_table_visible_tables') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expectSync(body['requested_billar_id'], 'A');
          expectSync(body['requested_table_type'], 'Billar');
          data = {
            'billar_id': 'A',
            'table_type': 'Billar',
            'items': [
              {
                'id': 17,
                'billar_id': 'A',
                'name': 'Mesa de personal',
                'table_type': 'Billar',
                'is_occupied': activeServiceId.isEmpty ? 0 : 1,
                'start_time':
                    activeServiceId.isEmpty ? null : activeServiceOpenedAt,
                'orders': jsonEncode(serviceItems),
                'is_deleted': 0,
                'service_id': activeServiceId.isEmpty ? null : activeServiceId,
                'service_actor_id': activeServiceId.isEmpty ? null : actor,
                'service_state': activeServiceId.isEmpty ? null : 'active',
                'service_items': serviceItems,
              },
            ],
          };
        } else if (request.url.path == '/rest/v1/rpc/staff_table_open') {
          serviceOpenCalls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          activeServiceId = body['requested_service_id'] as String;
          activeServiceOpenedAt = body['requested_opened_at'] as String;
          data = {
            'service_id': activeServiceId,
            'actor_id': actor,
            'billar_id': 'A',
            'table_id': 17,
            'table_type': 'Billar',
            'opened_at': activeServiceOpenedAt,
            'state': 'active',
          };
        } else if (request.url.path ==
            '/rest/v1/rpc/staff_table_add_consumption') {
          serviceConsumptionCalls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final item = {
            'request_id': body['requested_request_id'],
            'productId': body['requested_product_id'],
            'productName': body['requested_product_name'],
            'price': body['requested_price'],
            'quantity': body['requested_quantity'],
            'recorded_at': body['requested_recorded_at'],
          };
          serviceItems = [...serviceItems, item];
          data = {
            'request_id': item['request_id'],
            'service_id': activeServiceId,
            'billar_id': 'A',
            'actor_id': actor,
            'product_id': item['productId'],
            'product_name': item['productName'],
            'quantity': item['quantity'],
            'price': item['price'],
            'recorded_at': item['recorded_at'],
            'service_state': 'active',
            'late': false,
          };
        } else if (request.url.path == '/rest/v1/rpc/staff_table_conflicts') {
          conflictListCalls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expectSync(body['requested_billar_id'], 'A');
          expectSync(body['requested_table_type'], 'Billar');
          data = {
            'billar_id': 'A',
            'table_type': 'Billar',
            'has_more': false,
            'items': [
              {
                'ordinal': 2,
                'service_id': activeServiceId,
                'actor_id': actor,
                'table_id': 17,
                'table_type': 'Billar',
                'billar_id': 'A',
                'opened_at': activeServiceOpenedAt,
                'reason': 'late_consumption',
              },
              {
                'ordinal': 1,
                'service_id': '00000000-0000-4000-8000-000000000022',
                'actor_id': actor,
                'table_id': 19,
                'table_type': 'Billar',
                'billar_id': 'A',
                'opened_at': activeServiceOpenedAt,
                'reason': 'opening',
              },
            ],
          };
        } else if (request.url.path ==
            '/rest/v1/rpc/staff_table_conflict_consumptions') {
          conflictConsumptionCalls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final serviceId = body['requested_service_id'] as String;
          data = {
            'billar_id': 'A',
            'table_type': 'Billar',
            'service_id': serviceId,
            'has_more': false,
            'items':
                serviceId == activeServiceId
                    ? [
                      {
                        'ordinal': 3,
                        'request_id': serviceItems.single['request_id'],
                        'product_id': 12,
                        'product_name': 'Agua',
                        'quantity': 2,
                        'price': 12,
                        'recorded_at': serviceItems.single['recorded_at'],
                      },
                    ]
                    : [],
          };
        } else if (request.url.path ==
            '/rest/v1/rpc/staff_table_review_opening_conflict') {
          openingReviewCalls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          data = {
            'service_id': body['requested_service_id'],
            'billar_id': 'A',
            'table_type': 'Billar',
            'state': 'conflict',
            'reviewed_at': '2026-11-19T20:00:00Z',
            'reviewed_by': actor,
          };
        } else if (request.url.path == '/rest/v1/products') {
          expectSync(request.method, 'GET');
          expectSync(request.url.queryParameters['billar_id'], 'eq.A');
          if (denyInventory) {
            return http.Response(
              jsonEncode({
                'code': '42501',
                'message': 'Sin permiso de inventario',
              }),
              403,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          data =
              invalidInventoryResponse
                  ? [null]
                  : request.url.queryParameters['id'] == 'gt.0'
                  ? [
                    {
                      'id': 1,
                      'billar_id': 'A',
                      'name': 'Agua',
                      'barcode': 'H2O-001',
                      'category': 'Bebidas',
                      'presentation': null,
                      'price': 12,
                      'cost': 7,
                      'stock': 8,
                      'is_active': true,
                      'is_promo': 0,
                      'parent_id': null,
                      'pieces_per_unit': 1,
                    },
                    {
                      'id': 2,
                      'billar_id': 'A',
                      'name': 'Pan',
                      'barcode': 'PAN-001',
                      'category': 'Comida',
                      'presentation': null,
                      'price': 10,
                      'cost': 5,
                      'stock': 3.5,
                      'is_active': true,
                      'is_promo': 0,
                      'parent_id': null,
                      'pieces_per_unit': 1,
                    },
                  ]
                  : [];
        } else if ([
          '/rest/v1/providers',
          '/rest/v1/purchases',
        ].contains(request.url.path)) {
          expectSync(request.method, 'GET');
          expectSync(request.url.queryParameters['billar_id'], 'eq.A');
          expectSync(
            request.url.queryParameters['select'],
            isNot(contains('*')),
          );
          purchaseReads++;
          data = [];
        } else {
          throw StateError(
            'Unexpected staff request: ${request.method} ${request.url}',
          );
        }
        return http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      Future<void> waitFor(bool Function() condition) async {
        for (var attempt = 0; attempt < 300; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (condition()) {
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pump();
            return;
          }
        }
        final visible = tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .whereType<String>()
            .join(' | ');
        fail(
          'La navegación de personal no alcanzó el estado esperado: $visible',
        );
      }

      try {
        await tester.runAsync(
          () => Supabase.initialize(
            url: 'https://example.supabase.co',
            publishableKey: 'test-key',
            httpClient: transport,
            authOptions: const FlutterAuthClientOptions(
              autoRefreshToken: false,
              detectSessionInUri: false,
            ),
          ),
        );
        AccountStorage.initialize(Supabase.instance.client);
        final theme = ThemeProvider()..init();
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: theme,
            child: MaterialApp(
              navigatorKey: navigator,
              home: const LoginPage(enableStaffForIntegration: true),
              onGenerateRoute:
                  (settings) =>
                      enableIntegration
                          ? staffPilotEnabled
                              ? AppRouter.onGenerateRoute(settings)
                              : AppRouter.generateRoute(
                                settings,
                                enableStaffForIntegration: true,
                              )
                          : AppRouter.generateRoute(settings),
            ),
          ),
        );
        await tester.enterText(find.byType(TextField).at(0), ' CAJA ');
        await tester.enterText(find.byType(TextField).at(1), '  temporal123  ');
        await tester.ensureVisible(find.text('ENTRAR'));
        await tester.tap(find.text('ENTRAR'));
        await waitFor(
          () => find.text('CAMBIAR CONTRASEÑA').evaluate().isNotEmpty,
        );
        expect(AccountStorage.instance.isActive, isTrue);
        expect(preferences.billarId, 'A');
        expect(rawPreferences.getString('billar_id'), 'ORIGINAL');
        expect(rawPreferences.getString('business_name'), 'NEGOCIO ORIGINAL');
        expect(preferences.businessName, isNot('NEGOCIO ORIGINAL'));
        database = await tester.runAsync(
          () => DatabaseHelper.instance.database,
        );
        await tester.runAsync(
          () => database!.insert('products', {
            'id': 12,
            'billar_id': 'A',
            'name': 'Agua',
            'price': 12.0,
            'cost': 5.0,
            'stock': 10.0,
          }),
        );

        navigator.currentState!.pushNamed(AppRoutes.home);
        await waitFor(
          () => find.text('CAMBIAR CONTRASEÑA').evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(catalogCalls, 0);
        await tester.enterText(
          find.byType(TextFormField).at(0),
          '  nueva1234  ',
        );
        await tester.enterText(
          find.byType(TextFormField).at(1),
          '  nueva1234  ',
        );
        await tester.ensureVisible(find.text('GUARDAR Y CONTINUAR'));
        await tester.tap(find.text('GUARDAR Y CONTINUAR'));
        await waitFor(() => find.byType(StaffHomePage).evaluate().isNotEmpty);
        expect(edgeCalls, 1);
        expect(pending, isFalse);
        expect(find.text('BILLAR DEL PERSONAL'), findsOneWidget);
        expect(find.text('caja'), findsOneWidget);
        expect(
          tester.widget<HomeHeader>(find.byType(HomeHeader)).primaryColor,
          const Color(0xFF1565C0),
        );
        expect(
          find.widgetWithText(ModuleCard, 'VENTA\nRÁPIDA'),
          findsOneWidget,
        );
        expect(find.byType(ModuleCard), findsOneWidget);
        expect(find.text('INFORMES'), findsNothing);
        expect(find.text('CONFIGURACIÓN'), findsNothing);
        expect(find.text('INVENTARIO'), findsNothing);

        brandingBillar = 'B';
        await tester.tap(find.byTooltip('Actualizar permisos'));
        await waitFor(() => find.text('REINTENTAR').evaluate().isNotEmpty);
        expect(find.byType(StaffHomePage), findsNothing);
        expect(find.text('BILLAR DEL PERSONAL'), findsNothing);
        brandingBillar = 'A';
        modules = ['quick_sale', 'inventory', 'purchases'];
        await tester.tap(find.text('REINTENTAR'));
        await waitFor(() => find.byType(StaffHomePage).evaluate().isNotEmpty);
        expect(
          tester
              .widgetList<ModuleCard>(find.byType(ModuleCard))
              .map((c) => c.label),
          ['VENTA\nRÁPIDA', 'INVENTARIO', 'COMPRAS'],
        );
        modules = ['quick_sale', 'reports'];
        await tester.tap(find.byTooltip('Actualizar permisos'));
        await waitFor(() => find.byType(ModuleCard).evaluate().length == 1);
        modules = [
          'billiard_tables',
          'billiard_tables_open',
          'billiard_tables_consume',
        ];
        await tester.tap(find.byTooltip('Actualizar permisos'));
        await waitFor(() => find.text('MESAS\nBILLAR').evaluate().isNotEmpty);
        await tester.tap(find.text('MESAS\nBILLAR'));
        await waitFor(
          () => find.byType(StaffTableServicePage).evaluate().isNotEmpty,
        );
        await waitFor(
          () => find.text('Mesa de personal').evaluate().isNotEmpty,
        );
        expect(find.byType(BilliardTablesPage), findsNothing);
        await tester.tap(find.byTooltip('Iniciar servicio'));
        await waitFor(
          () =>
              serviceOpenCalls == 1 &&
              find.byTooltip('Anotar consumo').evaluate().isNotEmpty,
        );
        await tester.tap(find.byTooltip('Anotar consumo'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, '2');
        await tester.tap(find.text('GUARDAR').last);
        await waitFor(
          () =>
              serviceConsumptionCalls == 1 &&
              find.textContaining('Agua × 2.0').evaluate().isNotEmpty,
        );
        expect(find.byTooltip('Revisar conflictos'), findsNothing);
        navigator.currentState!.pop();
        await waitFor(() => find.byType(StaffHomePage).evaluate().isNotEmpty);
        await tester.runAsync(
          () => database!.delete('products', where: 'id = ?', whereArgs: [12]),
        );
        modules = [
          'billiard_tables',
          'billiard_tables_open',
          'billiard_tables_consume',
          'billiard_tables_view_all',
        ];
        await tester.tap(find.byTooltip('Actualizar permisos'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('MESAS\nBILLAR'));
        await waitFor(
          () => find.byType(StaffTableServicePage).evaluate().isNotEmpty,
        );
        await waitFor(
          () => find.text('Mesa de personal').evaluate().isNotEmpty,
        );
        await tester.tap(find.byTooltip('Revisar conflictos'));
        await waitFor(
          () =>
              conflictListCalls == 1 &&
              find.text('Consumo tardío · Mesa 17').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Consumo tardío · Mesa 17'));
        await waitFor(
          () =>
              conflictConsumptionCalls == 1 &&
              find.text('Agua × 2.0').evaluate().isNotEmpty,
        );
        expect(
          find.textContaining(
            'Se requiere permiso de cobro para crear un ajuste separado.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('CERRAR').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Apertura rechazada · Mesa 19'));
        await waitFor(
          () =>
              conflictConsumptionCalls == 2 &&
              find
                  .text('No hay consumos asociados a este conflicto.')
                  .evaluate()
                  .isNotEmpty,
        );
        await tester.tap(find.text('MARCAR REVISADO'));
        await waitFor(
          () =>
              openingReviewCalls == 1 &&
              find.text('Apertura rechazada · Mesa 19').evaluate().isEmpty,
        );
        await tester.tap(find.text('CERRAR'));
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await waitFor(() => find.byType(StaffHomePage).evaluate().isNotEmpty);
        modules = ['billiard_tables', 'billiard_tables_charge'];
        await tester.tap(find.byTooltip('Actualizar permisos'));
        await waitFor(() => find.text('MESAS\nBILLAR').evaluate().isNotEmpty);
        await tester.tap(find.text('MESAS\nBILLAR'));
        await waitFor(
          () => find.byType(StaffTableServicePage).evaluate().isNotEmpty,
        );
        await waitFor(
          () => find.text('Mesa de personal').evaluate().isNotEmpty,
        );
        expect(find.byTooltip('Revisar conflictos'), findsNothing);
        expect(find.byTooltip('Iniciar servicio'), findsNothing);
        expect(find.byTooltip('Cobrar servicio'), findsOneWidget);
        navigator.currentState!.pop();
        await waitFor(() => find.byType(StaffHomePage).evaluate().isNotEmpty);
        modules = ['quick_sale', 'reports'];
        await tester.tap(find.byTooltip('Actualizar permisos'));
        await waitFor(() => find.byType(ModuleCard).evaluate().length == 1);

        navigator.currentState!.pushNamed(AppRoutes.inventory);
        await waitFor(
          () =>
              find
                  .textContaining('No tienes permiso para usar inventario.')
                  .evaluate()
                  .isNotEmpty,
        );
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        modules = ['quick_sale', 'reports', 'inventory'];
        await tester.tap(find.byTooltip('Actualizar permisos'));
        await waitFor(() => find.text('INVENTARIO').evaluate().isNotEmpty);
        await tester.tap(find.text('INVENTARIO'));
        await waitFor(() => find.text('Agua').evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        expect(find.byType(StaffInventoryPage), findsOneWidget);
        expect(find.text('Pan'), findsOneWidget);
        expect(find.textContaining('Costo: \$7.00'), findsOneWidget);
        expect(find.byType(FloatingActionButton), findsNothing);
        await tester.enterText(find.byType(TextField), 'agua');
        await tester.pump();
        expect(find.text('Agua'), findsOneWidget);
        expect(find.text('Pan'), findsNothing);
        await tester.enterText(find.byType(TextField), 'h2o-001');
        await tester.pump();
        expect(find.text('Agua'), findsOneWidget);
        expect(find.text('Pan'), findsNothing);
        await tester.enterText(find.byType(TextField), '');
        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Comida').last);
        await tester.pumpAndSettle();
        expect(find.text('Agua'), findsNothing);
        expect(find.text('Pan'), findsOneWidget);
        denyInventory = true;
        await tester.tap(find.byTooltip('Actualizar inventario'));
        await waitFor(
          () =>
              find
                  .textContaining('Sin permiso de inventario')
                  .evaluate()
                  .isNotEmpty,
        );
        expect(find.text('Agua'), findsNothing);
        expect(find.text('Pan'), findsNothing);
        denyInventory = false;
        await tester.tap(find.text('REINTENTAR'));
        await waitFor(() => find.text('Pan').evaluate().isNotEmpty);
        invalidInventoryResponse = true;
        await tester.tap(find.byTooltip('Actualizar inventario'));
        await waitFor(() => find.text('REINTENTAR').evaluate().isNotEmpty);
        expect(find.text('Pan'), findsNothing);
        expect(find.text('Sin productos para esta consulta.'), findsNothing);
        invalidInventoryResponse = false;
        await tester.tap(find.text('REINTENTAR'));
        await waitFor(() => find.text('Pan').evaluate().isNotEmpty);
        modules = ['quick_sale', 'reports'];
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await waitFor(
          () =>
              find
                  .textContaining('No tienes permiso para usar inventario.')
                  .evaluate()
                  .isNotEmpty,
        );
        expect(find.byType(StaffInventoryPage), findsNothing);
        expect(find.text('Pan'), findsNothing);
        expect(
          await tester.runAsync(
            () => database!.rawQuery('select count(*) as total from products'),
          ),
          [
            {'total': 0},
          ],
        );
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        final beforePurchases = purchaseReads;
        navigator.currentState!.pushNamed(AppRoutes.purchases);
        await waitFor(
          () =>
              find
                  .textContaining('No tienes permiso para usar compras.')
                  .evaluate()
                  .isNotEmpty,
        );
        expect(find.byType(StaffPurchasesPage), findsNothing);
        expect(purchaseReads, beforePurchases);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        modules = ['quick_sale', 'reports', 'purchases'];
        await tester.tap(find.byTooltip('Actualizar permisos'));
        await waitFor(() => find.text('COMPRAS').evaluate().isNotEmpty);
        await tester.tap(find.text('COMPRAS'));
        await waitFor(
          () => find.text('GESTIONAR PROVEEDORES').evaluate().isNotEmpty,
        );
        expect(find.byType(StaffPurchasesPage), findsOneWidget);
        expect(find.text('COMPRAS · PERSONAL'), findsOneWidget);
        expect(find.text('ANULAR'), findsNothing);
        expect(purchaseReads, greaterThan(beforePurchases));
        expect(
          await tester.runAsync(
            () => database!.rawQuery('select count(*) as total from providers'),
          ),
          [
            {'total': 0},
          ],
        );
        modules = ['quick_sale', 'reports', 'inventory'];
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await waitFor(
          () =>
              find
                  .textContaining('No tienes permiso para usar compras.')
                  .evaluate()
                  .isNotEmpty,
        );
        expect(find.byType(StaffPurchasesPage), findsNothing);
        expect(find.text('GESTIONAR PROVEEDORES'), findsNothing);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        for (final route in ['/ruta_desconocida', AppRoutes.cashOperations]) {
          navigator.currentState!.pushNamed(route);
          await waitFor(
            () =>
                find
                    .text('Esta ruta aún no está habilitada para personal.')
                    .evaluate()
                    .isNotEmpty,
          );
          expect(find.text('CAJA Y TURNOS'), findsNothing);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
        }
        modules = ['reports_purchases'];
        await tester.tap(find.byTooltip('Actualizar permisos'));
        await waitFor(() => find.text('INFORMES').evaluate().isNotEmpty);
        expect(find.byType(ModuleCard), findsOneWidget);
        expect(find.text('COMPRAS'), findsNothing);
        expect(find.text('VENTA\nRÁPIDA'), findsNothing);
        final beforeReportPurchases = purchaseReads;
        navigator.currentState!.pushNamed(AppRoutes.purchases);
        await waitFor(
          () =>
              find
                  .textContaining('No tienes permiso para usar compras.')
                  .evaluate()
                  .isNotEmpty,
        );
        expect(find.byType(StaffPurchasesPage), findsNothing);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('INFORMES'));
        await waitFor(
          () =>
              find.text('No hay compras en este rango.').evaluate().isNotEmpty,
        );
        expect(find.byType(StaffReportsPage), findsOneWidget);
        expect(find.text('ANULAR'), findsNothing);
        expect(find.text('CAJA Y TURNOS'), findsNothing);
        expect(reportCalls, greaterThan(0));
        expect(purchaseReads, beforeReportPurchases);
        modules = ['quick_sale'];
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await waitFor(
          () =>
              find
                  .textContaining('No tienes permiso para usar informes.')
                  .evaluate()
                  .isNotEmpty,
        );
        expect(find.byType(StaffReportsPage), findsNothing);
        expect(find.text('No hay compras en este rango.'), findsNothing);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Actualizar permisos'));
        await waitFor(() => find.text('VENTA\nRÁPIDA').evaluate().isNotEmpty);
        await tester.tap(find.text('VENTA\nRÁPIDA'));
        await waitFor(
          () => find.text('Sin productos de venta.').evaluate().isNotEmpty,
        );
        expect(
          tester
              .widget<StaffQuickSalePage>(find.byType(StaffQuickSalePage))
              .enableForIntegration,
          isTrue,
        );
        expect(catalogCalls, 1);

        modules = ['reports'];
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await waitFor(
          () =>
              find
                  .textContaining('No tienes permiso para usar venta rápida')
                  .evaluate()
                  .isNotEmpty,
        );
        expect(find.byType(StaffQuickSalePage), findsNothing);
        expect(catalogCalls, 1);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Actualizar permisos'));
        await waitFor(() => find.byType(StaffHomePage).evaluate().isNotEmpty);
        expect(find.byType(ModuleCard), findsNothing);

        enableIntegration = false;
        final checked = membershipCalls;
        navigator.currentState!.pushNamed(AppRoutes.home);
        await tester.pumpAndSettle();
        expect(
          find.text('El acceso de personal aún no está habilitado.'),
          findsOneWidget,
        );
        expect(membershipCalls, checked);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        navigator.currentState!.pushNamed(AppRoutes.purchases);
        await tester.pumpAndSettle();
        expect(
          find.text('El acceso de personal aún no está habilitado.'),
          findsOneWidget,
        );
        expect(find.byType(StaffPurchasesPage), findsNothing);
        expect(membershipCalls, checked);
        await tester.tap(find.text('CERRAR SESIÓN'));
        await waitFor(() => find.text('ENTRAR').evaluate().isNotEmpty);
        expect(Supabase.instance.client.auth.currentUser, isNull);
        expect(AccountStorage.instance.requiresRestart, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          final opened =
              database ??
              (AccountStorage.instance.isActive
                  ? await DatabaseHelper.instance.database
                  : null);
          await opened?.close();
        });
        await tester.runAsync(AccountStorage.instance.dispose);
        await tester.runAsync(Supabase.instance.dispose);
        transport.close();
        messenger.setMockMethodCallHandler(pathChannel, null);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
