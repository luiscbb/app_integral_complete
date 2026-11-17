import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/database_helper.dart';
import '../storage/account_storage.dart';
import '../storage/preferences_service.dart';
import 'business_image_paths.dart';
import 'sync_session.dart';

class ImageCacheMissException implements Exception {
  @override
  String toString() => 'No hay copia local de la imagen sin conexión.';
}

class PrivateImageService {
  PrivateImageService({
    required this.client,
    required this.preferences,
    required this.openDatabase,
    required this.isCurrentScope,
    this.cacheDirectory = getApplicationSupportDirectory,
    this.imageClient,
  });

  factory PrivateImageService.current() => PrivateImageService(
    client: Supabase.instance.client,
    preferences: PreferencesService(),
    openDatabase: () => DatabaseHelper.instance.database,
    isCurrentScope: () => AccountStorage.instance.isActive,
  );

  final SupabaseClient client;
  final PreferencesService preferences;
  final Future<Database> Function() openDatabase;
  final bool Function() isCurrentScope;
  final Future<Directory> Function() cacheDirectory;
  final http.Client? imageClient;

  static const buckets = ['product_images', 'promo_images', 'player_avatars'];
  static const _maxCacheBytes = 5 * 1024 * 1024;
  static const _maxDatabaseCacheBytes = 512 * 1024;
  static const _maxCacheEntries = 100;

  ({String bucket, String path})? reference(String url) {
    for (final bucket in buckets) {
      final path = publicStorageObjectPath(client, bucket, url);
      if (path != null) return (bucket: bucket, path: path);
    }
    return null;
  }

  bool isLegacyPublicReference(({String bucket, String path}) ref) =>
      ref.bucket == 'product_images' &&
      ref.path.split('/').length == 2 &&
      (ref.path.startsWith('products/') || ref.path.startsWith('logos/'));

  Future<Uint8List> loadRemote(String url) async {
    final ref = reference(url);
    if (ref != null) {
      if (!isLegacyPublicReference(ref)) return load(url);
      return _loadLegacyPublic(url, ref);
    }
    final uri = Uri.parse(url);
    if ((uri.scheme != 'http' && uri.scheme != 'https') || !uri.hasAuthority) {
      throw ArgumentError('La URL de la imagen no es válida.');
    }
    final httpClient =
        HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await httpClient
          .getUrl(uri)
          .timeout(const Duration(seconds: 8));
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode != 200) {
        throw HttpException(
          'No se pudo cargar la imagen (HTTP ${response.statusCode}).',
          uri: uri,
        );
      }
      final bytes = await response
          .fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk))
          .timeout(const Duration(seconds: 8));
      if (bytes.isEmpty) throw StateError('La imagen descargada está vacía.');
      return Uint8List.fromList(bytes);
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<Uint8List> load(String url) async {
    final ref = reference(url);
    if (ref == null) {
      throw ArgumentError('La imagen no pertenece al Storage configurado.');
    }
    final guard = SyncSessionGuard(client, preferences);
    final session = guard.capture();
    void requireScope() {
      guard.require(session);
      if (!isCurrentScope()) {
        throw StateError('El ámbito local de la imagen ya no está activo.');
      }
    }

    requireScope();
    if (!ref.path.startsWith('${session.billarId}/')) {
      throw StateError('La imagen no pertenece al billar actual.');
    }
    final cacheKey = '${ref.bucket}/${ref.path}';
    try {
      final bytes = await _download(ref, session);
      requireScope();
      if (bytes.isEmpty) throw StateError('La imagen descargada está vacía.');
      await _cache(session, cacheKey, bytes, requireScope);
      requireScope();
      return bytes;
    } on SocketException {
      return _loadCached(session, cacheKey, requireScope);
    } on http.ClientException {
      return _loadCached(session, cacheKey, requireScope);
    } on TimeoutException {
      return _loadCached(session, cacheKey, requireScope);
    }
  }

  Future<Uint8List> _loadLegacyPublic(
    String url,
    ({String bucket, String path}) ref,
  ) async {
    final guard = SyncSessionGuard(client, preferences);
    final session = guard.capture();
    void requireScope() {
      guard.require(session);
      if (!isCurrentScope()) {
        throw StateError('El ámbito local de la imagen ya no está activo.');
      }
    }

    requireScope();
    final cacheKey = '${ref.bucket}/${ref.path}';
    final uri = Uri.parse(url);
    final request = http.Request('GET', uri)..followRedirects = false;
    final requestClient = imageClient ?? http.Client();
    try {
      final response = await requestClient
          .send(request)
          .timeout(const Duration(seconds: 8));
      final bytes = await response.stream.toBytes().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode != 200) {
        throw HttpException(
          'No se pudo cargar la imagen (HTTP ${response.statusCode}).',
          uri: uri,
        );
      }
      requireScope();
      if (bytes.isEmpty) throw StateError('La imagen descargada está vacía.');
      await _cache(session, cacheKey, bytes, requireScope);
      requireScope();
      return bytes;
    } on SocketException {
      return _loadCached(session, cacheKey, requireScope);
    } on http.ClientException {
      return _loadCached(session, cacheKey, requireScope);
    } on TimeoutException {
      return _loadCached(session, cacheKey, requireScope);
    } finally {
      if (imageClient == null) requestClient.close();
    }
  }

  Future<void> _cache(
    SyncSession session,
    String cacheKey,
    Uint8List bytes,
    void Function() requireScope,
  ) async {
    if (bytes.length > _maxCacheBytes) return;
    if (bytes.length > _maxDatabaseCacheBytes) {
      try {
        final directory = await _cacheScopeDirectory(session);
        final file = await _cacheFile(session, cacheKey);
        requireScope();
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        requireScope();
        await _trimFileCache(directory);
      } catch (error, stack) {
        requireScope();
        debugPrint(
          '[PrivateImageService] No se pudo guardar la imagen sin conexión: $error\n$stack',
        );
      }
      return;
    }
    try {
      final db = await openDatabase();
      requireScope();
      await db.transaction((txn) async {
        requireScope();
        await _ensureTable(txn);
        await txn.insert('private_image_cache', {
          'actor_id': session.actorId,
          'billar_id': session.billarId,
          'object_key': cacheKey,
          'bytes': bytes,
          'saved_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.rawDelete(
          '''
          DELETE FROM private_image_cache
          WHERE rowid IN (
            SELECT rowid FROM private_image_cache
            WHERE actor_id = ? AND billar_id = ?
            ORDER BY saved_at DESC, rowid DESC
            LIMIT -1 OFFSET ?
          )
        ''',
          [session.actorId, session.billarId, _maxCacheEntries],
        );
        requireScope();
      });
    } catch (error, stack) {
      requireScope();
      debugPrint(
        '[PrivateImageService] No se pudo guardar la imagen sin conexión: $error\n$stack',
      );
    }
  }

  Future<Uint8List> _download(
    ({String bucket, String path}) ref,
    SyncSession session,
  ) async {
    final apiKey = client.auth.headers['apikey'];
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError('No se encontró la clave pública de Supabase.');
    }
    final storage = client.storage.from(ref.bucket);
    final encodedPath = Uri(pathSegments: ref.path.split('/')).path;
    final uri = Uri.parse('${storage.url}/object/${ref.bucket}/$encodedPath');
    final request =
        http.Request('GET', uri)
          ..followRedirects = false
          ..headers['apikey'] = apiKey
          ..headers['Authorization'] = 'Bearer ${session.token}';
    final requestClient = imageClient ?? http.Client();
    try {
      final response = await requestClient
          .send(request)
          .timeout(const Duration(seconds: 8));
      final bytes = await response.stream.toBytes().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode != 200) {
        throw StorageException(
          'No se pudo cargar la imagen (HTTP ${response.statusCode}).',
          statusCode: '${response.statusCode}',
        );
      }
      if (kDebugMode) {
        debugPrint(
          '[PrivateImageService] HTTP 200 autenticado en ${ref.bucket}: ${bytes.length} bytes.',
        );
      }
      return bytes;
    } finally {
      if (imageClient == null) requestClient.close();
    }
  }

  Future<Uint8List> _loadCached(
    SyncSession session,
    String cacheKey,
    void Function() requireScope,
  ) async {
    requireScope();
    final file = await _cacheFile(session, cacheKey);
    requireScope();
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      requireScope();
      if (bytes.isNotEmpty) return Uint8List.fromList(bytes);
    }
    final db = await openDatabase();
    requireScope();
    final rows = await db.transaction((txn) async {
      requireScope();
      await _ensureTable(txn);
      final result = await txn.query(
        'private_image_cache',
        columns: ['bytes'],
        where: 'actor_id = ? AND billar_id = ? AND object_key = ?',
        whereArgs: [session.actorId, session.billarId, cacheKey],
        limit: 1,
      );
      requireScope();
      return result;
    });
    requireScope();
    if (rows.isEmpty) {
      throw ImageCacheMissException();
    }
    return rows.single['bytes'] as Uint8List;
  }

  Future<Directory> _cacheScopeDirectory(SyncSession session) async {
    String encode(String value) =>
        base64Url.encode(utf8.encode(value)).replaceAll('=', '');
    final root = await cacheDirectory();
    return Directory(
      p.join(
        root.path,
        'private_image_cache',
        encode(session.actorId),
        encode(session.billarId),
      ),
    );
  }

  Future<File> _cacheFile(SyncSession session, String cacheKey) async {
    final scopeDirectory = await _cacheScopeDirectory(session);
    String encode(String value) =>
        base64Url.encode(utf8.encode(value)).replaceAll('=', '');
    return File(
      p.joinAll([scopeDirectory.path, ...cacheKey.split('/').map(encode)]),
    );
  }

  Future<void> _trimFileCache(Directory directory) async {
    final files =
        await directory
            .list(recursive: true)
            .where((entity) => entity is File)
            .cast<File>()
            .toList();
    if (files.length <= _maxCacheEntries) return;
    final entries = await Future.wait(
      files.map(
        (file) async => (file: file, modified: await file.lastModified()),
      ),
    );
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in entries.take(files.length - _maxCacheEntries)) {
      await entry.file.delete();
    }
  }

  Future<void> _ensureTable(Transaction txn) => txn.execute('''
    CREATE TABLE IF NOT EXISTS private_image_cache (
      actor_id TEXT NOT NULL,
      billar_id TEXT NOT NULL,
      object_key TEXT NOT NULL,
      bytes BLOB NOT NULL,
      saved_at INTEGER NOT NULL,
      PRIMARY KEY (actor_id, billar_id, object_key)
    )
  ''');
}
