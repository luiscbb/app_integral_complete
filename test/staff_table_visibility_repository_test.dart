import 'dart:convert';

import 'package:app_integral_complete/core/services/sync_session.dart';
import 'package:app_integral_complete/features/sales/data/repositories/staff_table_visibility_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final auth =
      Session.fromJson({
        'access_token': 'token',
        'token_type': 'bearer',
        'user': {
          'id': '00000000-0000-4000-8000-000000000001',
          'aud': 'authenticated',
          'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{},
          'created_at': '2025-01-01T00:00:00Z',
        },
      })!;
  final SyncSession session = (
    actorId: auth.user.id,
    billarId: 'A',
    token: 'token',
    authSession: auth,
    scopeGeneration: 1,
  );
  final items = [
    {
      'id': 7,
      'billar_id': 'A',
      'name': 'Mesa libre',
      'table_type': 'Billar',
      'is_occupied': 0,
      'start_time': null,
      'orders': '[]',
      'is_deleted': 0,
      'service_id': null,
      'service_actor_id': null,
      'service_state': null,
      'service_items': <dynamic>[],
    },
    {
      'id': 9,
      'billar_id': 'A',
      'name': 'Mesa propia',
      'table_type': 'Billar',
      'is_occupied': 1,
      'start_time': '2026-11-18T17:00:00Z',
      'orders':
          '[{"request_id":"20000000-0000-4000-8000-000000000001","productId":1,"productName":"Agua","price":10,"quantity":1,"recorded_at":"2026-11-18T17:10:00Z"}]',
      'is_deleted': 0,
      'service_id': '10000000-0000-4000-8000-000000000001',
      'service_actor_id': auth.user.id,
      'service_state': 'active',
      'service_items': [
        {
          'request_id': '20000000-0000-4000-8000-000000000001',
          'productId': 1,
          'productName': 'Agua',
          'price': 10.0,
          'quantity': 1.0,
          'recorded_at': '2026-11-18T17:10:00Z',
        },
      ],
    },
  ];

  test(
    'requests the authenticated visibility scope and validates its rows',
    () async {
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/rest/v1/rpc/staff_table_visible_tables');
          expect(request.headers['authorization'], 'Bearer token');
          expect(jsonDecode(request.body), {
            'requested_billar_id': 'A',
            'requested_table_type': 'Billar',
          });
          return http.Response(
            jsonEncode({
              'billar_id': 'A',
              'table_type': 'Billar',
              'items': items,
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      try {
        final repository = StaffTableVisibilityRepository(client, (_) {});
        final tables = await repository.read(
          session: session,
          tableType: 'Billar',
        );
        expect(tables.map((table) => table['id']), [7, 9]);
        expect(tables.last['service_actor_id'], session.actorId);
        expect(jsonDecode(tables.last['orders'] as String), hasLength(1));
      } finally {
        await client.dispose();
      }
    },
  );

  test(
    'rejects responses from another business or duplicate table ids',
    () async {
      var calls = 0;
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          final scopeMismatch = calls++ == 1;
          return http.Response(
            jsonEncode({
              'billar_id': scopeMismatch ? 'B' : 'A',
              'table_type': 'Billar',
              'items': scopeMismatch ? [] : [items.first, items.first],
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      try {
        final repository = StaffTableVisibilityRepository(client, (_) {});
        await expectLater(
          repository.read(session: session, tableType: 'Invalid'),
          throwsArgumentError,
        );
        await expectLater(
          repository.read(session: session, tableType: 'Billar'),
          throwsFormatException,
        );
        await expectLater(
          repository.read(session: session, tableType: 'Comanda'),
          throwsFormatException,
        );
      } finally {
        await client.dispose();
      }
    },
  );

  test(
    'scopes cached visibility by actor and filters services after view permission is removed',
    () async {
      ffi.sqfliteFfiInit();
      final database = await ffi.databaseFactoryFfi.openDatabase(
        ffi.inMemoryDatabasePath,
        options: ffi.OpenDatabaseOptions(
          version: 1,
          onCreate:
              (db, _) => db.execute('''
              CREATE TABLE staff_table_visibility_cache (
                actor_id TEXT NOT NULL,
                billar_id TEXT NOT NULL,
                table_type TEXT NOT NULL,
                payload TEXT NOT NULL,
                fetched_at TEXT NOT NULL,
                PRIMARY KEY (actor_id, billar_id, table_type)
              )
            '''),
        ),
      );
      final otherService =
          Map<String, dynamic>.from(items.last)
            ..['id'] = 10
            ..['service_id'] = '10000000-0000-4000-8000-000000000002'
            ..['service_actor_id'] = '00000000-0000-4000-8000-000000000002';
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'billar_id': 'A',
              'table_type': 'Billar',
              'items': [...items, otherService],
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      try {
        final repository = StaffTableVisibilityRepository(
          client,
          (_) {},
          database: database,
        );
        await repository.read(session: session, tableType: 'Billar');
        final cached = await repository.readCached(
          session: session,
          tableType: 'Billar',
          canViewAll: true,
        );
        expect(cached?.tables.map((table) => table['id']), [7, 9, 10]);
        expect(cached?.fetchedAt, isA<DateTime>());

        final restrictedCache = await repository.readCached(
          session: session,
          tableType: 'Billar',
          canViewAll: false,
        );
        expect(restrictedCache?.tables.map((table) => table['id']), [7, 9]);

        final SyncSession anotherActor = (
          actorId: '00000000-0000-4000-8000-000000000002',
          billarId: session.billarId,
          token: session.token,
          authSession: session.authSession,
          scopeGeneration: session.scopeGeneration,
        );
        final SyncSession anotherBusiness = (
          actorId: session.actorId,
          billarId: 'B',
          token: session.token,
          authSession: session.authSession,
          scopeGeneration: session.scopeGeneration,
        );
        expect(
          await repository.readCached(
            session: anotherActor,
            tableType: 'Billar',
            canViewAll: false,
          ),
          isNull,
        );
        expect(
          await repository.readCached(
            session: anotherBusiness,
            tableType: 'Billar',
            canViewAll: false,
          ),
          isNull,
        );
      } finally {
        await client.dispose();
        await database.close();
      }
    },
  );
}
