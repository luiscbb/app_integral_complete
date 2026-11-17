import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_integral_complete/core/services/business_logo_loader.dart';
import 'package:app_integral_complete/core/services/private_image_service.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'isolates cached images and never falls back on a denied request',
    () async {
      SharedPreferences.setMockInitialValues({'billar_id': 'B1'});
      final preferences = PreferencesService();
      await preferences.init();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final directory = await Directory.systemTemp.createTemp(
        'private_logo_test_',
      );
      var status = 200;
      var offline = false;
      var active = true;
      var responseBytes = <int>[1, 2, 3];
      Completer<void>? started;
      Completer<void>? resume;
      final requests = <http.Request>[];
      final httpClient = MockClient((request) async {
        if (request.url.path == '/auth/v1/token') {
          final email = (jsonDecode(request.body) as Map)['email'] as String;
          final id = email == 'a@example.com' ? 'actor-a' : 'actor-b';
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
          return http.Response(
            jsonEncode({
              'access_token': 'eyJhbGciOiJub25lIn0.$payload.signature',
              'token_type': 'bearer',
              'expires_in': 3600,
              'refresh_token': 'refresh',
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
          );
        }
        requests.add(request);
        if (started != null) {
          started!.complete();
          await resume!.future;
          started = null;
        }
        if (offline) throw http.ClientException('sin conexión');
        return http.Response.bytes(
          status == 200 ? responseBytes : utf8.encode('denegado'),
          status,
        );
      });
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        httpClient: httpClient,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      Future<void> signIn(String email) => client.auth
          .signInWithPassword(email: email, password: 'password')
          .then((_) {});
      final service = PrivateImageService(
        client: client,
        preferences: preferences,
        openDatabase: () async => db,
        isCurrentScope: () => active,
        cacheDirectory: () async => directory,
        imageClient: httpClient,
      );
      final url = client.storage
          .from('product_images')
          .getPublicUrl('B1/products/a.jpg');
      expect(
        service.isLegacyPublicReference((
          bucket: 'product_images',
          path: 'products/products/a.jpg',
        )),
        isFalse,
      );
      try {
        await signIn('a@example.com');
        final token = client.auth.currentSession!.accessToken;
        expect(await service.load(url), Uint8List.fromList([1, 2, 3]));
        expect(
          requests.last.url.path,
          '/storage/v1/object/product_images/B1/products/a.jpg',
        );
        expect(requests.last.headers['authorization'], 'Bearer $token');
        final legacyLogoUrl = client.storage
            .from('product_images')
            .getPublicUrl('logos/legacy.jpg');
        expect(
          service.isLegacyPublicReference(service.reference(legacyLogoUrl)!),
          isTrue,
        );
        expect(
          await service.loadRemote(legacyLogoUrl),
          Uint8List.fromList([1, 2, 3]),
        );
        expect(
          requests.last.url.path,
          '/storage/v1/object/public/product_images/logos/legacy.jpg',
        );
        expect(requests.last.headers['authorization'], isNull);
        final largeImageUrl = client.storage
            .from('product_images')
            .getPublicUrl('B1/products/large.jpg');
        responseBytes = List<int>.filled(600 * 1024, 17);
        expect(
          await service.load(largeImageUrl),
          Uint8List.fromList(responseBytes),
        );

        offline = true;
        expect(await service.load(url), Uint8List.fromList([1, 2, 3]));
        final requestsBeforeOfflineLogo = requests.length;
        expect(
          await service.loadRemote(legacyLogoUrl),
          Uint8List.fromList([1, 2, 3]),
        );
        expect(requests, hasLength(requestsBeforeOfflineLogo + 1));
        expect(
          await service.load(largeImageUrl),
          Uint8List.fromList(responseBytes),
        );
        await signIn('b@example.com');
        await expectLater(
          service.load(url),
          throwsA(isA<ImageCacheMissException>()),
        );
        await expectLater(
          service.loadRemote(legacyLogoUrl),
          throwsA(isA<ImageCacheMissException>()),
        );
        await expectLater(
          service.load(largeImageUrl),
          throwsA(isA<ImageCacheMissException>()),
        );
        await signIn('a@example.com');
        active = false;
        await expectLater(service.load(url), throwsStateError);
        active = true;
        offline = false;
        status = 403;
        await expectLater(service.load(url), throwsA(isA<StorageException>()));
        final logo = File('${directory.path}${Platform.pathSeparator}logo.jpg');
        await logo.writeAsBytes([9, 8, 7]);
        await preferences.setLogoPath(logo.path);
        await preferences.setLogoUrl(url);
        expect(
          await loadBusinessLogo(
            preferences,
            remoteFirst: true,
            imageService: service,
          ),
          isNull,
        );
        offline = true;
        await preferences.setLogoUrl(
          client.storage
              .from('product_images')
              .getPublicUrl('B1/logos/missing.jpg'),
        );
        expect(
          await loadBusinessLogo(
            preferences,
            remoteFirst: true,
            imageService: service,
          ),
          Uint8List.fromList([9, 8, 7]),
        );
        offline = false;
        status = 302;
        await expectLater(service.load(url), throwsA(isA<StorageException>()));
        expect(requests.last.followRedirects, isFalse);
        final count = requests.length;
        await expectLater(
          service.load(
            client.storage
                .from('product_images')
                .getPublicUrl('B2/products/a.jpg'),
          ),
          throwsStateError,
        );
        await expectLater(
          service.load('https://elsewhere.test/a.jpg'),
          throwsArgumentError,
        );
        expect(requests.length, count);

        status = 200;
        started = Completer<void>();
        resume = Completer<void>();
        final inFlight = service.load(
          client.storage
              .from('product_images')
              .getPublicUrl('B1/products/new.jpg'),
        );
        await started!.future;
        await signIn('b@example.com');
        resume.complete();
        await expectLater(inFlight, throwsStateError);
        final rows = await db.query('private_image_cache');
        expect(rows, hasLength(2));
      } finally {
        await client.dispose();
        httpClient.close();
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
