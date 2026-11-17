import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/database/legacy_local_owner.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'legacy ownership is verified, persistent and never reassigned',
    () async {
      final directory = await Directory.systemTemp.createTemp('legacy_owner_');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      SharedPreferences.setMockInitialValues({'billar_id': 'A'});
      await PreferencesService().init();
      const first = '00000000-0000-0000-0000-000000000001';
      const second = '00000000-0000-0000-0000-000000000002';
      var membershipActive = true;
      var membershipVisible = true;
      var settingsOwner = first;
      var requests = 0;
      Completer<void>? verificationStarted;
      Completer<void>? allowVerification;
      final tokens = <String?>[];
      final client = MockClient((request) async {
        Object? data;
        if (request.url.path == '/auth/v1/token') {
          final email = (jsonDecode(request.body) as Map)['email'];
          final id = email == 'b@example.com' ? second : first;
          final payload = base64Url
              .encode(
                utf8.encode(
                  jsonEncode({
                    'sub': id,
                    'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
                  }),
                ),
              )
              .replaceAll('=', '');
          data = {
            'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'refresh-$id',
            'user': {
              'id': id,
              'aud': 'authenticated',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2025-01-01T00:00:00Z',
            },
          };
        } else if (request.url.path == '/rest/v1/billar_settings') {
          requests++;
          tokens.add(request.headers['authorization']);
          if (verificationStarted != null) {
            verificationStarted!.complete();
            await allowVerification!.future;
            verificationStarted = null;
          }
          data = {'user_id': settingsOwner, 'billar_id': 'A'};
        } else if (request.url.path == '/rest/v1/business_memberships') {
          requests++;
          tokens.add(request.headers['authorization']);
          data =
              membershipVisible
                  ? {
                    'role': 'admin',
                    'is_active': membershipActive,
                    'must_change_password': false,
                  }
                  : null;
        } else {
          throw StateError(
            'Unexpected request: ${request.method} ${request.url.path}',
          );
        }
        return http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });

      Database? db;
      try {
        await Supabase.initialize(
          url: 'http://localhost:54321',
          publishableKey: 'test-key',
          httpClient: client,
          authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
          ),
        );
        final supabase = Supabase.instance.client;
        Future<void> signIn(String email) async {
          await supabase.auth.signInWithPassword(
            email: email,
            password: 'test',
          );
        }

        await signIn('a@example.com');
        final firstToken = supabase.auth.currentSession!.accessToken;
        db = await DatabaseHelper.instance.database;
        LegacyLocalOwner owner() => LegacyLocalOwner(
          openDatabase: () async => db!,
          client: supabase,
          preferences: PreferencesService(),
        );
        await db.insert('sales_history', {
          'billar_id': 'A',
          'total': 10,
          'paid': 10,
          'date': '2026-01-01',
          'type': 'Venta Rápida',
          'payment_method': 'Efectivo',
          'synced': 0,
        });
        await db.insert('purchases', {
          'total': 10,
          'date': '2026-01-01',
          'reference': 'ANTERIOR',
          'synced': 0,
        });
        final legacySale = await db.insert('pending_sales', {
          'product': 'VENTA ANTERIOR',
          'quantity': 1,
          'price': 10,
          'created_at': '2026-01-01',
          'synced': 0,
        });
        await expectLater(owner().requireBoundOwner(), throwsStateError);
        await expectLater(
          owner().bindConfirmedLegacyData(legacyBillarId: 'B'),
          throwsStateError,
        );
        await PreferencesService().setBillarId('B');
        await expectLater(
          owner().bindConfirmedLegacyData(legacyBillarId: 'B'),
          throwsStateError,
        );
        await PreferencesService().setBillarId('A');
        final rawPreferences = await SharedPreferences.getInstance();
        final snapshot =
            rawPreferences.getString('legacy_settings_snapshot_v1')!;
        await rawPreferences.setString(
          'legacy_settings_snapshot_v1',
          '{"business_name":"Billar"}',
        );
        await expectLater(
          owner().bindConfirmedLegacyData(legacyBillarId: 'A'),
          throwsStateError,
        );
        await rawPreferences.setString('legacy_settings_snapshot_v1', snapshot);

        membershipVisible = false;
        await expectLater(
          owner().bindConfirmedLegacyData(legacyBillarId: 'A'),
          throwsStateError,
        );
        membershipVisible = true;
        membershipActive = false;
        await expectLater(
          owner().bindConfirmedLegacyData(legacyBillarId: 'A'),
          throwsStateError,
        );
        membershipActive = true;
        final unassignedProduct = await db.insert('products', {
          'billar_id': '',
          'name': 'PRODUCTO ANTERIOR',
        });
        final otherSale = await db.insert('sales_history', {
          'billar_id': 'B',
          'total': 20,
          'paid': 20,
          'date': '2026-01-01',
          'type': 'Venta Rápida',
          'payment_method': 'Efectivo',
          'synced': 0,
        });
        await expectLater(
          owner().bindConfirmedLegacyData(legacyBillarId: 'A'),
          throwsStateError,
        );
        expect(
          (await db.query(
            'products',
            where: 'id = ?',
            whereArgs: [unassignedProduct],
          )).single['billar_id'],
          '',
        );
        await db.delete(
          'sales_history',
          where: 'id = ?',
          whereArgs: [otherSale],
        );
        final otherClient = await db.insert('personal_clients', {
          'client_id': 'other-client',
          'billar_id': 'B',
          'name': 'CLIENTE',
          'created_at': '2026-01-01',
          'updated_at': '2026-01-01',
        });
        await expectLater(
          owner().bindConfirmedLegacyData(legacyBillarId: 'A'),
          throwsStateError,
        );
        await db.delete(
          'personal_clients',
          where: 'id = ?',
          whereArgs: [otherClient],
        );
        final otherDeletion = await db.insert('pending_product_deletions', {
          'billar_id': 'B',
          'product_id': 10,
        });
        await expectLater(
          owner().bindConfirmedLegacyData(legacyBillarId: 'A'),
          throwsStateError,
        );
        await db.delete(
          'pending_product_deletions',
          where: 'id = ?',
          whereArgs: [otherDeletion],
        );
        final otherPurchase = await db.insert('purchases', {
          'billar_id': 'B',
          'total': 20,
          'date': '2026-01-01',
          'reference': 'OTRO',
        });
        await expectLater(
          owner().bindConfirmedLegacyData(legacyBillarId: 'A'),
          throwsStateError,
        );
        expect(
          (await db.query(
            'purchases',
            where: 'reference = ?',
            whereArgs: ['ANTERIOR'],
          )).single['billar_id'],
          isNull,
        );
        await db.delete(
          'purchases',
          where: 'id = ?',
          whereArgs: [otherPurchase],
        );
        final otherRequest = await db.insert('pending_provider_operations', {
          'actor_id': second,
          'billar_id': 'A',
          'provider_id': 10,
          'operation': 'delete',
          'payload': 'null',
        });
        await expectLater(
          owner().bindConfirmedLegacyData(legacyBillarId: 'A'),
          throwsStateError,
        );
        await db.delete(
          'pending_provider_operations',
          where: 'id = ?',
          whereArgs: [otherRequest],
        );
        final foreignSale = await db.insert('pending_sales', {
          'actor_id': second,
          'billar_id': 'A',
          'product': 'OTRA CUENTA',
          'quantity': 1,
          'price': 10,
          'created_at': '2026-01-01',
        });
        await expectLater(
          owner().bindConfirmedLegacyData(legacyBillarId: 'A'),
          throwsStateError,
        );
        expect(
          (await db.query(
            'pending_sales',
            where: 'id = ?',
            whereArgs: [legacySale],
          )).single['actor_id'],
          isNull,
        );
        await db.delete(
          'pending_sales',
          where: 'id = ?',
          whereArgs: [foreignSale],
        );

        verificationStarted = Completer<void>();
        allowVerification = Completer<void>();
        final interrupted = owner().bindConfirmedLegacyData(
          legacyBillarId: 'A',
        );
        final interruptedAssertion = expectLater(interrupted, throwsStateError);
        await verificationStarted!.future.timeout(const Duration(seconds: 5));
        await signIn('b@example.com');
        allowVerification.complete();
        await interruptedAssertion;
        expect(tokens.last, 'Bearer $firstToken');
        await signIn('a@example.com');

        await owner().bindConfirmedLegacyData(legacyBillarId: 'A');
        expect(
          (await db.query(
            'products',
            where: 'id = ?',
            whereArgs: [unassignedProduct],
          )).single['billar_id'],
          'A',
        );
        final requestsAfterBinding = requests;
        await owner().requireBoundOwner();
        expect(requests, requestsAfterBinding);
        expect((await db.query('purchases')).single['reference'], 'ANTERIOR');
        expect((await db.query('purchases')).single['billar_id'], isNull);
        final unassignedSale =
            (await db.query(
              'pending_sales',
              where: 'id = ?',
              whereArgs: [legacySale],
            )).single;
        expect(unassignedSale['actor_id'], isNull);
        expect(unassignedSale['billar_id'], isNull);
        expect(unassignedSale['synced'], 0);
        final unverifiedSale = await db.insert('pending_sales', {
          'product': 'SIN ORIGEN',
          'quantity': 1,
          'price': 10,
          'created_at': '2026-01-02',
        });
        await owner().bindConfirmedLegacyData(legacyBillarId: 'A');
        expect(
          (await db.query(
            'pending_sales',
            where: 'id = ?',
            whereArgs: [unverifiedSale],
          )).single['actor_id'],
          isNull,
        );
        expect((await db.query('sales_history')).single['synced'], 0);
        final dbPath = db.path;
        await db.close();
        db = await ffi.databaseFactoryFfi.openDatabase(dbPath);
        await owner().requireBoundOwner();
        final reopenedSale =
            (await db.query(
              'pending_sales',
              where: 'id = ?',
              whereArgs: [legacySale],
            )).single;
        expect(reopenedSale['actor_id'], isNull);
        expect(reopenedSale['synced'], 0);
        await signIn('b@example.com');
        await expectLater(owner().requireBoundOwner(), throwsStateError);
        settingsOwner = second;
        await expectLater(
          owner().bindConfirmedLegacyData(legacyBillarId: 'A'),
          throwsStateError,
        );
        expect(
          (await db.query('legacy_local_owner')).single['actor_id'],
          first,
        );
        await signIn('a@example.com');
        final verifiedSession = supabase.auth.currentSession!;
        await db.close();
        db = null;
        final migrated = await DatabaseHelper.instance
            .migrateConfirmedLegacyDatabase(
              actorId: first,
              billarId: 'A',
              isCurrentScope:
                  () =>
                      supabase.auth.currentSession?.user.id == first &&
                      supabase.auth.currentSession?.accessToken ==
                          verifiedSession.accessToken &&
                      PreferencesService().billarId == 'A',
            );
        try {
          expect((await migrated.query('products')).single['billar_id'], 'A');
          expect(
            (await migrated.query('purchases')).single['billar_id'],
            isNull,
          );
          expect(
            (await migrated.query(
              'pending_sales',
              where: 'id = ?',
              whereArgs: [legacySale],
            )).single['synced'],
            0,
          );
          expect(await File(dbPath).exists(), isTrue);

          final legacyPreferences = PreferencesService();
          await legacyPreferences.setBusinessName('CONFIGURACIÓN ACTUAL');
          await legacyPreferences.setAdminPin('test-pin');
          final scopedPreferences = legacyPreferences.forScope(
            actorId: first,
            billarId: 'A',
            isCurrentScope:
                () =>
                    supabase.auth.currentSession?.user.id == first &&
                    supabase.auth.currentSession?.accessToken ==
                        verifiedSession.accessToken,
          );
          final migratedOwner = LegacyLocalOwner(
            openDatabase: () async => migrated,
            client: supabase,
            preferences: legacyPreferences,
          );
          final otherPreferences = legacyPreferences.forScope(
            actorId: second,
            billarId: 'A',
            isCurrentScope: () => true,
          );
          await expectLater(
            migratedOwner.migrateConfirmedPreferences(otherPreferences),
            throwsStateError,
          );
          expect(otherPreferences.businessName, 'MI BILLAR');
          await migratedOwner.migrateConfirmedPreferences(scopedPreferences);
          expect(scopedPreferences.businessName, 'CONFIGURACIÓN ACTUAL');
          expect(scopedPreferences.adminPin, 'test-pin');
          await scopedPreferences.setBusinessName('CONFIGURACIÓN NUEVA');
          await migratedOwner.migrateConfirmedPreferences(scopedPreferences);
          expect(scopedPreferences.businessName, 'CONFIGURACIÓN NUEVA');
          await signIn('b@example.com');
          await expectLater(
            migratedOwner.migrateConfirmedPreferences(scopedPreferences),
            throwsStateError,
          );
        } finally {
          await migrated.close();
        }
      } finally {
        if (db?.isOpen == true) await db!.close();
        await Supabase.instance.dispose();
        client.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
