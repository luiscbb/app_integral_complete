import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../data/repositories/player_repository.dart';
import '../../domain/entities/player_stats.dart';

class PlayersProvider extends ChangeNotifier {
  final _repo = PlayerRepository();
  List<PlayerEntity> _players = [];
  bool _loading = true;

  List<PlayerEntity> get players => List.unmodifiable(_players);
  bool get isLoading => _loading;

  PlayersProvider() {
    _load();
  }

  Future<void> _load() async {
    _loading = true;
    notifyListeners();
    try {
      _players = await _repo.getAll();
      debugPrint('[PlayersProvider] Loaded ${_players.length} players');
    } catch (e, st) {
      debugPrint('[PlayersProvider] Error loading players: $e\n$st');
    }
    _loading = false;
    notifyListeners();
  }

  Future<void> add(String name, {String nickname = '', String avatar = ''}) async {
    try {
      debugPrint('[PlayersProvider] Adding player: name=$name, nickname=$nickname, avatar=$avatar');
      final player = PlayerEntity(name: name, nickname: nickname, avatar: avatar);
      debugPrint('[PlayersProvider] Player entity created: $player');

      final insertedId = await _repo.insert(player);
      debugPrint('[PlayersProvider] Player inserted with ID: $insertedId');

      await _load();
      debugPrint('[PlayersProvider] Player list reloaded');
    } catch (e, st) {
      debugPrint('[PlayersProvider] ERROR adding player: $e\n$st');
      rethrow;
    }
  }

  Future<void> update(PlayerEntity player) async {
    await _repo.update(player);
    await _load();
  }

  Future<void> delete(int id) async {
    await _repo.delete(id);
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
