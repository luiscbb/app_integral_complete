class GameMatchEntity {
  final int? id;
  final String gameType;
  final int? player1Id;
  final int? player2Id;
  final int? winnerId;
  final int playerScore;
  final int opponentScore;
  final bool isDraw;
  final bool goldenBreak;
  final bool breakAndRun;
  final double accuracy;
  final double efficiency;
  final String notes;
  final DateTime date;

  GameMatchEntity({
    this.id,
    required this.gameType,
    this.player1Id,
    this.player2Id,
    this.winnerId,
    required this.playerScore,
    required this.opponentScore,
    this.isDraw = false,
    this.goldenBreak = false,
    this.breakAndRun = false,
    this.accuracy = 0,
    this.efficiency = 0,
    this.notes = '',
    required this.date,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'game_type': gameType,
        'player1_id': player1Id ?? 0,
        'player2_id': player2Id ?? 0,
        'winner_id': winnerId,
        'player_score': playerScore,
        'opponent_score': opponentScore,
        'is_draw': isDraw ? 1 : 0,
        'golden_break': goldenBreak ? 1 : 0,
        'break_and_run': breakAndRun ? 1 : 0,
        'notes': notes,
        'date': date.toIso8601String(),
      };

  factory GameMatchEntity.fromMap(Map<String, dynamic> map) => GameMatchEntity(
        id: map['id'] as int?,
        gameType: map['game_type'] as String,
        player1Id: map['player1_id'] as int?,
        player2Id: map['player2_id'] as int?,
        winnerId: map['winner_id'] as int?,
        playerScore: map['player_score'] as int,
        opponentScore: map['opponent_score'] as int,
        isDraw: (map['is_draw'] as int) == 1,
        goldenBreak: (map['golden_break'] as int) == 1,
        breakAndRun: (map['break_and_run'] as int) == 1,
        notes: map['notes'] as String? ?? '',
        date: DateTime.tryParse(map['date'] as String) ?? DateTime.now(),
      );
}
