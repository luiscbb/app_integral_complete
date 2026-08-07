import 'package:flutter/material.dart';
import '../../data/repositories/games_repository.dart';
import '../../domain/entities/game_match_entity.dart';

class GameProvider extends ChangeNotifier {
  final _repo = GamesRepository();

  String _gameType = 'Bola 9';
  int _maxBalls = 9;
  final Set<int> _pottedBalls = {};
  int _playerSets = 0;
  int _opponentSets = 0;
  int _targetSets = 5;
  bool _lostByEarlyEight = false;

  int? _player1Id;
  int? _player2Id;
  String _player1Name = 'TÚ';
  String _player2Name = 'RIVAL';

  final List<int> _targetOptions = [0, 3, 5, 7, 11, 13];

  String get gameType => _gameType;
  int get maxBalls => _maxBalls;
  int get playerSets => _playerSets;
  int get opponentSets => _opponentSets;
  int get targetSets => _targetSets;
  List<int> get targetOptions => _targetOptions;
  Set<int> get pottedBalls => _pottedBalls;
  bool get lostByEarlyEight => _lostByEarlyEight;
  String get player1Name => _player1Name;
  String get player2Name => _player2Name;

  bool get canFinishSet => _pottedBalls.isNotEmpty || _lostByEarlyEight;

  bool get isGoldenBreak {
    if (_gameType != 'Bola 9') return false;
    return _pottedBalls.contains(9) && _pottedBalls.length <= 2;
  }

  double get accuracy {
    if (_pottedBalls.isEmpty) return 0.0;
    final totalTargetBalls = (_gameType == 'Bola 8') ? 15 : _maxBalls;
    return (_pottedBalls.length / totalTargetBalls) * 100;
  }

  void setGameType(String type) {
    _gameType = type;
    _maxBalls = (type == 'Bola 8') ? 15 : (type == 'Bola 9' ? 9 : 10);
    resetRack();
    notifyListeners();
  }

  void setTargetSets(int value) {
    _targetSets = value;
    notifyListeners();
  }

  void toggleBall(int ballNumber) {
    if (_pottedBalls.contains(ballNumber)) {
      _pottedBalls.remove(ballNumber);
    } else {
      _pottedBalls.add(ballNumber);
    }
    notifyListeners();
  }

  void setPlayers({int? player1Id, int? player2Id, String player1Name = 'TÚ', String player2Name = 'RIVAL'}) {
    _player1Id = player1Id;
    _player2Id = player2Id;
    _player1Name = player1Name;
    _player2Name = player2Name;
    notifyListeners();
  }

  Future<void> loseByEarlyEight() async {
    _lostByEarlyEight = true;
    notifyListeners();
  }

  Future<bool> incrementPlayerSet() async {
    final golden = isGoldenBreak;
    final currentAcc = accuracy;
    _playerSets++;
    await _saveStats(isWin: true, wasGolden: golden, finalAcc: currentAcc);
    final isMatchOver = _targetSets > 0 && _playerSets >= _targetSets;
    _pottedBalls.clear();
    _lostByEarlyEight = false;
    notifyListeners();
    return isMatchOver;
  }

  Future<bool> incrementOpponentSet() async {
    final currentAcc = accuracy;
    _opponentSets++;
    await _saveStats(isWin: false, wasGolden: false, finalAcc: currentAcc);
    final isMatchOver = _targetSets > 0 && _opponentSets >= _targetSets;
    _pottedBalls.clear();
    _lostByEarlyEight = false;
    notifyListeners();
    return isMatchOver;
  }

  Future<void> _saveStats({required bool isWin, bool wasGolden = false, required double finalAcc}) async {
    try {
      String resultText;
      if (isWin) {
        resultText = wasGolden ? 'GOLDEN BREAK' : 'Victoria';
      } else {
        resultText = _lostByEarlyEight ? 'DERROTA (BOLA 8)' : 'Derrota';
      }

      await _repo.saveMatch(GameMatchEntity(
        gameType: _gameType,
        player1Id: _player1Id,
        player2Id: _player2Id,
        winnerId: isWin ? _player1Id : _player2Id,
        playerScore: _playerSets,
        opponentScore: _opponentSets,
        goldenBreak: wasGolden,
        breakAndRun: false,
        isDraw: false,
        accuracy: finalAcc,
        efficiency: wasGolden ? 100.0 : finalAcc,
        notes: resultText,
        date: DateTime.now(),
      ));
    } catch (e) {
      debugPrint('[GameProvider] Error al guardar stats: $e');
    }
  }

  void resetRack() {
    _pottedBalls.clear();
    _lostByEarlyEight = false;
    notifyListeners();
  }

  void resetMatch() {
    _playerSets = 0;
    _opponentSets = 0;
    _pottedBalls.clear();
    _lostByEarlyEight = false;
    notifyListeners();
  }
}
