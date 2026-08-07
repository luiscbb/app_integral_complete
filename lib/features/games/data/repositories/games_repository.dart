import '../../../../core/database/database_helper.dart';
import '../../domain/entities/game_match_entity.dart';

class GamesRepository {
  final _db = DatabaseHelper.instance;

  Future<int> saveMatch(GameMatchEntity match) async {
    final db = await _db.database;
    return db.insert('match_results', match.toMap());
  }

  Future<List<GameMatchEntity>> getMatches({int? playerId, String? gameType, int limit = 100}) async {
    final db = await _db.database;
    final where = <String>[];
    final args = <dynamic>[];

    if (playerId != null) {
      where.add('(player1_id = ? OR player2_id = ?)');
      args.addAll([playerId, playerId]);
    }
    if (gameType != null) {
      where.add('game_type = ?');
      args.add(gameType);
    }

    final rows = await db.query(
      'match_results',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'date DESC',
      limit: limit,
    );
    return rows.map(GameMatchEntity.fromMap).toList();
  }
}
