import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/routes/app_routes.dart';
import 'package:app_integral_complete/core/services/sync_service.dart';
import 'package:app_integral_complete/core/storage/account_storage.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/core/theme/theme_provider.dart';
import 'package:app_integral_complete/features/auth/presentation/pages/login_page.dart';
import 'package:app_integral_complete/features/config/presentation/pages/config_page.dart';
import 'package:app_integral_complete/features/home/presentation/pages/home_page.dart';
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
  testWidgets('logout does not read retired account preferences', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('logout_scope_'),
    ))!;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const path = MethodChannel('plugins.flutter.io/path_provider');
    const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
    const events = MethodChannel('dev.fluttercommunity.plus/connectivity_status');
    messenger.setMockMethodCallHandler(path, (_) async => directory.path);
    messenger.setMockMethodCallHandler(connectivity, (_) async => ['none']);
    messenger.setMockMethodCallHandler(events, (_) async => null);
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(PreferencesService().init);

    const actor = '00000000-0000-0000-0000-000000000001';
    final logoutStarted = Completer<void>();
    final finishLogout = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.path == '/auth/v1/logout') {
        logoutStarted.complete();
        await finishLogout.future;
        return http.Response('', 204, request: request);
      }
      if (request.url.path != '/auth/v1/token') {
        throw StateError('Unexpected request: ${request.method} ${request.url.path}');
      }
      final payload = base64Url.encode(utf8.encode(jsonEncode({
        'sub': actor, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      }))).replaceAll('=', '');
      return http.Response(
        jsonEncode({
          'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
          'token_type': 'bearer', 'expires_in': 3600, 'refresh_token': 'test',
          'user': {
            'id': actor, 'aud': 'authenticated', 'app_metadata': <String, dynamic>{},
            'user_metadata': <String, dynamic>{}, 'created_at': '2025-01-01T00:00:00Z',
          },
        }),
        200, headers: {'content-type': 'application/json'}, request: request,
      );
    });

    Database? database;
    try {
      await tester.runAsync(() => Supabase.initialize(
        url: 'http://localhost:54321', publishableKey: 'test',
        httpClient: client,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false, detectSessionInUri: false),
      ));
      await tester.runAsync(() => Supabase.instance.client.auth.signInWithPassword(
        email: 'owner@example.test', password: 'password',
      ));
      AccountStorage.initialize(Supabase.instance.client);
      await tester.runAsync(() => AccountStorage.instance.activate(
        billarId: 'A', migrateLegacyOwner: false,
      ));
      database = await tester.runAsync(() => DatabaseHelper.instance.database);
      await tester.runAsync(() => PreferencesService().setUserName('ADMIN'));
      final theme = ThemeProvider();
      Widget app() => ChangeNotifierProvider.value(
        value: theme,
        child: MaterialApp(
          home: const ConfigPage(),
          routes: {AppRoutes.login: (_) => const LoginPage()},
        ),
      );
      await tester.pumpWidget(app());
      await tester.scrollUntilVisible(
        find.text('Sesión'), 300, scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Sesión'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('CERRAR SESIÓN'));
      await tester.tap(find.text('CERRAR SESIÓN'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cerrar sesión').last);
      await tester.pump();
      for (var i = 0; i < 100 && !logoutStarted.isCompleted; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(logoutStarted.isCompleted, isTrue);
      expect(AccountStorage.instance.isActive, isFalse);

      await tester.pumpWidget(app());
      expect(tester.takeException(), isNull);
      expect(find.text('Cerrando sesión...'), findsWidgets);

      await tester.pump(const Duration(seconds: 11));
      expect(find.byType(LoginPage), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      for (var i = 0; i < 100 && find.byType(LoginPage).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.textContaining('No se pudo completar'), findsOneWidget);
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: theme,
        child: const MaterialApp(key: ValueKey('retired-home'), home: HomePage()),
      ));
      expect(tester.takeException(), isNull);
      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byType(Scaffold), findsNothing);
    } finally {
      if (!finishLogout.isCompleted) finishLogout.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      SyncService().dispose();
      if (database != null) {
        await tester.runAsync(database.close);
      }
      await tester.runAsync(AccountStorage.instance.dispose);
      await tester.runAsync(Supabase.instance.dispose);
      client.close();
      messenger.setMockMethodCallHandler(path, null);
      messenger.setMockMethodCallHandler(connectivity, null);
      messenger.setMockMethodCallHandler(events, null);
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });
}
