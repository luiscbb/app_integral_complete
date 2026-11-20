import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/purchases/data/repositories/staff_purchase_outbox.dart';
import 'package:app_integral_complete/features/purchases/data/repositories/staff_purchases_repository.dart';
import 'package:app_integral_complete/features/purchases/data/repositories/staff_provider_outbox.dart';
import 'package:app_integral_complete/features/purchases/data/repositories/staff_providers_repository.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/staff_purchase.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/purchase_payment_terms.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/staff_purchase_data.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/provider_entity.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/staff_provider_operation.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/staff_operation_rejection.dart';
import 'package:app_integral_complete/features/purchases/presentation/pages/staff_purchases_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _PageOutbox extends StaffPurchaseOutbox {
  _PageOutbox(super.database, super.requireSession);

  PendingStaffPurchase? value;

  @override
  Future<PendingStaffPurchase?> pending(SyncSession session) async {
    requireSession(session);
    return value;
  }
}

class _PageProviderOutbox extends StaffProviderOutbox {
  _PageProviderOutbox(super.database, super.requireSession);

  PendingStaffProvider? value;

  @override
  Future<PendingStaffProvider?> pending(SyncSession session) async => value;
}

class _PageProvidersRepository extends StaffProvidersRepository {
  const _PageProvidersRepository(
    super.client,
    super.outbox,
    this.onApply,
    this.onRecover,
  );

  final Future<StaffProviderReceipt> Function(StaffProviderDraft) onApply;
  final Future<StaffProviderReceipt?> Function() onRecover;

  @override
  Future<StaffProviderReceipt> apply(
    SyncSession session,
    StaffProviderDraft draft,
  ) => onApply(draft);

  @override
  Future<StaffProviderReceipt?> recover(SyncSession session) => onRecover();
}

class _PageRepository extends StaffPurchasesRepository {
  const _PageRepository(
    super.client,
    super.outbox,
    this.data,
    this.onRecord,
    this.onRecover,
  );

  final StaffPurchaseData data;
  final Future<StaffPurchaseReceipt> Function(StaffPurchaseDraft) onRecord;
  final Future<StaffPurchaseReceipt?> Function() onRecover;

  @override
  Future<StaffPurchaseData> load(SyncSession session) async => data;

  @override
  Future<StaffPurchaseReceipt> record(
    SyncSession session,
    StaffPurchaseDraft draft,
  ) => onRecord(draft);

  @override
  Future<StaffPurchaseReceipt?> recover(SyncSession session) => onRecover();

  @override
  Future<StaffPurchaseReceipt?> resolvePending(SyncSession session) =>
      onRecover();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const actor = '00000000-0000-0000-0000-000000000002';
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late String dbPath;
  late Database database;
  late SupabaseClient client;
  late MockClient transport;
  late SyncSession session;
  late StaffPurchaseOutbox outbox;
  late StaffPurchasesRepository repository;
  late Map<String, Object?> membership;
  late Map<String, Map<String, dynamic>> remote;
  late List<Map<String, dynamic>> submissions;
  late List<Map<String, dynamic>> resolutions;
  Object? Function(Map<String, dynamic>)? corrupt;
  void Function()? onRpc;
  var generation = 1;
  var loseResponse = false;
  var membershipOffline = false;
  late Map<String, Map<int, List<Map<String, dynamic>>>> readPages;
  late List<String> reads;
  void Function(String)? onRead;

  StaffPurchaseDraft draft({
    String reference = 'FACT-1',
    PurchasePaymentTerms? payment,
    int? providerId = 1,
  }) => StaffPurchaseDraft(
    providerId: providerId,
    reference: reference,
    cashSource: payment == null ? 'caja' : payment.legacyCashSource,
    payment: payment,
    items: const [
      StaffPurchaseItem(
        productId: 1,
        quantity: 0.5,
        costPerUnit: 4,
        parentId: null,
        piecesPerUnit: 1,
      ),
      StaffPurchaseItem(
        productId: 3,
        quantity: 2,
        costPerUnit: 24,
        parentId: 1,
        piecesPerUnit: 4,
      ),
    ],
  );
  Map<String, Object?> paymentReceipt(Object? value) {
    if (value == null) return {};
    final payment = PurchasePaymentTerms.fromJson(value);
    return {
      'payment_condition': payment.condition,
      'payment_method': payment.paymentMethod,
      'credit_days': payment.creditDays,
      'due_date':
          payment.isCredit
              ? DateTime.utc(2026, 11, 16)
                  .add(Duration(days: payment.creditDays!))
                  .toIso8601String()
                  .substring(0, 10)
              : null,
      'paid_amount': payment.isCredit ? 0 : 50,
      'balance_due': payment.isCredit ? 50 : 0,
    };
  }

  void attach() {
    outbox = StaffPurchaseOutbox(database, (expected) {
      if (expected.actorId != client.auth.currentUser?.id ||
          expected.billarId != 'A' ||
          expected.scopeGeneration != generation ||
          !identical(expected.authSession, client.auth.currentSession) ||
          expected.token != client.auth.currentSession?.accessToken) {
        throw StateError('La sesión o el billar cambió.');
      }
    });
    repository = StaffPurchasesRepository(client, outbox);
  }

  Map<String, dynamic> receipt(Map<String, dynamic> body) => {
    'request_id': body['p_request_id'],
    'actor_id': actor,
    'billar_id': 'A',
    'purchase': {
      'id': 12,
      'billar_id': 'A',
      'provider_id': body['p_provider_id'],
      'reference': body['p_reference'],
      'cash_source': body['p_cash_source'],
      'date': '2026-11-16T22:00:00Z',
      'created_by': 'compras',
      'total': 50,
      'cancelled': false,
      ...paymentReceipt(body['p_payment']),
    },
    'items': [
      {
        ...(body['p_items'] as List)[0],
        'product_name': 'Unidad',
        'stock_product_id': 1,
        'stock_quantity': 0.5,
        'cost_per_piece': 4,
      },
      {
        ...(body['p_items'] as List)[1],
        'product_name': 'Caja cuatro',
        'stock_product_id': 1,
        'stock_quantity': 8,
        'cost_per_piece': 6,
      },
    ],
    'stock_before': [
      {'product_id': 1, 'stock': 10, 'cost': 3.5, 'stock_revision': 0},
      {'product_id': 3, 'stock': 0, 'cost': 14, 'stock_revision': 0},
      {'product_id': 4, 'stock': 0, 'cost': null, 'stock_revision': 0},
    ],
    'stock_after': [
      {'product_id': 1, 'stock': 18.5, 'cost': 6, 'stock_revision': 2},
      {'product_id': 3, 'stock': 0, 'cost': 24, 'stock_revision': 2},
      {'product_id': 4, 'stock': 0, 'cost': 12, 'stock_revision': 2},
    ],
  };

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('staff_purchases_');
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    dbPath = path.join(
      directory.path,
      'BaumarSolutions',
      'database',
      'integral_pos_v1.db',
    );
    await Directory(path.dirname(dbPath)).create(recursive: true);
    ffi.sqfliteFfiInit();
    final old = await ffi.databaseFactoryFfi.openDatabase(
      dbPath,
      options: ffi.OpenDatabaseOptions(
        version: 50,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE providers (id INTEGER PRIMARY KEY)');
          await db.execute(
            'CREATE TABLE products (id INTEGER PRIMARY KEY, stock REAL, cost REAL)',
          );
          await db.insert('products', {'id': 1, 'stock': 100, 'cost': 77});
          await db.execute(
            'CREATE TABLE purchases (id INTEGER PRIMARY KEY, total REAL)',
          );
          await db.insert('purchases', {'id': 1, 'total': 999});
          await db.execute(
            'CREATE TABLE pending_staff_sales (request_id TEXT, payload TEXT)',
          );
          await db.insert('pending_staff_sales', {
            'request_id': 'sale-pending',
            'payload': '{"total":10}',
          });
        },
      ),
    );
    await old.close();
    database = await DatabaseHelper.instance.database;
  });
  tearDownAll(() async {
    await database.close();
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });
  setUp(() async {
    await database.delete('staff_purchase_operations');
    generation = 1;
    loseResponse = false;
    membershipOffline = false;
    corrupt = null;
    onRpc = null;
    onRead = null;
    reads = [];
    readPages = {
      'products': {
        0: [
          {
            'id': 1,
            'billar_id': 'A',
            'name': 'Unidad',
            'cost': 4,
            'parent_id': null,
            'pieces_per_unit': 1,
            'is_active': true,
            'is_promo': 0,
          },
        ],
        1: [
          {
            'id': 3,
            'billar_id': 'A',
            'name': 'Caja cuatro',
            'cost': 24,
            'parent_id': 1,
            'pieces_per_unit': 4,
            'is_active': true,
            'is_promo': 0,
          },
        ],
      },
      'providers': {
        0: [
          {
            'id': 1,
            'billar_id': 'A',
            'name': 'Proveedor prueba',
            'is_active': true,
            'credit_days': 30,
            'preferred_payment_method': 'credito',
          },
        ],
      },
      'purchases': {
        0: [
          {
            'id': 12,
            'billar_id': 'A',
            'provider_id': 1,
            'reference': 'FACT-1',
            'date': '2026-11-16T22:00:00Z',
            'total': 50,
            'cancelled': false,
            'cash_source': 'caja',
            'payment_condition': null,
            'payment_method': null,
            'credit_days': null,
            'due_date': null,
            'paid_amount': null,
            'balance_due': null,
          },
        ],
      },
    };
    membership = {
      'billar_id': 'A',
      'role': 'manager',
      'is_active': true,
      'must_change_password': false,
      'username': 'compras',
      'allowed_modules': ['purchases'],
    };
    remote = {};
    submissions = [];
    resolutions = [];
    transport = MockClient((request) async {
      Object? data;
      if (request.url.path == '/auth/v1/token') {
        final body = base64Url
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
          'access_token': 'eyJhbGciOiJub25lIn0.$body.signature',
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'test',
          'user': {
            'id': actor,
            'aud': 'authenticated',
            'created_at': '2025-01-01T00:00:00Z',
            'app_metadata': {'account_type': 'staff', 'billar_id': 'A'},
            'user_metadata': <String, dynamic>{},
          },
        };
      } else {
        expect(request.headers['authorization'], 'Bearer ${session.token}');
        if (request.url.path == '/rest/v1/business_memberships') {
          expect(request.method, 'GET');
          expect(request.url.queryParameters['user_id'], 'eq.$actor');
          expect(request.url.queryParameters['billar_id'], 'eq.A');
          if (membershipOffline) throw http.ClientException('Sin conexión');
          data = membership;
        } else if (readPages.containsKey(request.url.path.split('/').last)) {
          expect(request.method, 'GET');
          final table = request.url.path.split('/').last;
          reads.add(table);
          expect(request.url.queryParameters['billar_id'], 'eq.A');
          expect(request.url.queryParameters['select'], isNot(contains('*')));
          expect(
            request.url.queryParameters['order'],
            startsWith(table == 'purchases' ? 'id.desc' : 'id.asc'),
          );
          if (table != 'purchases') {
            expect(request.url.queryParameters['is_active'], 'eq.true');
            expect(request.url.queryParameters['limit'], '500');
          }
          if (table == 'products') {
            expect(request.url.queryParameters['is_promo'], 'eq.0');
          }
          final cursor = request.url.queryParameters['id'];
          final lastId = cursor == null ? 0 : int.parse(cursor.substring(3));
          onRead?.call(table);
          data = readPages[table]![lastId] ?? [];
        } else if (request.url.path ==
            '/rest/v1/rpc/resolve_staff_purchase_request') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final pending = (await outbox.pending(session))!;
          expect(body['p_request_id'], pending.draft.requestId);
          expect(body['p_kind'], 'purchase');
          expect(body['p_billar_id'], 'A');
          expect(
            body['p_request_payload'],
            StaffOperationRejection.requestPayload(pending.draft.parameters),
          );
          resolutions.add(body);
          final canonical = remote.putIfAbsent(
            pending.draft.requestId,
            () => {
              'status': 'rejected',
              'reason_code': 'not_applied_closed',
              'kind': 'purchase',
              'request_id': pending.draft.requestId,
              'actor_id': actor,
              'billar_id': 'A',
              'request_payload': body['p_request_payload'],
            },
          );
          onRpc?.call();
          if (loseResponse) throw http.ClientException('Cierre sin respuesta');
          final copy =
              jsonDecode(jsonEncode(canonical)) as Map<String, dynamic>;
          data = corrupt == null ? copy : corrupt!(copy);
        } else if (request.url.path == '/rest/v1/rpc/record_staff_purchase') {
          expect(request.method, 'POST');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['p_billar_id'], 'A');
          expect(body.containsKey('p_total'), false);
          expect(body.containsKey('p_created_by'), false);
          final saved = (await outbox.pending(session))!;
          expect(body['p_request_id'], saved.draft.requestId);
          expect(body['p_items'], saved.draft.parameters['p_items']);
          submissions.add(body);
          final canonical = remote.putIfAbsent(
            saved.draft.requestId,
            () => receipt(body),
          );
          onRpc?.call();
          if (loseResponse) {
            throw http.ClientException(
              'Respuesta perdida después de confirmar',
            );
          }
          final copy =
              jsonDecode(jsonEncode(canonical)) as Map<String, dynamic>;
          data = corrupt == null ? copy : corrupt!(copy);
        } else {
          throw StateError(
            'Unexpected purchases request: ${request.method} ${request.url}',
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
      email: 'a@example.test',
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
    attach();
  });
  tearDown(() async {
    await client.dispose();
    transport.close();
  });

  test(
    'loads scoped purchase catalog, full provider terms and history through short pages without touching owner data',
    () async {
      readPages['products']![0]!.first['cost'] = null;
      final oldProducts = await database.query('products');
      final oldPurchases = await database.query('purchases');
      final data = await repository.load(session);
      expect(data.products.map((product) => product.id), [1, 3]);
      expect(data.products.first.cost, isNull);
      expect(data.products.last.parentId, 1);
      expect(data.products.last.piecesPerUnit, 4);
      expect(data.providers.single.creditDays, 30);
      expect(data.providers.single.preferredPaymentMethod, 'credito');
      expect(data.history.single.payment, isNull);
      expect(reads.where((table) => table == 'products'), hasLength(3));
      expect(await database.query('products'), oldProducts);
      expect(await database.query('purchases'), oldPurchases);
      final history = readPages['purchases']![0]!.single;
      readPages['purchases']![0] = [
        for (var id = 100; id >= 51; id--) {...history, 'id': id},
      ];
      expect((await repository.load(session)).history, hasLength(50));
    },
  );

  test(
    'validates financial history without treating credit as paid cash or inventing historic terms',
    () async {
      final row = readPages['purchases']![0]!.single;
      row.addAll(
        PurchasePaymentTerms(option: 'credito', creditDays: 30).snapshot(
          total: 50,
          recordedAt: DateTime.parse(row['date'] as String),
        ),
      );
      row['cash_source'] = null;
      expect(
        (await repository.load(session)).history.single.payment!.isCredit,
        true,
      );
      final valid = Map<String, dynamic>.from(row);
      for (final change in [
        {'balance_due': 49.99, 'paid_amount': 0.01},
        {'due_date': '2026-12-15'},
        {'provider_id': null},
        {'cash_source': 'caja'},
        {'payment_condition': null},
        {'credit_days': -1},
      ]) {
        row
          ..clear()
          ..addAll(valid)
          ..addAll(change);
        await expectLater(repository.load(session), throwsFormatException);
      }
    },
  );

  test(
    'rejects foreign, repeated and invalid catalog or provider rows',
    () async {
      final row = readPages['products']![0]!.single;
      final valid = Map<String, dynamic>.from(row);
      for (final change in [
        {'billar_id': 'B'},
        {'id': 0},
        {'cost': -1},
        {'pieces_per_unit': 0},
        {'parent_id': 999},
        {'is_active': false},
        {'is_promo': 1},
      ]) {
        row
          ..clear()
          ..addAll(valid)
          ..addAll(change);
        await expectLater(repository.load(session), throwsFormatException);
      }
      row
        ..clear()
        ..addAll(valid);
      readPages['products']![1] = [
        {...valid},
      ];
      await expectLater(repository.load(session), throwsFormatException);
      readPages['products']![1] = [];
      readPages['providers']![0]!.first['credit_days'] = '30';
      await expectLater(repository.load(session), throwsFormatException);
    },
  );

  test(
    'rechecks permission after reads and stops when the scope changes',
    () async {
      membership['allowed_modules'] = ['inventory'];
      await expectLater(repository.load(session), throwsStateError);
      expect(reads, isEmpty);
      membership['allowed_modules'] = ['purchases'];
      onRead = (table) {
        if (table == 'purchases') membership['allowed_modules'] = ['inventory'];
      };
      await expectLater(repository.load(session), throwsStateError);
      membership['allowed_modules'] = ['purchases'];
      reads.clear();
      onRead = (_) => generation++;
      await expectLater(repository.load(session), throwsStateError);
      expect(reads, ['products']);
    },
  );

  testWidgets('standalone purchases stays disabled without integration', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: StaffPurchasesPage()));
    expect(
      find.text('Compras de personal aún no está habilitado.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'confirms provider credit, blocks new intents on uncertainty and recovers the same request',
    (tester) async {
      final pageOutbox = _PageOutbox(database, outbox.requireSession);
      StaffPurchaseDraft? submitted;
      var records = 0;
      var recoveries = 0;
      final data = StaffPurchaseData(
        products:
            readPages['products']!.values
                .expand((rows) => rows)
                .map((row) => StaffPurchaseProduct.fromMap(row, billarId: 'A'))
                .toList(),
        providers: [ProviderEntity.fromMap(readPages['providers']![0]!.single)],
        history: [],
      );
      StaffPurchaseReceipt confirmed(StaffPurchaseDraft draft) =>
          StaffPurchaseReceipt.validate(
            jsonDecode(
              jsonEncode(
                receipt({
                  'p_request_id': draft.requestId,
                  'p_provider_id': draft.providerId,
                  'p_reference': draft.reference,
                  'p_cash_source': draft.cashSource,
                  'p_items': draft.parameters['p_items'],
                  'p_payment': draft.payment!.toJson(),
                }),
              ),
            ),
            draft: draft,
            actorId: actor,
            billarId: 'A',
          );
      final pageRepository = _PageRepository(
        client,
        pageOutbox,
        data,
        (draft) async {
          records++;
          submitted = draft;
          pageOutbox.value = PendingStaffPurchase(draft, null);
          throw http.ClientException(
            'Respuesta perdida; confirma recuperando la solicitud.',
          );
        },
        () async {
          recoveries++;
          expect(
            pageOutbox.value!.draft.encodedPayload,
            submitted!.encodedPayload,
          );
          final result = confirmed(pageOutbox.value!.draft);
          pageOutbox.value = null;
          return result;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: StaffPurchasesPage(
            enableForIntegration: true,
            repository: pageRepository,
            providersRepository: StaffProvidersRepository(
              client,
              _PageProviderOutbox(database, outbox.requireSession),
            ),
            captureSession: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proveedor prueba').last);
      await tester.pumpAndSettle();
      for (final entry in [
        ('Unidad', '0.5', '4'),
        ('Caja cuatro', '2', '24'),
      ]) {
        final add = find.byTooltip('Agregar ${entry.$1}');
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(find.byType(TextFormField).first, entry.$2);
        await tester.enterText(find.byType(TextFormField).last, entry.$3);
        await tester.tap(find.text('AGREGAR AL CARRITO'));
        await tester.pumpAndSettle();
      }
      final confirm = find.widgetWithText(
        FilledButton,
        'REVISAR Y CONFIRMAR COMPRA',
      );
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Crédito'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(find.text('Pagado: \$0.00 · Saldo: \$50.00'), findsOneWidget);
      await tester.tap(find.text('CONFIRMAR Y REGISTRAR'));
      await tester.pumpAndSettle();
      expect(records, 1);
      expect(submitted!.payment!.isCredit, true);
      expect(submitted!.providerId, 1);
      expect(submitted!.cashSource, isNull);
      expect(
        submitted!.parameters,
        draft(
          reference: '',
          payment: PurchasePaymentTerms(option: 'credito', creditDays: 30),
        ).parameters,
      );
      final scroller = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(confirm, 150, scrollable: scroller);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      final recover = find.text('RECUPERAR MISMA SOLICITUD');
      await tester.scrollUntilVisible(recover, -150, scrollable: scroller);
      await tester.pumpAndSettle();
      await tester.tap(recover);
      await tester.pumpAndSettle();
      expect(recoveries, 1);
      expect(records, 1);
      expect(pageOutbox.value, isNull);
      expect(
        find.text(
          'Hay una compra pendiente de confirmación. No registres otra ni cambies su solicitud.',
        ),
        findsNothing,
      );
      await tester.scrollUntilVisible(
        find.text('Total: \$0.00'),
        150,
        scrollable: scroller,
      );
      expect(find.text('Total: \$0.00'), findsOneWidget);
      expect(find.text('ANULAR'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'provider uncertainty blocks new operations and recovers the same draft from the purchase screen',
    (tester) async {
      final purchases = _PageOutbox(database, outbox.requireSession);
      final providers = _PageProviderOutbox(database, outbox.requireSession);
      StaffProviderDraft? submitted;
      var records = 0;
      var recoveries = 0;
      final page = _PageRepository(
        client,
        purchases,
        StaffPurchaseData(
          products: [],
          providers: [
            ProviderEntity.fromMap(readPages['providers']![0]!.single),
          ],
          history: [],
        ),
        (_) async => throw StateError('No se esperaba una compra.'),
        () async => throw StateError('No se esperaba recuperar una compra.'),
      );
      final providersRepository = _PageProvidersRepository(
        client,
        providers,
        (draft) async {
          records++;
          submitted = draft;
          providers.value = PendingStaffProvider(draft, null);
          throw http.ClientException('Respuesta perdida del proveedor.');
        },
        () async {
          recoveries++;
          final draft = providers.value!.draft;
          expect(draft.encodedPayload, submitted!.encodedPayload);
          final receipt = StaffProviderReceipt.validate(
            jsonDecode(
              jsonEncode({
                'request_id': draft.requestId,
                'actor_id': actor,
                'billar_id': 'A',
                'provider_id': draft.providerId,
                'operation': draft.operation,
                'provider': {
                  ...draft.parameters['p_provider'] as Map,
                  'id': draft.providerId,
                  'billar_id': 'A',
                  'is_active': true,
                },
                'product_ids': draft.parameters['p_product_ids'],
              }),
            ),
            draft: draft,
            actorId: actor,
            billarId: 'A',
          );
          providers.value = null;
          return receipt;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: StaffPurchasesPage(
            enableForIntegration: true,
            repository: page,
            providersRepository: providersRepository,
            captureSession: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('GESTIONAR PROVEEDORES'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AGREGAR PROVEEDOR'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byType(TextFormField).first,
        'Nuevo proveedor',
      );
      await tester.tap(find.text('GUARDAR PROVEEDOR'));
      await tester.pumpAndSettle();
      expect(records, 1);
      expect(providers.value!.draft.requestId, submitted!.requestId);
      final edit = find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            widget.tooltip == 'Editar proveedor Proveedor prueba',
      );
      if (edit.evaluate().isEmpty) {
        await tester.tap(find.text('GESTIONAR PROVEEDORES'));
        await tester.pumpAndSettle();
      }
      expect(tester.widget<IconButton>(edit).onPressed, isNull);
      final confirm = find.widgetWithText(
        FilledButton,
        'REVISAR Y CONFIRMAR COMPRA',
      );
      final scroller = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(confirm, 150, scrollable: scroller);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      final recover = find.text('RECUPERAR CAMBIO DE PROVEEDOR');
      await tester.scrollUntilVisible(recover, -150, scrollable: scroller);
      await tester.pumpAndSettle();
      await tester.tap(recover);
      await tester.pumpAndSettle();
      expect(recoveries, 1);
      expect(records, 1);
      expect(providers.value, isNull);
      expect(find.text('RECUPERAR CAMBIO DE PROVEEDOR'), findsNothing);
      if (edit.evaluate().isEmpty) {
        await tester.tap(find.text('GESTIONAR PROVEEDORES'));
        await tester.pumpAndSettle();
      }
      expect(tester.widget<IconButton>(edit).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'closing an unapplied purchase requires confirmation and only unlocks after acknowledgment',
    (tester) async {
      final purchases = _PageOutbox(database, outbox.requireSession);
      final intent = draft();
      purchases.value = PendingStaffPurchase(intent, null);
      var resolutions = 0;
      final data = StaffPurchaseData(
        products: [
          StaffPurchaseProduct.fromMap(
            readPages['products']![0]!.first,
            billarId: 'A',
          ),
        ],
        providers: [],
        history: [],
      );
      final page = _PageRepository(
        client,
        purchases,
        data,
        (_) async => throw StateError('No se esperaba registrar.'),
        () async {
          resolutions++;
          purchases.value = null;
          throw StaffOperationRejection.validate(
            {
              'status': 'rejected',
              'reason_code': 'not_applied_closed',
              'kind': 'purchase',
              'request_id': intent.requestId,
              'actor_id': actor,
              'billar_id': 'A',
              'request_payload': StaffOperationRejection.requestPayload(
                intent.parameters,
              ),
            },
            kind: 'purchase',
            requestId: intent.requestId,
            actorId: actor,
            billarId: 'A',
            parameters: intent.parameters,
          );
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: StaffPurchasesPage(
            enableForIntegration: true,
            repository: page,
            captureSession: () => session,
            providersRepository: StaffProvidersRepository(
              client,
              _PageProviderOutbox(database, outbox.requireSession),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final close = find.text('VERIFICAR CIERRE DE COMPRA');
      await tester.tap(close);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('VERIFICAR SOLICITUD PENDIENTE'), findsOneWidget);
      await tester.tap(find.text('VOLVER'));
      await tester.pumpAndSettle();
      expect(resolutions, 0);
      expect(purchases.value, isNotNull);
      await tester.tap(close);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('VERIFICAR Y RESOLVER'));
      await tester.pumpAndSettle();
      expect(resolutions, 1);
      expect(purchases.value, isNull);
      expect(find.text('RECUPERAR MISMA SOLICITUD'), findsNothing);
      expect(
        find.textContaining('Solicitud cerrada: el servidor confirmó'),
        findsOneWidget,
      );
      final add = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Agregar Unidad',
      );
      expect(tester.widget<IconButton>(add).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'resolution recovers an already committed purchase without recording another',
    () async {
      final intent = draft();
      loseResponse = true;
      await expectLater(
        repository.record(session, intent),
        throwsA(isA<http.ClientException>()),
      );
      loseResponse = false;
      expect((await repository.resolvePending(session))!.purchaseId, 12);
      expect(await outbox.pending(session), isNull);
      expect(submissions, hasLength(1));
      expect(resolutions, hasLength(1));
      expect(remote, hasLength(1));
    },
  );

  test(
    'a lost closure stays pending; rejects mismatched closures and persists the validated tombstone across restart',
    () async {
      final intent = draft(
        payment: PurchasePaymentTerms(option: 'credito', creditDays: 30),
      );
      await outbox.prepare(session, intent);
      loseResponse = true;
      await expectLater(
        repository.resolvePending(session),
        throwsA(isA<http.ClientException>()),
      );
      expect(await outbox.pending(session), isNotNull);
      loseResponse = false;
      for (final change in <void Function(Map<String, dynamic>)>[
        (row) => row['actor_id'] = 'another',
        (row) => row['billar_id'] = 'B',
        (row) => row['request_id'] = draft().requestId,
        (row) => row['kind'] = 'provider',
        (row) => row['reason_code'] = 'unknown',
        (row) => (row['request_payload'] as Map)['reference'] = 'changed',
        (row) =>
            ((row['request_payload'] as Map)['payment'] as Map)['credit_days'] =
                60,
      ]) {
        corrupt = (row) {
          change(row);
          return row;
        };
        await expectLater(
          repository.resolvePending(session),
          throwsFormatException,
        );
        expect(
          (await outbox.pending(session))!.draft.requestId,
          intent.requestId,
        );
      }
      corrupt = null;
      onRpc = () => generation++;
      await expectLater(repository.resolvePending(session), throwsStateError);
      generation = 1;
      onRpc = null;
      expect(await outbox.pending(session), isNotNull);
      // The original RPC may return the closure after its response was lost.
      await expectLater(
        repository.recover(session),
        throwsA(isA<StaffOperationRejection>()),
      );
      expect(await outbox.pending(session), isNull);
      await database.close();
      database = await ffi.databaseFactoryFfi.openDatabase(dbPath);
      attach();
      final calls = submissions.length;
      await expectLater(
        repository.record(session, intent),
        throwsA(isA<StaffOperationRejection>()),
      );
      expect(submissions.length, calls);
      final saved = (await database.query('staff_purchase_operations')).single;
      expect(saved['payload'], intent.encodedPayload);
      expect(jsonDecode(saved['receipt'] as String)['status'], 'rejected');
      await repository.record(session, draft(reference: 'Corregida'));
      expect(await outbox.pending(session), isNull);
    },
  );

  test(
    'failed local closure commit never releases an unacknowledged purchase',
    () async {
      final intent = draft();
      await outbox.prepare(session, intent);
      await database.execute('''
      CREATE TRIGGER reject_purchase_closure BEFORE UPDATE OF receipt
      ON staff_purchase_operations BEGIN SELECT RAISE(ABORT, 'Sin commit'); END
    ''');
      try {
        await expectLater(
          repository.resolvePending(session),
          throwsA(isA<DatabaseException>()),
        );
        expect(await outbox.pending(session), isNotNull);
      } finally {
        await database.execute('DROP TRIGGER reject_purchase_closure');
      }
      await expectLater(
        repository.resolvePending(session),
        throwsA(isA<StaffOperationRejection>()),
      );
      expect(await outbox.pending(session), isNull);
      expect(remote, hasLength(1));
    },
  );

  test('migration preserves owner data and sale requests', () async {
    expect(await database.getVersion(), 61);
    expect(await database.query('products'), [
      {'id': 1, 'stock': 100.0, 'cost': 77.0},
    ]);
    expect(await database.query('purchases'), [
      {
        'id': 1,
        'total': 999.0,
        'payment_condition': null,
        'payment_method': null,
        'credit_days': null,
        'due_date': null,
        'paid_amount': null,
        'balance_due': null,
      },
    ]);
    expect(
      (await database.query('pending_staff_sales')).single['request_id'],
      'sale-pending',
    );
  });
  test(
    'preserves legacy payloads and rejects contradictory payment terms before persisting',
    () {
      final original = draft();
      expect(original.parameters.containsKey('p_payment'), false);
      expect(
        StaffPurchaseDraft.restore(
          original.requestId,
          original.encodedPayload,
        ).encodedPayload,
        original.encodedPayload,
      );
      for (final makeInvalid in <void Function()>[
        () => PurchasePaymentTerms(option: 'credito'),
        () => PurchasePaymentTerms(option: 'credito', creditDays: -1),
        () => PurchasePaymentTerms(option: 'tarjeta', cashSource: 'caja'),
        () => PurchasePaymentTerms(option: 'transferencia', creditDays: 30),
        () => draft(
          payment: PurchasePaymentTerms(option: 'credito', creditDays: 30),
          providerId: null,
        ),
      ]) {
        expect(makeInvalid, throwsArgumentError);
      }
    },
  );
  test(
    'credit survives a lost response and reopening without changing its terms or UUID',
    () async {
      final intent = draft(
        payment: PurchasePaymentTerms(option: 'credito', creditDays: 30),
      );
      loseResponse = true;
      await expectLater(
        repository.record(session, intent),
        throwsA(isA<http.ClientException>()),
      );
      final pending = (await outbox.pending(session))!;
      expect(pending.draft.requestId, intent.requestId);
      expect(pending.draft.encodedPayload, intent.encodedPayload);
      await database.close();
      database = await ffi.databaseFactoryFfi.openDatabase(dbPath);
      attach();
      loseResponse = false;
      final result = (await repository.recover(session))!;
      final purchase = result.json['purchase'] as Map;
      expect(purchase['paid_amount'], 0);
      expect(purchase['balance_due'], 50);
      expect(purchase['due_date'], '2026-12-16');
      expect(purchase['cash_source'], isNull);
      expect(submissions.map((body) => body['p_request_id']).toSet(), {
        intent.requestId,
      });
      expect(submissions[0], submissions[1]);
    },
  );
  test(
    'rejects altered credit balances and maturities without releasing the pending purchase',
    () async {
      final intent = draft(
        payment: PurchasePaymentTerms(option: 'credito', creditDays: 30),
      );
      for (final change in [
        {'paid_amount': 10},
        {'paid_amount': 0.0000001},
        {'balance_due': 0},
        {'balance_due': 49.9999999},
        {'payment_method': 'efectivo'},
        {'credit_days': 60},
        {'due_date': '2026-12-15'},
        {'due_date': '2026-12-16T00:00:00Z'},
      ]) {
        corrupt = (data) {
          (data['purchase'] as Map).addAll(change);
          return data;
        };
        await expectLater(
          repository.record(session, intent),
          throwsFormatException,
        );
        expect(
          (await outbox.pending(session))!.draft.requestId,
          intent.requestId,
        );
      }
      corrupt = null;
      expect((await repository.recover(session))!.total, 50);
    },
  );
  test('rejects invalid item drafts before writing', () async {
    for (final item in [
      const StaffPurchaseItem(
        productId: 1,
        quantity: 0,
        costPerUnit: 4,
        parentId: null,
        piecesPerUnit: 1,
      ),
      const StaffPurchaseItem(
        productId: 1,
        quantity: 1,
        costPerUnit: -1,
        parentId: null,
        piecesPerUnit: 1,
      ),
      const StaffPurchaseItem(
        productId: 1,
        quantity: 1,
        costPerUnit: 4,
        parentId: 1,
        piecesPerUnit: 1,
      ),
      const StaffPurchaseItem(
        productId: 1,
        quantity: double.infinity,
        costPerUnit: 4,
        parentId: null,
        piecesPerUnit: 1,
      ),
    ]) {
      expect(
        () => StaffPurchaseDraft(
          providerId: null,
          reference: '',
          cashSource: 'caja',
          items: [item],
        ),
        throwsArgumentError,
      );
    }
    expect(await outbox.pending(session), isNull);
    expect(submissions, isEmpty);
  });

  test(
    'persists before sending, survives a lost response and reopening, and never writes owner stock',
    () async {
      final intent = draft();
      loseResponse = true;
      await expectLater(
        repository.record(session, intent),
        throwsA(isA<http.ClientException>()),
      );
      expect(remote.length, 1);
      final saved = (await outbox.pending(session))!;
      expect(saved.draft.requestId, intent.requestId);
      await expectLater(
        repository.record(session, draft(reference: 'OTRA')),
        throwsStateError,
      );
      expect(submissions.length, 1);
      await database.close();
      database = await ffi.databaseFactoryFfi.openDatabase(dbPath);
      attach();
      loseResponse = false;
      final recovered = (await repository.recover(session))!;
      expect(recovered.purchaseId, 12);
      expect(recovered.total, 50);
      expect(submissions[0], submissions[1]);
      expect(remote.length, 1);
      expect(await outbox.pending(session), isNull);
      expect((await database.query('staff_purchase_operations')).length, 1);
      expect(
        (await repository.record(session, intent)).encoded,
        recovered.encoded,
      );
      expect(submissions.length, 2);
      expect(await database.query('products'), [
        {'id': 1, 'stock': 100.0, 'cost': 77.0},
      ]);
      expect(await database.query('purchases'), [
        {
          'id': 1,
          'total': 999.0,
          'payment_condition': null,
          'payment_method': null,
          'credit_days': null,
          'due_date': null,
          'paid_amount': null,
          'balance_due': null,
        },
      ]);
      expect((recovered.json['stock_before'] as List).last['cost'], isNull);
    },
  );

  test(
    'denies other modules, inactivity, pending passwords and offline checks without starting a purchase',
    () async {
      for (final change in [
        {
          'allowed_modules': ['inventory', 'reports', 'quick_sale'],
        },
        {'is_active': false},
        {'must_change_password': true},
      ]) {
        final valid = Map<String, Object?>.from(membership);
        membership.addAll(change);
        await expectLater(
          repository.record(session, draft()),
          throwsStateError,
        );
        membership = valid;
      }
      membershipOffline = true;
      await expectLater(
        repository.record(session, draft()),
        throwsA(isA<http.ClientException>()),
      );
      expect(await outbox.pending(session), isNull);
      expect(submissions, isEmpty);
    },
  );

  test(
    'keeps malformed or mismatched confirmations pending rather than accepting success-shaped responses',
    () async {
      final intent = draft();
      final changes = <Object? Function(Map<String, dynamic>)>[
        (_) => null,
        (_) => [],
        (r) => r..['actor_id'] = 'another',
        (r) => r..['billar_id'] = 'B',
        (r) => r..['request_id'] = draft().requestId,
        (r) {
          r['purchase']['total'] = 1;
          return r;
        },
        (r) {
          r['purchase']['cancelled'] = true;
          return r;
        },
        (r) {
          r['items'][0]['cost_per_unit'] = null;
          return r;
        },
        (r) {
          r['items'][0]['stock_product_id'] = 99;
          return r;
        },
        (r) {
          r['stock_after'][0]['stock'] = 999;
          return r;
        },
        (r) {
          r['stock_after'][0]['stock_revision'] = 0;
          return r;
        },
        (r) {
          r['stock_after'][0]['cost'] = null;
          return r;
        },
        (r) {
          r['stock_before'][0].remove('cost');
          return r;
        },
        (r) {
          r['stock_after'].add(r['stock_after'][0]);
          return r;
        },
      ];
      for (final change in changes) {
        corrupt = change;
        await expectLater(
          repository.record(session, intent),
          throwsA(isA<FormatException>()),
        );
        expect(
          (await outbox.pending(session))!.draft.requestId,
          intent.requestId,
        );
      }
      corrupt = null;
      expect((await repository.recover(session))!.purchaseId, 12);
      expect(remote.length, 1);
    },
  );

  test(
    'post-send revocation or a changed session never acknowledges an uncertain operation',
    () async {
      onRpc = () => membership['allowed_modules'] = ['reports'];
      await expectLater(repository.record(session, draft()), throwsStateError);
      final id = (await outbox.pending(session))!.draft.requestId;
      expect(remote.length, 1);
      membership['allowed_modules'] = ['purchases'];
      onRpc = () => generation += 2;
      await expectLater(repository.recover(session), throwsStateError);
      expect(submissions.length, 2);
      onRpc = null;
      await expectLater(repository.recover(session), throwsStateError);
      session = (
        actorId: session.actorId,
        billarId: session.billarId,
        token: session.token,
        authSession: session.authSession,
        scopeGeneration: generation,
      );
      expect((await outbox.pending(session))!.draft.requestId, id);
      expect((await repository.recover(session))!.purchaseId, 12);
      expect(remote.length, 1);
      membership['allowed_modules'] = [];
      final completed = StaffPurchaseDraft.restore(
        id,
        (await database.query('staff_purchase_operations')).single['payload']
            as String,
      );
      await expectLater(
        repository.record(session, completed),
        throwsStateError,
      );
    },
  );

  test(
    'a failed local commit retains the same operation for idempotent recovery',
    () async {
      await database.execute(
        '''CREATE TRIGGER fixture_fail_ack BEFORE UPDATE OF receipt ON staff_purchase_operations
      BEGIN SELECT RAISE(ABORT, 'No se pudo guardar el comprobante'); END''',
      );
      try {
        await expectLater(
          repository.record(session, draft()),
          throwsA(isA<DatabaseException>()),
        );
        expect(await outbox.pending(session), isNotNull);
        expect(remote.length, 1);
      } finally {
        await database.execute('DROP TRIGGER fixture_fail_ack');
      }
      expect((await repository.recover(session))!.purchaseId, 12);
      expect(submissions[0], submissions[1]);
      expect(remote.length, 1);
    },
  );

  test(
    'pending rows are isolated by actor and business and duplicate preparations share the request',
    () async {
      final intent = draft();
      final prepared = await Future.wait([
        outbox.prepare(session, intent),
        outbox.prepare(session, draft()),
      ]);
      expect(prepared[0].draft.requestId, prepared[1].draft.requestId);
      final other = draft();
      await database.insert('staff_purchase_operations', {
        'request_id': other.requestId,
        'actor_id': 'another',
        'billar_id': 'B',
        'payload': other.encodedPayload,
      });
      expect(
        (await outbox.pending(session))!.draft.requestId,
        intent.requestId,
      );
      await expectLater(outbox.prepare(session, other), throwsStateError);
      expect((await database.query('staff_purchase_operations')).length, 2);
    },
  );
}
