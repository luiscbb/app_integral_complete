import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../data/repositories/player_repository.dart';
import '../../domain/entities/player_stats.dart';
import '../../../tournaments/data/tournament_repository.dart';
import '../../../tournaments/domain/tournament.dart';

class PlayersProvider extends ChangeNotifier {
  final _repo = PlayerRepository();
  final _tournamentRepository = TournamentRepository();
  List<PlayerEntity> _players = [];
  final Map<String, (int, int)> _tournamentRecords = {};
  bool _loading = true;
  bool _isAdmin = false;

  List<PlayerEntity> get players => List.unmodifiable(_players);
  bool get isLoading => _loading;
  bool get isAdmin => _isAdmin;

  PlayersProvider() {
    _load();
  }

  Future<void> refresh() => _load();

  Future<void> _load() async {
    _loading = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        _repo.getAll(),
        _repo.isCurrentUserAdmin(),
      ]);
      _players = results[0] as List<PlayerEntity>;
      _isAdmin = results[1] as bool;
      try {
        final tournaments = await _tournamentRepository.listAllForStatistics();
        _tournamentRecords
          ..clear()
          ..addAll(_calculateTournamentRecords(_players, tournaments));
      } catch (e, st) {
        debugPrint(
          '[PlayersProvider] Could not load tournament win rates: $e\n$st',
        );
        _tournamentRecords.clear();
      }
      debugPrint('[PlayersProvider] Loaded ${_players.length} players');
    } catch (e, st) {
      debugPrint('[PlayersProvider] Error loading players: $e\n$st');
    }
    _loading = false;
    notifyListeners();
  }

  double winRateFor(PlayerEntity player) {
    final record = _tournamentRecords[_playerKey(player)] ?? (0, 0);
    final totalMatches = player.stats.totalMatches + record.$1 + record.$2;
    if (totalMatches == 0) return 0;
    return (player.stats.wins + record.$1) / totalMatches * 100;
  }

  Map<String, (int, int)> _calculateTournamentRecords(
    List<PlayerEntity> players,
    List<TournamentEntity> tournaments,
  ) {
    final records = <String, (int, int)>{};
    for (final tournament in tournaments) {
      final entries = {for (final entry in tournament.entries) entry.id: entry};
      for (final match in tournament.matches) {
        if (!match.isReady || !match.isComplete || match.isBye) continue;
        final first = entries[match.player1Id];
        final second = entries[match.player2Id];
        if (first == null || second == null) continue;
        if (match.winnerEntryId != first.id &&
            match.winnerEntryId != second.id) {
          continue;
        }
        final firstPlayer = _playerForEntry(players, first);
        final secondPlayer = _playerForEntry(players, second);
        if (firstPlayer != null) {
          final key = _playerKey(firstPlayer);
          final current = records[key] ?? (0, 0);
          records[key] =
              match.winnerEntryId == first.id
                  ? (current.$1 + 1, current.$2)
                  : (current.$1, current.$2 + 1);
        }
        if (secondPlayer != null) {
          final key = _playerKey(secondPlayer);
          final current = records[key] ?? (0, 0);
          records[key] =
              match.winnerEntryId == second.id
                  ? (current.$1 + 1, current.$2)
                  : (current.$1, current.$2 + 1);
        }
      }
    }
    return records;
  }

  PlayerEntity? _playerForEntry(
    List<PlayerEntity> players,
    TournamentEntry entry,
  ) {
    if (entry.isGuest) return null;
    return players
        .where(
          (player) =>
              (entry.registeredPlayerId != null &&
                  player.cloudId == entry.registeredPlayerId) ||
              (entry.playerCode.isNotEmpty &&
                  player.playerCode == entry.playerCode),
        )
        .firstOrNull;
  }

  String _playerKey(PlayerEntity player) =>
      player.clientId.isEmpty ? 'local:${player.id}' : player.clientId;

  Future<PlayerRegistrationResult> add({
    required String name,
    required String email,
    required String phone,
    required String nickname,
    required int handicap,
    String avatarPath = '',
  }) async {
    try {
      final result = await _repo.createRegisteredPlayer(
        name: name,
        email: email,
        phone: phone,
        nickname: nickname,
        handicap: handicap,
        avatarPath: avatarPath,
      );
      await _load();
      return result;
    } catch (e, st) {
      debugPrint('[PlayersProvider] ERROR adding player: $e\n$st');
      rethrow;
    }
  }

  Future<String?> updateRegistration(
    PlayerEntity player, {
    String? newAvatarPath,
  }) async {
    final temporaryPassword = await _repo.updateRegistration(
      player,
      newAvatarPath: newAvatarPath,
    );
    await _load();
    return temporaryPassword;
  }

  Future<void> archive(PlayerEntity player) async {
    await _repo.archivePlayer(player);
    await _load();
  }

  Future<PlayerEntity> renew(PlayerEntity player) async {
    final updated = await _repo.renewPlayer(player);
    await _load();
    return updated;
  }

  Future<String> resetPassword(PlayerEntity player) {
    return _repo.resetPlayerPassword(player);
  }

  Future<List<Map<String, dynamic>>> getManagers() {
    return _repo.getManagers();
  }

  Future<ManagerRegistrationResult> addManager({
    required String name,
    required String email,
  }) {
    return _repo.createManager(name: name, email: email);
  }

  Future<String> resetManagerPassword(String userId) {
    return _repo.resetManagerPassword(userId);
  }

  Future<void> setManagerActive(String userId, bool isActive) async {
    await _repo.setManagerActive(userId, isActive);
    await _load();
  }

  Future<void> recordWin(
    int id, {
    bool goldenBreak = false,
    bool breakAndRun = false,
  }) async {
    await _repo.recordMatch(
      id,
      won: true,
      goldenBreak: goldenBreak,
      breakAndRun: breakAndRun,
    );
    await _load();
  }

  Future<void> recordLoss(int id) async {
    await _repo.recordMatch(id, won: false);
    await _load();
  }

  Future<void> recordDraw(int id) async {
    await _repo.recordMatch(id, won: false, isDraw: true);
    await _load();
  }
}
