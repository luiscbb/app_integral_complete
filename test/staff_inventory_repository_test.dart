import 'dart:convert';

import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/inventory/data/repositories/staff_inventory_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const actor = '00000000-0000-0000-0000-000000000001';
  late MockClient transport;
  late SupabaseClient client;
  late SyncSession session;
  late StaffInventoryRepository repository;
  late Map<String, Object?> membership;
  late Map<String, Object?> product;
  late Map<int, Object?> pages;
  var productCalls = 0;
  var membershipCalls = 0;
  var generation = 1;
  var changeScopeAt = '';
  var revokeDuringRead = false;
  var rejectProducts = false;

  setUp(() async {
    membership = {
      'billar_id': 'A',
      'role': 'manager',
      'is_active': true,
      'must_change_password': false,
      'username': 'caja',
      'allowed_modules': ['inventory'],
    };
    product = {
      'id': 1,
      'billar_id': 'A',
      'name': 'Producto',
      'barcode': 'COD-1',
      'category': 'Bebidas',
      'presentation': null,
      'price': 12,
      'cost': 7,
      'stock': 3.5,
      'is_active': true,
      'is_promo': 0,
      'parent_id': null,
    };
    pages = {
      0: [product],
    };
    productCalls = 0;
    membershipCalls = 0;
    generation = 1;
    changeScopeAt = '';
    revokeDuringRead = false;
    rejectProducts = false;
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
        expect(request.method, 'GET');
        expect(request.headers['authorization'], 'Bearer ${session.token}');
        if (request.url.path == '/rest/v1/business_memberships') {
          membershipCalls++;
          expect(request.url.queryParameters['user_id'], 'eq.$actor');
          expect(request.url.queryParameters['billar_id'], 'eq.A');
          if (changeScopeAt == 'membership' ||
              changeScopeAt == 'confirmation' && membershipCalls == 2) {
            generation++;
          }
          data = membership;
        } else if (request.url.path == '/rest/v1/products') {
          productCalls++;
          expect(request.url.queryParameters['billar_id'], 'eq.A');
          expect(request.url.queryParameters['is_active'], 'eq.true');
          expect(request.url.queryParameters['order'], startsWith('id.asc'));
          expect(request.url.queryParameters['limit'], '500');
          expect(
            request.url.queryParameters['select']!.split(','),
            contains('cost'),
          );
          expect(request.url.queryParameters['select'], isNot(contains('*')));
          if (changeScopeAt == 'products') generation++;
          if (revokeDuringRead) membership['allowed_modules'] = ['quick_sale'];
          if (rejectProducts) {
            status = 403;
            data = {'code': '42501', 'message': 'Sin permiso de inventario'};
          } else {
            final cursor = int.parse(
              request.url.queryParameters['id']!.substring(3),
            );
            data = pages[cursor] ?? [];
          }
        } else {
          throw StateError(
            'Unexpected inventory request: ${request.method} ${request.url}',
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
    repository = StaffInventoryRepository(client, (expected) {
      if (generation != expected.scopeGeneration ||
          expected.actorId != client.auth.currentUser?.id ||
          !identical(client.auth.currentSession, expected.authSession)) {
        throw StateError('La sesión o el billar cambió.');
      }
    });
  });

  tearDown(() async {
    await client.dispose();
    transport.close();
  });

  test(
    'reads costs without writes, follows short keyset pages and verifies final access',
    () async {
      pages[1] = [
        {...product, 'id': 9, 'cost': 0, 'stock': -1},
      ];
      final products = await repository.load(session);
      expect(products.map((product) => product.id), [1, 9]);
      expect(products.first.cost, 7);
      expect(products.first.stock, 3.5);
      expect(products.last.cost, 0);
      expect(products.last.stock, -1);
      expect(productCalls, 3);
      expect(membershipCalls, 2);
    },
  );

  test(
    'refuses other modules, revoked accounts and pending passwords before fetching costs',
    () async {
      for (final change in [
        {
          'allowed_modules': ['quick_sale'],
        },
        {'is_active': false},
        {'must_change_password': true},
        {'billar_id': 'B'},
      ]) {
        final valid = Map<String, Object?>.from(membership);
        membership.addAll(change);
        await expectLater(repository.load(session), throwsStateError);
        membership = valid;
      }
      expect(productCalls, 0);
    },
  );

  test(
    'rejects foreign, inactive, invalid and repeated inventory rows rather than defaulting costs',
    () async {
      for (final change in [
        {'billar_id': 'B'},
        {'id': 0},
        {'name': ''},
        {'cost': null},
        {'cost': -1},
        {'cost': '7'},
        {'price': -1},
        {'stock': 'Infinity'},
        {'barcode': 3},
        {'category': 3},
        {'is_active': false},
        {'is_promo': 2},
        {'parent_id': 1},
      ]) {
        pages = {
          0: [
            {...product, ...change},
          ],
        };
        await expectLater(
          repository.load(session),
          throwsA(isA<FormatException>()),
        );
      }
      pages = {
        0: [product, product],
      };
      await expectLater(
        repository.load(session),
        throwsA(isA<FormatException>()),
      );
      pages = {
        0: [product],
        1: [product],
      };
      await expectLater(
        repository.load(session),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'cannot publish data after scope changes, post-read revocation or denied reads',
    () async {
      for (final stage in ['membership', 'products', 'confirmation']) {
        changeScopeAt = stage;
        generation = 1;
        membershipCalls = 0;
        await expectLater(repository.load(session), throwsStateError);
      }
      changeScopeAt = '';
      generation = 1;
      revokeDuringRead = true;
      await expectLater(repository.load(session), throwsStateError);
      revokeDuringRead = false;
      membership['allowed_modules'] = ['inventory'];
      await repository.load(session);
      rejectProducts = true;
      await expectLater(
        repository.load(session),
        throwsA(isA<PostgrestException>()),
      );
    },
  );
}
