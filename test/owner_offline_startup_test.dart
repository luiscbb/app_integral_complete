import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/routes/app_routes.dart';
import 'package:app_integral_complete/core/services/sync_service.dart';
import 'package:app_integral_complete/core/storage/account_storage.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/core/theme/theme_provider.dart';
import 'package:app_integral_complete/features/home/presentation/pages/splash_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('verified owner can reopen the existing local database offline', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('owner_offline_start_'),
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
    final requestStarted = Completer<void>();
    final finishRequest = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.path == '/rest/v1/players') {
        requestStarted.complete();
        await finishRequest.future;
        return http.Response(
          jsonEncode({'code': '42501', 'message': 'Consulta no disponible'}),
          403, headers: {'content-type': 'application/json'}, request: request,
        );
      }
      if (request.url.path.startsWith('/rest/v1/')) {
        return http.Response(
          jsonEncode({'code': '42501', 'message': 'Consulta no disponible'}),
          403, headers: {'content-type': 'application/json'}, request: request,
        );
      }
      if (request.url.path != '/auth/v1/token') {
        throw StateError('Unexpected request: ${request.url.path}');
      }
      final payload = base64Url.encode(utf8.encode(jsonEncode({
        'sub': actor, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      }))).replaceAll('=', '');
      return http.Response(jsonEncode({
        'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
        'token_type': 'bearer', 'expires_in': 3600, 'refresh_token': 'test',
        'user': {
          'id': actor, 'aud': 'authenticated', 'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{}, 'created_at': '2025-01-01T00:00:00Z',
        },
      }), 200, headers: {'content-type': 'application/json'}, request: request);
    });
    try {
      await tester.runAsync(() => Supabase.initialize(
        url: 'http://localhost:54321', publishableKey: 'test', httpClient: client,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false, detectSessionInUri: false),
      ));
      await tester.runAsync(() => Supabase.instance.client.auth.signInWithPassword(
        email: 'a@example.com', password: 'test',
      ));
      await tester.runAsync(() async {
        final prefs = PreferencesService();
        await prefs.recordVerifiedOwner(actor, 'A');
        final scoped = await DatabaseHelper.instance.openScopedDatabase(
          actorId: actor, billarId: 'A', isCurrentScope: () => true,
        );
        await scoped.insert('categories', {'billar_id': 'A', 'name': 'LOCAL'});
        await scoped.close();
      });
      AccountStorage.initialize(Supabase.instance.client);
      await tester.pumpWidget(ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: const SplashPage(),
          routes: {AppRoutes.home: (_) => const Scaffold(body: Text('HOME OFFLINE'))},
        ),
      ));
      await tester.pump();
      await tester.runAsync(() => requestStarted.future.timeout(const Duration(seconds: 5)));
      await tester.pump(const Duration(seconds: 9));
      for (var i = 0; i < 250 && find.text('HOME OFFLINE').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('HOME OFFLINE'), findsOneWidget);
      final categories = await tester.runAsync(() async =>
        (await DatabaseHelper.instance.database).query('categories'));
      expect(categories!.single['name'], 'LOCAL');
      expect(Supabase.instance.client.auth.currentUser?.id, actor);
    } finally {
      finishRequest.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      SyncService().dispose();
      if (AccountStorage.instance.isActive) {
        await tester.runAsync(() async => (await DatabaseHelper.instance.database).close());
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
