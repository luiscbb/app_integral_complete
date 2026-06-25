import 'package:flutter/foundation.dart';
import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_service.dart';
import '../../domain/entities/player_stats.dart';

class PlayerRepository {
  final _db = DatabaseHelper.instance;

  Future<List<PlayerEntity>> getAll() async {
    try {
      final db = await _db.database;
      debugPrint('[PlayerRepository] Querying players table...');
      final rows = await db.query('players', orderBy: 'wins DESC');
      debugPrint('[PlayerRepository] Found ${rows.length} players');
      final result = rows.map(PlayerEntity.fromMap).toList();
      debugPrint('[PlayerRepository] Parsed ${result.length} player entities');
      return result;
    } catch (e, st) {
      debugPrint('[PlayerRepository] ERROR in getAll: $e\n$st');
      rethrow;
    }
  }

  Future<int> insert(PlayerEntity player) async {
    try {
      debugPrint('[PlayerRepository] Inserting player: ${player.name}');
      final db = await _db.database;
      final map = player.toMap();
      debugPrint('[PlayerRepository] Player toMap: $map');
      final id = await db.insert('players', map);
      debugPrint('[PlayerRepository] Player inserted with ID: $id');

      // Intento inmediato de sync con Supabase en background
      _syncPlayer(id, player);

      return id;
    } catch (e, st) {
      debugPrint('[PlayerRepository] ERROR in insert: $e\n$st');
      rethrow;
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
        debugPrint('[PlayerRepository] Player $localId synced ok cloudId=$cloudId');
      }
    } catch (e) {
      debugPrint('[PlayerRepository] Sync failed for player $localId: $e');
    }
  }

  Future<int> update(PlayerEntity player) async {
    final db = await _db.database;
    return db.update('players', player.toMap(), where: 'id = ?', whereArgs: [player.id]);
  }

  Future<int> delete(int id) async {
    final db = await _db.database;
    return db.delete('players', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> recordMatch(
    int playerId, {
    required bool won,
    bool isDraw = false,
    bool goldenBreak = false,
    bool breakAndRun = false,
  }) async {
    final db = await _db.database;
    final maps = await db.query('players', where: 'id = ?', whereArgs: [playerId], limit: 1);
    if (maps.isEmpty) return;
    final p = PlayerEntity.fromMap(maps.first);
    var stats = p.stats;
    int currentStreak = stats.currentStreak;
    if (won) {
      stats = stats.copyWith(wins: stats.wins + 1, currentStreak: currentStreak + 1);
    } else if (isDraw) {
      stats = stats.copyWith(draws: stats.draws + 1, currentStreak: 0);
    } else {
      stats = stats.copyWith(losses: stats.losses + 1, currentStreak: 0);
    }
    if (goldenBreak) stats = stats.copyWith(goldenBreaks: stats.goldenBreaks + 1);
    if (breakAndRun) stats = stats.copyWith(breakAndRun: stats.breakAndRun + 1);
    final bestStreak =
        stats.currentStreak > stats.bestStreak ? stats.currentStreak : stats.bestStreak;
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
  }
}
