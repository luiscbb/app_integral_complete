import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/theme/theme_provider.dart';
import 'package:app_integral_complete/features/auth/data/staff_account_creation_repository.dart';
import 'package:app_integral_complete/features/auth/data/staff_account_request_store.dart';
import 'package:app_integral_complete/features/auth/presentation/widgets/staff_management_section.dart';
import 'package:app_integral_complete/features/config/presentation/pages/config_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TestStaffAccountCreationRepository
    extends StaffAccountCreationRepository {
  TestStaffAccountCreationRepository({
    required super.client,
    required super.requests,
    required super.currentBillarId,
    required this.changes,
  });

  final Stream<AuthState> changes;

  @override
  Stream<AuthState> get authChanges => changes;
}

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(finder, findsWidgets);
}

Future<void> waitUntilAbsent(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 150 && finder.evaluate().isNotEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(finder, findsNothing);
}

void main() {
  testWidgets(
    'configuration exposes the section but keeps operations disabled',
    (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => ThemeProvider(),
          child: const MaterialApp(home: ConfigPage()),
        ),
      );
      await tester.ensureVisible(find.text('Personal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Personal'));
      await tester.pumpAndSettle();
      expect(
        find.text('La gestión de personal aún no está habilitada.'),
        findsOneWidget,
      );
      expect(find.text('AGREGAR USUARIO'), findsNothing);
    },
  );

  testWidgets(
    'forms create, recover, edit and deactivate with session isolation',
    (tester) async {
      final directory =
          (await tester.runAsync(
            () => Directory.systemTemp.createTemp('staff_management_'),
          ))!;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      final accounts = <Map<String, dynamic>>[
        {
          'user_id': '00000000-0000-0000-0000-000000000011',
          'billar_id': 'A',
          'username': 'existente',
          'full_name': 'Existente',
          'job_title': 'Caja',
          'allowed_modules': ['quick_sale'],
          'is_active': true,
          'must_change_password': false,
          'staff_revision': 0,
        },
      ];
      final createRequests = <String>[];
      final updates = <Map<String, dynamic>>[];
      var sessionCounter = 0;
      var loseFirstResponse = true;
      final client = MockClient((request) async {
        if (request.url.path == '/auth/v1/token') {
          final email = (jsonDecode(request.body) as Map)['email'];
          final id = email == 'a@example.com' ? 'admin-a' : 'admin-b';
          final payload = base64Url
              .encode(
                utf8.encode(
                  jsonEncode({
                    'sub': id,
                    'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
                    'nonce': sessionCounter++,
                  }),
                ),
              )
              .replaceAll('=', '');
          return http.Response(
            jsonEncode({
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
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
        Object response;
        switch (body['action']) {
          case 'list_staff':
            response = {'staff': accounts};
          case 'create_staff':
            createRequests.add(body['request_id'] as String);
            if (!accounts.any((row) => row['username'] == body['username'])) {
              accounts.add({
                'user_id': '00000000-0000-0000-0000-000000000012',
                'billar_id': 'A',
                'username': body['username'],
                'full_name': body['full_name'],
                'job_title': body['job_title'],
                'allowed_modules': body['modules'],
                'is_active': true,
                'must_change_password': true,
                'staff_revision': 0,
              });
            }
            if (loseFirstResponse) {
              loseFirstResponse = false;
              throw http.ClientException('response lost');
            }
            response = {
              'staff': accounts.last,
              'password_available': true,
              'temporary_password': 'temporary-secret',
            };
          case 'update_staff':
            updates.add(body);
            final index = accounts.indexWhere(
              (row) => row['user_id'] == body['user_id'],
            );
            accounts[index] = {
              ...accounts[index],
              'full_name': body['full_name'],
              'job_title': body['job_title'],
              'allowed_modules': body['modules'],
              'is_active': body['is_active'],
              'staff_revision': (accounts[index]['staff_revision'] as int) + 1,
            };
            response = {'staff': accounts[index]};
          default:
            throw StateError('Unexpected action');
        }
        return http.Response(
          jsonEncode(response),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      final supabase =
          (await tester.runAsync(
            () async => SupabaseClient(
              'http://localhost:54321',
              'test-key',
              httpClient: client,
              authOptions: const AuthClientOptions(autoRefreshToken: false),
            ),
          ))!;
      Database? db;
      final authEvents = StreamController<AuthState>.broadcast(sync: true);
      AuthState? lastAuthEvent;
      final authSubscription = supabase.auth.onAuthStateChange.listen((event) {
        lastAuthEvent = event;
        authEvents.add(event);
      }, onError: authEvents.addError);
      Future<void> signIn(String email) async {
        await supabase.auth.signInWithPassword(email: email, password: 'test');
      }

      try {
        db = await tester.runAsync(() => DatabaseHelper.instance.database);
        await tester.runAsync(() => signIn('a@example.com'));
        final repository = TestStaffAccountCreationRepository(
          client: supabase,
          requests: StaffAccountRequestStore(openDatabase: () async => db!),
          currentBillarId: () => 'A',
          changes: authEvents.stream,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: StaffManagementSection(
                  enabled: true,
                  repository: repository,
                ),
              ),
            ),
          ),
        );
        await waitFor(tester, find.text('Existente'));
        await tester.tap(find.byType(PopupMenuButton<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Editar'));
        await tester.pumpAndSettle();
        await tester.runAsync(() => signIn('b@example.com'));
        await tester.pump();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Nombre completo'),
          'No debe guardarse',
        );
        await tester.tap(find.text('CONTINUAR'));
        await waitUntilAbsent(tester, find.text('EDITAR USUARIO'));
        expect(updates, isEmpty);
        await tester.runAsync(() => signIn('a@example.com'));
        await tester.pump();
        await tester.tap(find.text('REINTENTAR'));
        await waitFor(tester, find.text('Existente'));
        await tester.tap(find.text('AGREGAR USUARIO'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Nombre completo'),
          'Ana',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Usuario'),
          'CAJERO',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Puesto o rol'),
          'Caja',
        );
        await tester.ensureVisible(find.text('Venta rápida'));
        await tester.tap(find.text('Venta rápida'));
        await tester.tap(find.text('CONTINUAR'));
        await waitFor(tester, find.text('RECUPERAR'));
        expect(createRequests, hasLength(1));
        await tester.tap(find.text('RECUPERAR'));
        await waitFor(tester, find.textContaining('temporary-secret'));
        authEvents.addError(StateError('auth stream failed'));
        await tester.pump();
        expect(find.textContaining('temporary-secret'), findsNothing);
        authEvents.add(lastAuthEvent!);
        await tester.pump();
        expect(find.textContaining('temporary-secret'), findsNothing);
        await tester.tap(find.text('CERRAR'));
        await waitFor(tester, find.text('RECUPERAR'));
        await tester.tap(find.text('RECUPERAR'));
        await waitFor(tester, find.textContaining('temporary-secret'));
        await tester.runAsync(() => signIn('b@example.com'));
        await tester.pump();
        expect(find.textContaining('temporary-secret'), findsNothing);
        await waitFor(
          tester,
          find.textContaining(
            'Recupera la solicitud desde la cuenta original.',
          ),
        );
        await tester.tap(find.text('CERRAR'));
        await tester.pumpAndSettle();
        await tester.runAsync(() => signIn('a@example.com'));
        await tester.pump();
        await tester.tap(find.text('REINTENTAR'));
        await waitFor(tester, find.text('RECUPERAR'));
        await tester.tap(find.text('RECUPERAR'));
        await waitFor(tester, find.textContaining('temporary-secret'));
        expect(createRequests.toSet(), hasLength(1));
        await tester.tap(find.text('GUARDÉ EL ACCESO'));
        await waitUntilAbsent(tester, find.text('RECUPERAR'));
        await waitFor(tester, find.text('Existente'));

        await tester.tap(find.byType(PopupMenuButton<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Editar'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(
                find.descendant(
                  of: find.widgetWithText(TextFormField, 'Usuario'),
                  matching: find.byType(TextField),
                ),
              )
              .readOnly,
          isTrue,
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Nombre completo'),
          'Nombre actualizado',
        );
        await tester.tap(find.text('CONTINUAR'));
        await waitUntilAbsent(tester, find.text('EDITAR USUARIO'));
        await waitFor(tester, find.text('Nombre actualizado'));
        expect(updates.last['staff_revision'], 0);
        await tester.tap(find.byType(PopupMenuButton<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Desactivar'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('CONFIRMAR'));
        await waitFor(tester, find.textContaining('Desactivado'));
        expect(updates.last['staff_revision'], 1);
        expect(updates.last['is_active'], false);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await authSubscription.cancel();
          await authEvents.close();
        });
        await tester.runAsync(supabase.dispose);
        client.close();
        if (db?.isOpen == true) await tester.runAsync(db!.close);
        messenger.setMockMethodCallHandler(channel, null);
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
