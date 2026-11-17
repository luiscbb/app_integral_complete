import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app_integral_complete/core/services/private_image_service.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/core/utils/scoped_remote_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeImageService extends PrivateImageService {
  _FakeImageService(SupabaseClient client)
    : super(
        client: client,
        preferences: PreferencesService(),
        openDatabase: () => throw UnimplementedError(),
        isCurrentScope: () => true,
      );

  final pending = <String, Completer<Uint8List>>{};
  bool failOnLoad = false;
  int loadCount = 0;

  @override
  ({String bucket, String path})? reference(String url) {
    if (url.startsWith('legacy:')) {
      return (
        bucket: 'product_images',
        path: 'logos/${url.substring('legacy:'.length)}',
      );
    }
    return (bucket: 'product_images', path: 'B1/products/$url');
  }

  @override
  Future<Uint8List> loadRemote(String url) => load(url);

  @override
  Future<Uint8List> load(String url) {
    loadCount++;
    return failOnLoad
        ? Future.error(StateError('sesión cerrada'))
        : (pending[url] ??= Completer<Uint8List>()).future;
  }
}

void main() {
  late SupabaseClient client;
  late MockClient httpClient;
  setUpAll(() async {
    httpClient = MockClient((request) async {
      if (request.url.path == '/auth/v1/logout') {
        return http.Response('', 204, request: request);
      }
      if (request.url.path != '/auth/v1/token') {
        throw StateError('Unexpected request: ${request.url.path}');
      }
      const actor = '00000000-0000-0000-0000-000000000001';
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
      return http.Response(
        jsonEncode({
          'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'test',
          'user': {
            'id': actor,
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
    });
    client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      httpClient: httpClient,
    );
    await client.auth.signInWithPassword(
      email: 'owner@example.test',
      password: 'test',
    );
  });
  tearDownAll(() async {
    await client.dispose();
    httpClient.close();
  });
  testWidgets('does not show the previous image while a new one loads', (
    tester,
  ) async {
    final service = _FakeImageService(client);
    Widget image(String url) => MaterialApp(
      home: ScopedRemoteImage(
        url: url,
        service: service,
        placeholder: const Text('Cargando'),
        error: const Text('Sin imagen'),
      ),
    );
    try {
      await tester.pumpWidget(image('first'));
      service.pending['first']!.complete(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lX8AAAAASUVORK5CYII=',
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);

      await tester.pumpWidget(image('second'));
      expect(find.text('Cargando'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      service.pending['second']!.completeError(StateError('denegado'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Sin imagen'), findsOneWidget);

      await tester.pumpWidget(image('first'));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      service.failOnLoad = true;
      final loadsBeforeSignOut = service.loadCount;
      final signOut = client.auth.signOut();
      await tester.pump();
      await signOut;
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.text('Sin imagen'), findsOneWidget);
      expect(service.loadCount, loadsBeforeSignOut);

      await tester.pumpWidget(image('third'));
      expect(find.text('Sin imagen'), findsOneWidget);
      expect(service.loadCount, loadsBeforeSignOut);
      service.failOnLoad = false;
      final signIn = client.auth.signInWithPassword(
        email: 'owner@example.test',
        password: 'test',
      );
      await tester.pump();
      await signIn;
      await tester.pump();
      expect(service.loadCount, loadsBeforeSignOut + 1);
      service.pending['third']!.complete(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lX8AAAAASUVORK5CYII=',
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('loads legacy public logos through the scoped cache', (
    tester,
  ) async {
    final service = _FakeImageService(client);
    await tester.pumpWidget(
      MaterialApp(
        home: ScopedRemoteImage(
          url: 'legacy:old-logo.jpg',
          service: service,
          placeholder: const Text('Cargando'),
          error: const Text('Sin imagen'),
        ),
      ),
    );
    expect(service.loadCount, 1);
    service.pending['legacy:old-logo.jpg']!.complete(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lX8AAAAASUVORK5CYII=',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
  });
}
