import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../domain/entities/player_stats.dart';

typedef PlayerRegistrationResult =
    ({PlayerEntity player, String temporaryPassword});

typedef ManagerRegistrationResult =
    ({Map<String, dynamic> manager, String temporaryPassword});

class PlayerRepository {
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  SupabaseClient get _sup => Supabase.instance.client;

  Future<List<PlayerEntity>> getAll() async {
    final db = await _db.database;
    final billarId = _prefs.billarId;

    try {
      try {
        await _invoke('expire_players', {'billar_id': billarId});
      } catch (e, st) {
        debugPrint(
          '[PlayerRepository] Could not update expired enrollments: $e',
        );
        debugPrint('$st');
      }
      final remoteRows = await _sup
          .from('players')
          .select()
          .eq('billar_id', billarId)
          .order('registered_at', ascending: false);

      for (final remote in remoteRows) {
        await _cacheCloudPlayer(Map<String, dynamic>.from(remote));
      }
    } catch (e, st) {
      debugPrint(
        '[PlayerRepository] Cloud refresh failed; showing local cache: $e',
      );
      debugPrint('$st');
    }

    final rows = await db.query(
      'players',
      where: 'billar_id = ?',
      whereArgs: [billarId],
      orderBy: 'created_at DESC',
    );
    return rows.map(PlayerEntity.fromMap).toList();
  }

  Future<PlayerRegistrationResult> createRegisteredPlayer({
    required String name,
    required String email,
    required String phone,
    required String nickname,
    required int handicap,
    String avatarPath = '',
  }) async {
    final avatarUrl = await _uploadAvatar(avatarPath);
    final response = await _invoke('create_player', {
      'billar_id': _prefs.billarId,
      'name': name.trim().toUpperCase(),
      'email': email.trim().toLowerCase(),
      'phone': phone.trim(),
      'nickname': nickname.trim().toUpperCase(),
      'handicap': handicap,
      'avatar_url': avatarUrl,
    });
    final cloudPlayer = _asMap(
      response['player'],
      'No se recibió el jugador creado.',
    );
    final player = await _cacheCloudPlayer(cloudPlayer);
    final temporaryPassword = response['temporary_password'] as String?;
    if (temporaryPassword == null || temporaryPassword.isEmpty) {
      throw StateError('El servidor no devolvió la contraseña provisional.');
    }
    return (player: player, temporaryPassword: temporaryPassword);
  }

  Future<String?> updateRegistration(
    PlayerEntity player, {
    String? newAvatarPath,
  }) async {
    final cloudId = player.cloudId;
    final avatarUrl =
        newAvatarPath == null
            ? player.avatar
            : await _uploadAvatar(newAvatarPath);
    final response = await _invoke(
      cloudId == null || cloudId.isEmpty ? 'create_player' : 'update_player',
      {
        'billar_id': _prefs.billarId,
        if (cloudId != null && cloudId.isNotEmpty) 'player_id': cloudId,
        'local_id': player.id,
        'name': player.name.trim().toUpperCase(),
        'email': player.email.trim().toLowerCase(),
        'phone': player.phone.trim(),
        'nickname': player.nickname.trim().toUpperCase(),
        'handicap': player.handicap,
        'avatar_url': avatarUrl,
      },
    );
    final cloudPlayer = _asMap(
      response['player'],
      'No se recibió el jugador actualizado.',
    );
    if (cloudId == null || cloudId.isEmpty) {
      final localId = player.id;
      if (localId == null) {
        throw StateError('No se pudo asociar el jugador local con su cuenta.');
      }
      final linked = PlayerEntity.fromCloudMap(
        cloudPlayer,
        localId: localId,
      ).copyWith(
        id: localId,
        clientId: player.clientId,
        stats: player.stats,
        totalSeconds: player.totalSeconds,
        createdAt: player.createdAt,
        synced: false,
      );
      final db = await _db.database;
      await db.update(
        'players',
        linked.toMap()..['synced'] = 0,
        where: 'id = ?',
        whereArgs: [localId],
      );
      _syncPlayer(localId, linked);
    } else {
      await _cacheCloudPlayer(cloudPlayer);
    }
    return response['temporary_password'] as String?;
  }

  Future<void> archivePlayer(PlayerEntity player) async {
    final cloudId = player.cloudId;
    if (cloudId == null || cloudId.isEmpty) {
      final db = await _db.database;
      await db.update(
        'players',
        {'is_active': 0, 'archived_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [player.id],
      );
      return;
    }
    final response = await _invoke('archive_player', {
      'billar_id': _prefs.billarId,
      'player_id': cloudId,
    });
    await _cacheCloudPlayer(
      _asMap(response['player'], 'No se recibió el jugador archivado.'),
    );
  }

  Future<PlayerEntity> renewPlayer(PlayerEntity player) async {
    final cloudId = player.cloudId;
    if (cloudId == null || cloudId.isEmpty) {
      throw StateError('Este registro local aún no tiene cuenta en la nube.');
    }
    final response = await _invoke('renew_player', {
      'billar_id': _prefs.billarId,
      'player_id': cloudId,
    });
    return _cacheCloudPlayer(
      _asMap(response['player'], 'No se recibió el jugador renovado.'),
    );
  }

  Future<String> resetPlayerPassword(PlayerEntity player) async {
    final response = await _invoke('reset_player_password', {
      'billar_id': _prefs.billarId,
      'player_id': player.cloudId,
    });
    final password = response['temporary_password'] as String?;
    if (password == null || password.isEmpty) {
      throw StateError('El servidor no devolvió la contraseña provisional.');
    }
    return password;
  }

  Future<bool> isCurrentUserAdmin() async {
    final userId = _sup.auth.currentUser?.id;
    if (userId == null) return false;
    try {
      final row =
          await _sup
              .from('business_memberships')
              .select('role')
              .eq('user_id', userId)
              .eq('billar_id', _prefs.billarId)
              .eq('is_active', true)
              .maybeSingle();
      return row?['role'] == 'admin';
    } catch (e, st) {
      debugPrint('[PlayerRepository] Could not resolve business role: $e');
      debugPrint('$st');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getManagers() async {
    final rows = await _sup
        .from('business_memberships')
        .select(
          'user_id, billar_id, email, role, is_active, must_change_password',
        )
        .eq('billar_id', _prefs.billarId)
        .eq('role', 'manager')
        .order('created_at');
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<ManagerRegistrationResult> createManager({
    required String name,
    required String email,
  }) async {
    final response = await _invoke('create_manager', {
      'billar_id': _prefs.billarId,
      'name': name.trim().toUpperCase(),
      'email': email.trim().toLowerCase(),
    });
    final manager = _asMap(
      response['manager'],
      'No se recibió el encargado creado.',
    );
    final password = response['temporary_password'] as String?;
    if (password == null || password.isEmpty) {
      throw StateError('El servidor no devolvió la contraseña provisional.');
    }
    return (manager: manager, temporaryPassword: password);
  }

  Future<String> resetManagerPassword(String userId) async {
    final response = await _invoke('reset_manager_password', {
      'billar_id': _prefs.billarId,
      'user_id': userId,
    });
    final password = response['temporary_password'] as String?;
    if (password == null || password.isEmpty) {
      throw StateError('El servidor no devolvió la contraseña provisional.');
    }
    return password;
  }

  Future<void> setManagerActive(String userId, bool isActive) async {
    await _invoke('set_manager_active', {
      'billar_id': _prefs.billarId,
      'user_id': userId,
      'is_active': isActive,
    });
  }

  Future<int> insert(PlayerEntity player) async {
    final db = await _db.database;
    final now = DateTime.now();
    final localPlayer = player.copyWith(
      clientId: player.clientId.isEmpty ? _newClientId() : player.clientId,
      billarId: _prefs.billarId,
      registeredAt:
          player.registeredAt.isEmpty
              ? now.toIso8601String()
              : player.registeredAt,
      expiresAt:
          player.expiresAt.isEmpty
              ? DateTime(now.year + 1, now.month, now.day).toIso8601String()
              : player.expiresAt,
    );
    final id = await db.insert('players', localPlayer.toMap());
    _syncPlayer(id, localPlayer.copyWith(id: id));
    return id;
  }

  Future<int> update(PlayerEntity player) async {
    final db = await _db.database;
    final map = player.toMap()..['synced'] = 0;
    final changed = await db.update(
      'players',
      map,
      where: 'id = ?',
      whereArgs: [player.id],
    );
    if (changed > 0) {
      _syncPlayer(player.id!, player.copyWith(synced: false));
    }
    return changed;
  }

  Future<int> delete(int id) async {
    final db = await _db.database;
    return db.update(
      'players',
      {'is_active': 0, 'archived_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> recordMatch(
    int playerId, {
    required bool won,
    bool isDraw = false,
    bool goldenBreak = false,
    bool breakAndRun = false,
    bool opponent8BallFoul = false,
  }) async {
    final db = await _db.database;
    final maps = await db.query(
      'players',
      where: 'id = ?',
      whereArgs: [playerId],
      limit: 1,
    );
    if (maps.isEmpty) return;
    final player = PlayerEntity.fromMap(maps.first);
    var stats = player.stats;
    if (won) {
      stats = stats.copyWith(
        wins: stats.wins + 1,
        currentStreak: stats.currentStreak + 1,
      );
    } else if (isDraw) {
      stats = stats.copyWith(draws: stats.draws + 1, currentStreak: 0);
    } else {
      stats = stats.copyWith(losses: stats.losses + 1, currentStreak: 0);
    }
    if (goldenBreak) {
      stats = stats.copyWith(goldenBreaks: stats.goldenBreaks + 1);
    }
    if (breakAndRun) {
      stats = stats.copyWith(breakAndRun: stats.breakAndRun + 1);
    }
    if (opponent8BallFoul) {
      stats = stats.copyWith(opponent8BallFoul: stats.opponent8BallFoul + 1);
    }
    final bestStreak =
        stats.currentStreak > stats.bestStreak
            ? stats.currentStreak
            : stats.bestStreak;
    stats = stats.copyWith(bestStreak: bestStreak);
    await db.update(
      'players',
      {
        'wins': stats.wins,
        'losses': stats.losses,
        'draws': stats.draws,
        'total_matches': stats.totalMatches,
        'break_and_run': stats.breakAndRun,
        'golden_breaks': stats.goldenBreaks,
        'high_run': stats.highRun,
        'current_streak': stats.currentStreak,
        'best_streak': stats.bestStreak,
      },
      where: 'id = ?',
      whereArgs: [playerId],
    );
    final updatedRows = await db.query(
      'players',
      where: 'id = ?',
      whereArgs: [playerId],
      limit: 1,
    );
    if (updatedRows.isNotEmpty) {
      await _syncPlayer(playerId, PlayerEntity.fromMap(updatedRows.first));
    }
  }

  Future<void> _syncPlayer(int localId, PlayerEntity player) async {
    try {
      final cloudId = await SyncService().pushPlayerToCloud(player);
      if (cloudId != null) {
        final db = await _db.database;
        await db.update(
          'players',
          {'synced': 1, 'cloud_id': cloudId},
          where: 'id = ?',
          whereArgs: [localId],
        );
      }
    } catch (e, st) {
      debugPrint('[PlayerRepository] Sync failed for player $localId: $e');
      debugPrint('$st');
    }
  }

  Future<PlayerEntity> _cacheCloudPlayer(Map<String, dynamic> row) async {
    final db = await _db.database;
    final cloudId = row['id']?.toString();
    final existing =
        cloudId == null
            ? <Map<String, Object?>>[]
            : await db.query(
              'players',
              where: 'cloud_id = ?',
              whereArgs: [cloudId],
              limit: 1,
            );
    final localId =
        existing.isEmpty ? null : (existing.first['id'] as num).toInt();
    var player = PlayerEntity.fromCloudMap(row, localId: localId);
    if (player.clientId.isEmpty) {
      final savedClientId =
          existing.isEmpty ? null : existing.first['client_id']?.toString();
      player = player.copyWith(
        clientId:
            savedClientId?.isNotEmpty == true ? savedClientId : _newClientId(),
      );
    }
    final values = player.toMap()..['synced'] = 1;
    if (localId == null) {
      final insertedId = await db.insert('players', values);
      player = player.copyWith(id: insertedId);
    } else {
      await db.update('players', values, where: 'id = ?', whereArgs: [localId]);
    }
    return player;
  }

  Future<String> _uploadAvatar(String pathOrUrl) async {
    if (pathOrUrl.isEmpty || pathOrUrl.startsWith('http')) return pathOrUrl;
    final file = File(pathOrUrl);
    if (!await file.exists()) {
      throw FileSystemException(
        'No se encontró el archivo de la foto.',
        pathOrUrl,
      );
    }
    final extension = pathOrUrl.split('.').last.toLowerCase();
    final contentType = switch (extension) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
    final storagePath =
        '${_prefs.billarId}/${DateTime.now().microsecondsSinceEpoch}_${_newClientId()}.$extension';
    await _sup.storage
        .from('player_avatars')
        .upload(
          storagePath,
          file,
          fileOptions: FileOptions(contentType: contentType),
        );
    return _sup.storage.from('player_avatars').getPublicUrl(storagePath);
  }

  Future<Map<String, dynamic>> _invoke(
    String action,
    Map<String, dynamic> parameters,
  ) async {
    final response = await _sup.functions.invoke(
      'player-admin',
      body: {'action': action, ...parameters},
    );
    final data = response.data;
    if (response.status < 200 || response.status >= 300) {
      final message = data is Map ? data['error']?.toString() : null;
      throw StateError(
        message ?? 'No se pudo completar la operación ($action).',
      );
    }
    if (data is! Map) {
      throw StateError('Respuesta inválida del servidor ($action).');
    }
    return Map<String, dynamic>.from(data);
  }

  static Map<String, dynamic> _asMap(dynamic value, String error) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw StateError(error);
  }

  static String _newClientId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
