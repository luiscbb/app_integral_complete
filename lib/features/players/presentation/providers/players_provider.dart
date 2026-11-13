import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../data/repositories/player_repository.dart';
import '../../domain/entities/player_stats.dart';

class PlayersProvider extends ChangeNotifier {
  final _repo = PlayerRepository();
  List<PlayerEntity> _players = [];
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
      debugPrint('[PlayersProvider] Loaded ${_players.length} players');
    } catch (e, st) {
      debugPrint('[PlayersProvider] Error loading players: $e\n$st');
    }
    _loading = false;
    notifyListeners();
  }

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

  Future<void> recordWin(int id, {bool goldenBreak = false, bool breakAndRun = false}) async {
    await _repo.recordMatch(id, won: true, goldenBreak: goldenBreak, breakAndRun: breakAndRun);
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
