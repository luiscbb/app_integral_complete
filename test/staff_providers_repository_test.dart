import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/purchases/data/repositories/staff_provider_outbox.dart';
import 'package:app_integral_complete/features/purchases/data/repositories/staff_providers_repository.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/provider_entity.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/staff_provider_operation.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/staff_operation_rejection.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/staff_purchase_data.dart';
import 'package:app_integral_complete/features/purchases/presentation/widgets/staff_provider_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:supabase_flutter/supabase_flutter.dart';

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
  late StaffProviderOutbox outbox;
  late StaffProvidersRepository repository;
  late Map<String, Object?> membership;
  late List<Map<String, dynamic>> submissions;
  late List<Map<String, dynamic>> resolutions;
  late Map<String, Map<String, dynamic>> remote;
  late Map<int, List<Map<String, dynamic>>> links;
  var generation = 1;
  var loseResponse = false;
  var rpcUnavailable = false;
  void Function()? onRpc;
  void Function()? onRead;
  void Function(Map<String, dynamic>)? corrupt;

  StaffProviderDraft draft({String name = 'Proveedor', int? id = 100}) =>
      StaffProviderDraft.save(
        provider: ProviderEntity(
          id: id,
          name: name,
          creditDays: 30,
          preferredPaymentMethod: 'credito',
          visitDays: const ['Lunes'],
        ),
        productIds: [1, 99],
      );

  void attach() {
    outbox = StaffProviderOutbox(database, (expected) {
      if (expected.actorId != client.auth.currentUser?.id ||
          expected.billarId != 'A' ||
          expected.scopeGeneration != generation ||
          !identical(expected.authSession, client.auth.currentSession) ||
          expected.token != client.auth.currentSession?.accessToken) {
        throw StateError('La sesión o el billar cambió.');
      }
    });
    repository = StaffProvidersRepository(client, outbox);
  }

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('staff_providers_');
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
        version: 52,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE providers (id INTEGER PRIMARY KEY, name TEXT)',
          );
          await db.insert('providers', {'id': 8, 'name': 'Propietario'});
          await db.execute(
            'CREATE TABLE staff_purchase_operations (request_id TEXT, payload TEXT)',
          );
          await db.insert('staff_purchase_operations', {
            'request_id': 'purchase-pending',
            'payload': '{"p_reference":"No cambiar"}',
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
    await database.delete('staff_provider_operations');
    generation = 1;
    loseResponse = false;
    rpcUnavailable = false;
    onRpc = null;
    onRead = null;
    corrupt = null;
    submissions = [];
    resolutions = [];
    remote = {};
    links = {
      0: [
        {
          'id': 4,
          'provider_id': 100,
          'product_id': 1,
          'providers': {'billar_id': 'A'},
        },
      ],
      4: [
        {
          'id': 9,
          'provider_id': 100,
          'product_id': 99,
          'providers': {'billar_id': 'A'},
        },
      ],
    };
    membership = {
      'billar_id': 'A',
      'role': 'manager',
      'is_active': true,
      'must_change_password': false,
      'username': 'compras',
      'allowed_modules': ['purchases'],
    };
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
          expect(request.url.queryParameters['user_id'], 'eq.$actor');
          expect(request.url.queryParameters['billar_id'], 'eq.A');
          data = membership;
        } else if (request.url.path == '/rest/v1/provider_products') {
          expect(request.method, 'GET');
          expect(request.url.queryParameters['providers.billar_id'], 'eq.A');
          expect(request.url.queryParameters['provider_id'], 'eq.100');
          expect(request.url.queryParameters['order'], startsWith('id.asc'));
          final cursor = int.parse(
            request.url.queryParameters['id']!.substring(3),
          );
          onRead?.call();
          data = links[cursor] ?? [];
        } else if (request.url.path ==
            '/rest/v1/rpc/resolve_staff_purchase_request') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final pending = (await outbox.pending(session))!;
          expect(body['p_request_id'], pending.draft.requestId);
          expect(body['p_kind'], 'provider');
          expect(body['p_billar_id'], 'A');
          expect(
            body['p_request_payload'],
            StaffOperationRejection.requestPayload(pending.draft.parameters),
          );
          resolutions.add(body);
          if (rpcUnavailable) {
            return http.Response(
              jsonEncode({'code': 'PGRST202', 'message': 'RPC no instalada'}),
              404,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          final canonical = remote.putIfAbsent(
            pending.draft.requestId,
            () => {
              'status': 'rejected',
              'reason_code': 'not_applied_closed',
              'kind': 'provider',
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
          corrupt?.call(copy);
          data = copy;
        } else if (request.url.path ==
            '/rest/v1/rpc/apply_staff_provider_operation') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final pending = (await outbox.pending(session))!;
          expect(body['p_request_id'], pending.draft.requestId);
          expect(body['p_provider_id'], pending.draft.providerId);
          expect(body['p_provider'], pending.draft.parameters['p_provider']);
          expect(
            body['p_product_ids'],
            pending.draft.parameters['p_product_ids'],
          );
          expect(body['p_billar_id'], 'A');
          expect(body.containsKey('p_actor_id'), false);
          submissions.add(body);
          if (rpcUnavailable) {
            return http.Response(
              jsonEncode({'code': 'PGRST202', 'message': 'RPC no instalada'}),
              404,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          final receipt = remote.putIfAbsent(
            body['p_request_id'] as String,
            () => {
              'request_id': body['p_request_id'],
              'actor_id': actor,
              'billar_id': 'A',
              'provider_id': body['p_provider_id'],
              'operation': body['p_operation'],
              'provider': {
                ...(body['p_provider'] as Map<String, dynamic>),
                'id': body['p_provider_id'],
                'billar_id': 'A',
                'is_active': body['p_operation'] != 'archive',
              },
              'product_ids':
                  body['p_operation'] == 'archive'
                      ? [1, 99]
                      : body['p_product_ids'],
            },
          );
          onRpc?.call();
          if (loseResponse) throw http.ClientException('Respuesta perdida');
          final copy = jsonDecode(jsonEncode(receipt)) as Map<String, dynamic>;
          corrupt?.call(copy);
          data = copy;
        } else {
          throw StateError(
            'Solicitud inesperada: ${request.method} ${request.url.path}',
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
    'migration 53 preserves owner data and immutable purchase requests',
    () async {
      expect(await database.query('providers'), [
        {'id': 8, 'name': 'Propietario'},
      ]);
      expect(await database.query('staff_purchase_operations'), [
        {
          'request_id': 'purchase-pending',
          'payload': '{"p_reference":"No cambiar"}',
        },
      ]);
      final first = await outbox.prepare(session, draft());
      await expectLater(
        database.insert('staff_provider_operations', {
          'request_id': draft(name: 'Otra').requestId,
          'actor_id': actor,
          'billar_id': 'A',
          'payload': first.draft.encodedPayload,
        }),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        (await outbox.pending(session))!.draft.requestId,
        first.draft.requestId,
      );
    },
  );

  test(
    'freezes new provider ID, relations and terms and rejects invalid persisted payloads',
    () {
      final days = ['Lunes'];
      final ids = [1, 99];
      final intent = StaffProviderDraft.save(
        provider: ProviderEntity(
          name: 'Nuevo',
          visitDays: days,
          creditDays: 30,
          preferredPaymentMethod: 'credito',
        ),
        productIds: ids,
      );
      days.clear();
      ids.clear();
      final restored = StaffProviderDraft.restore(
        intent.requestId,
        intent.encodedPayload,
      );
      expect(restored.operation, 'create');
      expect(restored.providerId, greaterThan(0));
      expect(restored.parameters['p_product_ids'], [1, 99]);
      expect((restored.parameters['p_provider'] as Map)['visit_days'], 'Lunes');
      final changedCopy = restored.parameters;
      changedCopy['p_provider_id'] = 1;
      expect(restored.providerId, intent.providerId);
      for (final change in [
        {'p_provider_id': 0},
        {'p_operation': 'delete'},
        {
          'p_product_ids': [1, 1],
        },
        {
          'p_product_ids': [null],
        },
        {'p_provider': <String, dynamic>{}},
        {'extra': true},
      ]) {
        expect(
          () => StaffProviderDraft.restore(
            intent.requestId,
            jsonEncode({...intent.parameters, ...change}),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'lost create response survives reopening and recovers exactly the saved request',
    () async {
      final intent = draft(id: null);
      loseResponse = true;
      await expectLater(
        repository.apply(session, intent),
        throwsA(isA<http.ClientException>()),
      );
      await expectLater(
        repository.apply(session, draft(name: 'Otra')),
        throwsStateError,
      );
      await database.close();
      database = await ffi.databaseFactoryFfi.openDatabase(dbPath);
      attach();
      final pending = (await outbox.pending(session))!;
      expect(pending.draft.encodedPayload, intent.encodedPayload);
      expect(pending.draft.providerId, intent.providerId);
      loseResponse = false;
      final receipt = (await repository.recover(session))!;
      expect(receipt.operation, 'create');
      expect(submissions, hasLength(2));
      expect(submissions.first, submissions.last);
      expect(remote, hasLength(1));
      expect(await outbox.pending(session), isNull);
      expect((await database.query('providers')).single['name'], 'Propietario');
    },
  );

  test(
    'does not confirm malformed, foreign or financially incomplete receipts',
    () async {
      final intent = draft();
      for (final change in <void Function(Map<String, dynamic>)>[
        (row) => row['actor_id'] = 'another',
        (row) => row['billar_id'] = 'B',
        (row) => row['request_id'] = draft().requestId,
        (row) => row['operation'] = 'archive',
        (row) => (row['provider'] as Map)['is_active'] = false,
        (row) => (row['provider'] as Map)['billar_id'] = 'B',
        (row) => (row['provider'] as Map).remove('credit_days'),
        (row) =>
            (row['provider'] as Map)['preferred_payment_method'] = 'efectivo',
        (row) => row['product_ids'] = [1],
        (row) => row['product_ids'] = [1, 1],
      ]) {
        corrupt = change;
        await expectLater(
          repository.apply(session, intent),
          throwsFormatException,
        );
        expect(
          (await outbox.pending(session))!.draft.requestId,
          intent.requestId,
        );
      }
      corrupt = null;
      expect((await repository.recover(session))!.providerId, 100);
      expect(remote, hasLength(1));
    },
  );

  test(
    'requires purchase permission and keeps uncertain operations after revocation or session change',
    () async {
      membership['allowed_modules'] = ['inventory'];
      await expectLater(repository.apply(session, draft()), throwsStateError);
      expect(submissions, isEmpty);
      expect(await outbox.pending(session), isNull);
      membership['allowed_modules'] = ['purchases'];
      onRpc = () => membership['is_active'] = false;
      await expectLater(repository.apply(session, draft()), throwsStateError);
      expect(await outbox.pending(session), isNotNull);
      onRpc = null;
      await expectLater(repository.recover(session), throwsStateError);
      expect(submissions, hasLength(1));
      membership['is_active'] = true;
      onRpc = () => generation++;
      await expectLater(repository.recover(session), throwsStateError);
      generation = 1;
      onRpc = null;
      expect(await outbox.pending(session), isNotNull);
      await repository.recover(session);
      expect(await outbox.pending(session), isNull);
    },
  );

  test(
    'missing RPC never falls back to owner writes or discards the pending request',
    () async {
      rpcUnavailable = true;
      final intent = draft();
      await expectLater(
        repository.apply(session, intent),
        throwsA(isA<PostgrestException>()),
      );
      expect(
        (await outbox.pending(session))!.draft.requestId,
        intent.requestId,
      );
      expect(remote, isEmpty);
      rpcUnavailable = false;
      await repository.recover(session);
      expect(submissions.first, submissions.last);
    },
  );

  test(
    'failed local receipt commit remains recoverable without repeating the mutation',
    () async {
      final intent = draft();
      await database.execute('''
      CREATE TRIGGER reject_provider_receipt BEFORE UPDATE OF receipt
      ON staff_provider_operations BEGIN
        SELECT RAISE(ABORT, 'No se pudo guardar el comprobante');
      END
    ''');
      try {
        await expectLater(
          repository.apply(session, intent),
          throwsA(isA<DatabaseException>()),
        );
        expect(
          (await outbox.pending(session))!.draft.requestId,
          intent.requestId,
        );
        expect(remote, hasLength(1));
      } finally {
        await database.execute('DROP TRIGGER reject_provider_receipt');
      }
      await repository.recover(session);
      expect(await outbox.pending(session), isNull);
      expect(submissions.first, submissions.last);
      expect(remote, hasLength(1));
    },
  );

  test(
    'loads all scoped provider links through short pages and rejects foreign or duplicate links',
    () async {
      expect(await repository.productIds(session, 100), [1, 99]);
      for (final change in [
        {'provider_id': 101},
        {'product_id': 0},
        {'id': 0},
        {
          'providers': {'billar_id': 'B'},
        },
      ]) {
        final valid = Map<String, dynamic>.from(links[0]!.single);
        links[0] = [
          {...valid, ...change},
        ];
        await expectLater(
          repository.productIds(session, 100),
          throwsFormatException,
        );
        links[0] = [valid];
      }
      links[4]!.single['product_id'] = 1;
      await expectLater(
        repository.productIds(session, 100),
        throwsFormatException,
      );
      links[4]!.single['product_id'] = 99;
      onRead = () => generation++;
      await expectLater(repository.productIds(session, 100), throwsStateError);
    },
  );

  test(
    'provider resolution recovers an applied receipt without a new mutation',
    () async {
      final intent = draft();
      loseResponse = true;
      await expectLater(
        repository.apply(session, intent),
        throwsA(isA<http.ClientException>()),
      );
      loseResponse = false;
      expect(
        (await repository.resolvePending(session))!.providerId,
        intent.providerId,
      );
      expect(await outbox.pending(session), isNull);
      expect(submissions, hasLength(1));
      expect(resolutions, hasLength(1));
      expect(remote, hasLength(1));
    },
  );

  test(
    'provider closure requires a validated server response, survives restart and never resends its UUID',
    () async {
      final intent = draft();
      await outbox.prepare(session, intent);
      rpcUnavailable = true;
      await expectLater(
        repository.resolvePending(session),
        throwsA(isA<PostgrestException>()),
      );
      expect(await outbox.pending(session), isNotNull);
      expect(remote, isEmpty);
      rpcUnavailable = false;
      loseResponse = true;
      await expectLater(
        repository.resolvePending(session),
        throwsA(isA<http.ClientException>()),
      );
      loseResponse = false;
      for (final change in <void Function(Map<String, dynamic>)>[
        (row) => row['actor_id'] = 'another',
        (row) => row['kind'] = 'purchase',
        (row) => (row['request_payload'] as Map)['provider_id'] = 999,
        (row) =>
            ((row['request_payload'] as Map)['provider']
                    as Map)['credit_days'] =
                60,
      ]) {
        corrupt = change;
        await expectLater(
          repository.resolvePending(session),
          throwsFormatException,
        );
        expect(await outbox.pending(session), isNotNull);
      }
      corrupt = null;
      onRpc = () => membership['is_active'] = false;
      await expectLater(repository.resolvePending(session), throwsStateError);
      onRpc = null;
      await expectLater(repository.resolvePending(session), throwsStateError);
      membership['is_active'] = true;
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
        repository.apply(session, intent),
        throwsA(isA<StaffOperationRejection>()),
      );
      expect(submissions.length, calls);
      expect(
        (await database.query('staff_provider_operations')).single['payload'],
        intent.encodedPayload,
      );
      await repository.apply(session, draft(name: 'Corregido'));
      expect(await outbox.pending(session), isNull);
    },
  );

  test(
    'archive keeps historical relations and never deletes owner data',
    () async {
      final receipt = await repository.apply(
        session,
        StaffProviderDraft.archive(100),
      );
      expect(receipt.operation, 'archive');
      expect(jsonDecode(receipt.encoded)['product_ids'], [1, 99]);
      expect(submissions.single['p_provider'], isEmpty);
      expect(submissions.single['p_product_ids'], isEmpty);
      expect((await database.query('providers')).single['name'], 'Propietario');
    },
  );

  testWidgets(
    'provider dialog preserves unavailable links and exposes editable credit defaults',
    (tester) async {
      StaffProviderDraft? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder:
                  (context) => TextButton(
                    onPressed: () async {
                      saved = await showDialog<StaffProviderDraft>(
                        context: context,
                        builder:
                            (_) => const StaffProviderDialog(
                              provider: ProviderEntity(
                                id: 100,
                                name: 'Proveedor',
                                creditDays: 30,
                                preferredPaymentMethod: 'credito',
                              ),
                              productIds: [1, 99],
                              products: [
                                StaffPurchaseProduct(
                                  id: 1,
                                  name: 'Unidad',
                                  cost: 5,
                                  parentId: null,
                                  piecesPerUnit: 1,
                                ),
                              ],
                            ),
                      );
                    },
                    child: const Text('ABRIR'),
                  ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ABRIR'));
      await tester.pumpAndSettle();
      expect(find.text('Crédito'), findsOneWidget);
      final credit = find.widgetWithText(TextFormField, 'Días de crédito');
      await tester.ensureVisible(credit);
      await tester.enterText(credit, '-1');
      await tester.tap(find.text('GUARDAR PROVEEDOR'));
      await tester.pumpAndSettle();
      expect(
        find.text('Ingresa días enteros entre 0 y 2147483647.'),
        findsOneWidget,
      );
      await tester.enterText(credit, '45');
      final hidden = find.widgetWithText(
        FilterChip,
        'Producto #99 no disponible',
      );
      await tester.ensureVisible(hidden);
      expect(tester.widget<FilterChip>(hidden).selected, true);
      await tester.tap(find.text('GUARDAR PROVEEDOR'));
      await tester.pumpAndSettle();
      expect(saved!.parameters['p_product_ids'], [1, 99]);
      expect((saved!.parameters['p_provider'] as Map)['credit_days'], 45);
      expect(
        (saved!.parameters['p_provider'] as Map)['preferred_payment_method'],
        'credito',
      );
    },
  );
}
