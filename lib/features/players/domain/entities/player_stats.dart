class PlayerStats {
  final int wins;
  final int losses;
  final int draws;
  final int breakAndRun;
  final int goldenBreaks;
  final int opponent8BallFoul;
  final int highRun;
  final int currentStreak;
  final int bestStreak;

  const PlayerStats({
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    this.breakAndRun = 0,
    this.goldenBreaks = 0,
    this.opponent8BallFoul = 0,
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
    'opponent_8_ball_foul': opponent8BallFoul,
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
    int? opponent8BallFoul,
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
      opponent8BallFoul: opponent8BallFoul ?? this.opponent8BallFoul,
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
  final String email;
  final String phone;
  final String playerCode;
  final int handicap;
  final String billarId;
  final bool isActive;
  final String registeredAt;
  final String expiresAt;
  final String? archivedAt;
  final String? authUserId;
  final bool mustChangePassword;
  final String clientId;
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
    this.email = '',
    this.phone = '',
    this.playerCode = '',
    this.handicap = 1,
    this.billarId = 'BILLAR_001',
    this.isActive = true,
    this.registeredAt = '',
    this.expiresAt = '',
    this.archivedAt,
    this.authUserId,
    this.mustChangePassword = false,
    this.clientId = '',
    this.totalSeconds = 0,
    this.stats = const PlayerStats(),
    this.createdAt = '',
    this.synced = false,
    this.cloudId,
  });

  String get displayName => (nickname.isNotEmpty ? nickname : name).toUpperCase();
  String get initials => name.isNotEmpty ? name[0].toUpperCase() : '?';
  int get level => handicap.clamp(1, 6).toInt();
  String get levelLabel => 'HANDICAP $level';

  bool get isExpired {
    final expiry = DateTime.tryParse(expiresAt);
    return expiry != null && !expiry.isAfter(DateTime.now());
  }

  bool get enrollmentIsActive =>
      isActive && archivedAt == null && !isExpired;

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
    'email': email,
    'phone': phone,
    'player_code': playerCode,
    'handicap': handicap,
    'billar_id': billarId,
    'is_active': isActive ? 1 : 0,
    'registered_at': registeredAt,
    'expires_at': expiresAt,
    'archived_at': archivedAt,
    'auth_user_id': authUserId,
    'must_change_password': mustChangePassword ? 1 : 0,
    'client_id': clientId,
    'wins': stats.wins,
    'losses': stats.losses,
    'draws': stats.draws,
    'total_matches': stats.totalMatches,
    'total_seconds': totalSeconds,
    'break_and_run': stats.breakAndRun,
    'golden_breaks': stats.goldenBreaks,
    'opponent_8_ball_foul': stats.opponent8BallFoul,
    'high_run': stats.highRun,
    'current_streak': stats.currentStreak,
    'best_streak': stats.bestStreak,
    'synced': synced ? 1 : 0,
    'cloud_id': cloudId,
    'created_at': createdAt.isEmpty
        ? DateTime.now().toIso8601String()
        : createdAt,
  };

  factory PlayerEntity.fromMap(Map<String, dynamic> m) => PlayerEntity(
    id: m['id'] as int?,
    name: m['name'] as String? ?? '',
    nickname: m['nickname'] as String? ?? '',
    avatar: m['avatar'] as String? ?? '',
    email: m['email'] as String? ?? '',
    phone: m['phone'] as String? ?? '',
    playerCode: m['player_code'] as String? ?? '',
    handicap: (m['handicap'] as num?)?.toInt() ?? 1,
    billarId: m['billar_id'] as String? ?? 'BILLAR_001',
    isActive: _asBool(m['is_active'], fallback: true),
    registeredAt: m['registered_at'] as String? ?? '',
    expiresAt: m['expires_at'] as String? ?? '',
    archivedAt: m['archived_at'] as String?,
    authUserId: m['auth_user_id']?.toString(),
    mustChangePassword: _asBool(m['must_change_password']),
    clientId: m['client_id'] as String? ?? '',
    totalSeconds: (m['total_seconds'] as num?)?.toInt() ?? 0,
    stats: PlayerStats(
      wins: (m['wins'] as num?)?.toInt() ?? 0,
      losses: (m['losses'] as num?)?.toInt() ?? 0,
      draws: (m['draws'] as num?)?.toInt() ?? 0,
      breakAndRun: (m['break_and_run'] as num?)?.toInt() ?? 0,
      goldenBreaks: (m['golden_breaks'] as num?)?.toInt() ?? 0,
      opponent8BallFoul: (m['opponent_8_ball_foul'] as num?)?.toInt() ?? 0,
      highRun: (m['high_run'] as num?)?.toInt() ?? 0,
      currentStreak: (m['current_streak'] as num?)?.toInt() ?? 0,
      bestStreak: (m['best_streak'] as num?)?.toInt() ?? 0,
    ),
    createdAt: m['created_at'] as String? ?? '',
    synced: m['synced'] == 1,
    cloudId: m['cloud_id'] as String?,
  );

  factory PlayerEntity.fromCloudMap(
    Map<String, dynamic> map, {
    required int? localId,
  }) {
    final normalized = <String, dynamic>{
      ...map,
      'id': localId,
      'avatar': map['avatar_url']?.toString().isNotEmpty == true
          ? map['avatar_url']
          : map['avatar'],
      'cloud_id': map['id']?.toString(),
      'is_active': map['is_active'] == true ? 1 : 0,
      'must_change_password': map['must_change_password'] == true ? 1 : 0,
      'synced': 1,
    };
    return PlayerEntity.fromMap(normalized);
  }

  PlayerEntity copyWith({
    int? id,
    String? name,
    String? nickname,
    String? avatar,
    String? email,
    String? phone,
    String? playerCode,
    int? handicap,
    String? billarId,
    bool? isActive,
    String? registeredAt,
    String? expiresAt,
    String? archivedAt,
    String? authUserId,
    bool? mustChangePassword,
    String? clientId,
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
      email: email ?? this.email,
      phone: phone ?? this.phone,
      playerCode: playerCode ?? this.playerCode,
      handicap: handicap ?? this.handicap,
      billarId: billarId ?? this.billarId,
      isActive: isActive ?? this.isActive,
      registeredAt: registeredAt ?? this.registeredAt,
      expiresAt: expiresAt ?? this.expiresAt,
      archivedAt: archivedAt ?? this.archivedAt,
      authUserId: authUserId ?? this.authUserId,
      mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      clientId: clientId ?? this.clientId,
      totalSeconds: totalSeconds ?? this.totalSeconds,
      stats: stats ?? this.stats,
      createdAt: createdAt ?? this.createdAt,
      synced: synced ?? this.synced,
      cloudId: cloudId ?? this.cloudId,
    );
  }

  static bool _asBool(dynamic value, {bool fallback = false}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return fallback;
  }
}
