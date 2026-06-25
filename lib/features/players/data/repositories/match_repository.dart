import '../../../../core/database/database_helper.dart';
import '../../domain/entities/match_result.dart';
import 'player_repository.dart';

class MatchRepository {
  final _db = DatabaseHelper.instance;
  final _playerRepo = PlayerRepository();

  Future<List<Map<String, dynamic>>> getMatchesForPlayer(int playerId) async {
    final db = await _db.database;
    return db.query(
      'match_results',
      where: 'player1_id = ? OR player2_id = ?',
      whereArgs: [playerId, playerId],
      orderBy: 'date DESC',
    );
  }

  Future<void> recordHeadToHead(MatchResult match) async {
    final db = await _db.database;
    await db.insert('match_results', match.toMap());

    // Update stats for both players
    final p1Maps = await db.query('players', where: 'id = ?', whereArgs: [match.player1Id], limit: 1);
    final p2Maps = await db.query('players', where: 'id = ?', whereArgs: [match.player2Id], limit: 1);

    if (p1Maps.isEmpty || p2Maps.isEmpty) return;

    if (match.isDraw) {
      await _playerRepo.recordMatch(match.player1Id, won: false, isDraw: true);
      await _playerRepo.recordMatch(match.player2Id, won: false, isDraw: true);
    } else if (match.winnerId == match.player1Id) {
      await _playerRepo.recordMatch(match.player1Id, won: true, goldenBreak: match.goldenBreak, breakAndRun: match.breakAndRun);
      await _playerRepo.recordMatch(match.player2Id, won: false);
    } else if (match.winnerId == match.player2Id) {
      await _playerRepo.recordMatch(match.player2Id, won: true, goldenBreak: match.goldenBreak, breakAndRun: match.breakAndRun);
      await _playerRepo.recordMatch(match.player1Id, won: false);
    }
  }
}
