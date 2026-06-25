class PlayerStats {
  final int wins;
  final int losses;
  final int draws;
  final int breakAndRun;
  final int goldenBreaks;
  final int highRun;
  final int currentStreak;
  final int bestStreak;

  const PlayerStats({
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    this.breakAndRun = 0,
    this.goldenBreaks = 0,
    this.highRun = 0,
    this.currentStreak = 0,
    this.bestStreak = 0,
  });

  int get totalMatches => wins + losses + draws;
  double get winRate => totalMatches == 0 ? 0 : (wins / totalMatches) * 100;
  String get formattedWinRate => '${winRate.toStringAsFixed(1)}%';

  Map<String, dynamic> toMap() => {
    'wins': wins,
    'losses': losses,
    'draws': draws,
    'break_and_run': breakAndRun,
    'golden_breaks': goldenBreaks,
    'high_run': highRun,
    'current_streak': currentStreak,
    'best_streak': bestStreak,
  };

  PlayerStats copyWith({
    int? wins,
    int? losses,
    int? draws,
    int? breakAndRun,
    int? goldenBreaks,
    int? highRun,
    int? currentStreak,
    int? bestStreak,
  }) {
    return PlayerStats(
      wins: wins ?? this.wins,
      losses: losses ?? this.losses,
      draws: draws ?? this.draws,
      breakAndRun: breakAndRun ?? this.breakAndRun,
      goldenBreaks: goldenBreaks ?? this.goldenBreaks,
      highRun: highRun ?? this.highRun,
      currentStreak: currentStreak ?? this.currentStreak,
      bestStreak: bestStreak ?? this.bestStreak,
    );
  }
}

class PlayerEntity {
  final int? id;
  final String name;
  final String nickname;
  final String avatar;
  final int totalSeconds;
  final PlayerStats stats;
  final String createdAt;
  final bool synced;
  final String? cloudId;

  const PlayerEntity({
    this.id,
    required this.name,
    this.nickname = '',
    this.avatar = '',
    this.totalSeconds = 0,
    this.stats = const PlayerStats(),
    this.createdAt = '',
    this.synced = false,
    this.cloudId,
  });

  String get displayName => nickname.isNotEmpty ? nickname : name;
  String get initials => name.isNotEmpty ? name[0].toUpperCase() : '?';
  int get level {
    if (stats.totalMatches < 10) return 1;
    if (stats.totalMatches < 50) return 2;
    if (stats.totalMatches < 100) return 3;
    if (stats.totalMatches < 250) return 4;
    return 5;
  }
  String get levelLabel => switch (level) { 1 => 'NOVATO', 2 => 'APRENDIZ', 3 => 'PRO', 4 => 'MAESTRO', _ => 'LEYENDA' };
  String get formattedTime {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'nickname': nickname,
    'avatar': avatar,
    'wins': stats.wins,
    'losses': stats.losses,
    'draws': stats.draws,
    'total_matches': stats.totalMatches,
    'total_seconds': totalSeconds,
    'break_and_run': stats.breakAndRun,
    'golden_breaks': stats.goldenBreaks,
    'high_run': stats.highRun,
    'current_streak': stats.currentStreak,
    'best_streak': stats.bestStreak,
    'synced': synced ? 1 : 0,
    'cloud_id': cloudId,
  };

  factory PlayerEntity.fromMap(Map<String, dynamic> m) => PlayerEntity(
    id: m['id'] as int?,
    name: m['name'] as String? ?? '',
    nickname: m['nickname'] as String? ?? '',
    avatar: m['avatar'] as String? ?? '',
    totalSeconds: m['total_seconds'] as int? ?? 0,
    stats: PlayerStats(
      wins: m['wins'] as int? ?? 0,
      losses: m['losses'] as int? ?? 0,
      draws: m['draws'] as int? ?? 0,
      breakAndRun: m['break_and_run'] as int? ?? 0,
      goldenBreaks: m['golden_breaks'] as int? ?? 0,
      highRun: m['high_run'] as int? ?? 0,
      currentStreak: m['current_streak'] as int? ?? 0,
      bestStreak: m['best_streak'] as int? ?? 0,
    ),
    createdAt: m['created_at'] as String? ?? '',
    synced: m['synced'] == 1,
    cloudId: m['cloud_id'] as String?,
  );

  PlayerEntity copyWith({
    int? id,
    String? name,
    String? nickname,
    String? avatar,
    int? totalSeconds,
    PlayerStats? stats,
    String? createdAt,
    bool? synced,
    String? cloudId,
  }) {
    return PlayerEntity(
      id: id ?? this.id,
      name: name ?? this.name,
      nickname: nickname ?? this.nickname,
      avatar: avatar ?? this.avatar,
      totalSeconds: totalSeconds ?? this.totalSeconds,
      stats: stats ?? this.stats,
      createdAt: createdAt ?? this.createdAt,
      synced: synced ?? this.synced,
      cloudId: cloudId ?? this.cloudId,
    );
  }
}
