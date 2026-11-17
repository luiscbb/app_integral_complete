import 'dart:convert';

import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/quick_sale/data/staff_sale_catalog_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const actor = '00000000-0000-0000-0000-000000000001';
  late MockClient transport;
  late SupabaseClient client;
  late SyncSession session;
  late StaffSaleCatalogRepository repository;
  late Map<String, Object?> membership;
  late Map<String, Object?> product;
  Object? response;
  var catalogCalls = 0;
  var generation = 1;
  var changeScopeAt = '';
  var rejectCatalog = false;

  setUp(() async {
    membership = {
      'billar_id': 'A',
      'role': 'manager',
      'is_active': true,
      'must_change_password': false,
      'username': 'caja',
      'allowed_modules': ['quick_sale'],
    };
    product = {
      'id': 1,
      'billar_id': 'A',
      'barcode': '123',
      'name': 'Producto',
      'description': null,
      'price': 10,
      'stock': 3.5,
      'image_path': 'product_images/A/producto.png',
      'is_promo': 0,
      'parent_id': null,
      'pieces_per_unit': 1,
      'category': 'Bebidas',
      'presentation': null,
      'inventory_stock': 3.5,
      'stock_revision': 1,
      'components': [],
    };
    response = [product];
    catalogCalls = 0;
    generation = 1;
    changeScopeAt = '';
    rejectCatalog = false;
    transport = MockClient((request) async {
      Object? data;
      var status = 200;
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
          expect(request.url.queryParameters['user_id'], 'eq.$actor');
          expect(request.url.queryParameters['billar_id'], 'eq.A');
          if (changeScopeAt == 'membership') generation++;
          data = membership;
        } else if (request.url.path == '/rest/v1/rpc/staff_sale_products') {
          expect(jsonDecode(request.body), {'p_billar_id': 'A'});
          catalogCalls++;
          if (changeScopeAt == 'catalog') generation++;
          if (rejectCatalog) {
            status = 403;
            data = {'code': '42501', 'message': 'Sin permiso'};
          } else {
            data = response;
          }
        } else {
          throw StateError(
            'Unexpected request: ${request.method} ${request.url}',
          );
        }
      }
      return http.Response(
        jsonEncode(data),
        status,
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
    repository = StaffSaleCatalogRepository(client, (expected) {
      if (generation != expected.scopeGeneration ||
          expected.actorId != client.auth.currentUser?.id ||
          expected.billarId != 'A' ||
          !identical(client.auth.currentSession, expected.authSession)) {
        throw StateError('La sesión o el billar cambió.');
      }
    });
  });

  tearDown(() async {
    await client.dispose();
    transport.close();
  });

  test('loads the cost-free RPC and revalidates access on each read', () async {
    final catalog = await repository.load(session);
    expect(catalog.single.id, 1);
    expect(catalog.single.name, 'Producto');
    expect(catalog.single.price, 10);
    expect(catalog.single.stock, 3.5);
    expect(catalog.single.imagePath, 'product_images/A/producto.png');
    expect(catalogCalls, 1);

    membership['allowed_modules'] = ['reports'];
    await expectLater(repository.load(session), throwsStateError);
    expect(catalogCalls, 1);
    membership['allowed_modules'] = ['quick_sale'];
    response = [];
    expect(await repository.load(session), isEmpty);
    expect(catalogCalls, 2);
  });

  test('rejects foreign, duplicate or malformed product snapshots', () async {
    final valid = Map<String, Object?>.from(product);
    for (final change in [
      {'billar_id': 'B'},
      {'id': 0},
      {'name': ''},
      {'price': -1},
      {'price': '10'},
      {'stock': 'Infinity'},
      {'is_promo': 2},
      {'pieces_per_unit': 0},
      {'inventory_stock': '10'},
      {'stock_revision': -1},
      {
        'components': [
          {'product_id': 2, 'quantity': 1},
        ],
      },
      {'parent_id': 1},
      {'image_path': 123},
    ]) {
      response = [
        {...valid, ...change},
      ];
      await expectLater(
        repository.load(session),
        throwsA(isA<FormatException>()),
      );
    }
    for (final invalid in [
      {'products': []},
      [null],
      [valid, valid],
    ]) {
      response = invalid;
      await expectLater(
        repository.load(session),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test(
    'does not expose results after scope changes during either read',
    () async {
      changeScopeAt = 'membership';
      await expectLater(repository.load(session), throwsStateError);
      expect(catalogCalls, 0);
      generation = 1;
      changeScopeAt = 'catalog';
      await expectLater(repository.load(session), throwsStateError);
      expect(catalogCalls, 1);
    },
  );

  test('denied or failed reads never return cached success', () async {
    await repository.load(session);
    rejectCatalog = true;
    await expectLater(
      repository.load(session),
      throwsA(isA<PostgrestException>()),
    );
    expect(catalogCalls, 2);
    rejectCatalog = false;
    membership['must_change_password'] = true;
    await expectLater(repository.load(session), throwsStateError);
    membership['must_change_password'] = false;
    membership['is_active'] = false;
    await expectLater(repository.load(session), throwsStateError);
    expect(catalogCalls, 2);
  });
}
