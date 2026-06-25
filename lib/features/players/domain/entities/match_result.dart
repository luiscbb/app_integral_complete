class MatchResult {
  final int? id;
  final String gameType;
  final int player1Id;
  final int player2Id;
  final int? winnerId;
  final bool isDraw;
  final bool goldenBreak;
  final bool breakAndRun;
  final String notes;
  final String date;
  final bool synced;

  MatchResult({
    this.id,
    this.gameType = 'Bola 8',
    required this.player1Id,
    required this.player2Id,
    this.winnerId,
    this.isDraw = false,
    this.goldenBreak = false,
    this.breakAndRun = false,
    this.notes = '',
    this.date = '',
    this.synced = false,
  });

  Map<String, dynamic> toMap() => {
    'game_type': gameType,
    'player1_id': player1Id,
    'player2_id': player2Id,
    'winner_id': winnerId,
    'is_draw': isDraw ? 1 : 0,
    'golden_break': goldenBreak ? 1 : 0,
    'break_and_run': breakAndRun ? 1 : 0,
    'notes': notes,
    'date': date.isEmpty ? DateTime.now().toIso8601String() : date,
    'synced': synced ? 1 : 0,
  };
}
