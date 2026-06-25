import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityService {
  final Connectivity _connectivity = Connectivity();
  final StreamController<bool> _controller = StreamController<bool>.broadcast();

  ConnectivityService() {
    _connectivity.onConnectivityChanged.listen((_) async {
      final online = await isOnline;
      _controller.add(online);
    });
  }

  Future<bool> get isOnline async {
    final result = await _connectivity.checkConnectivity();
    return result.first != ConnectivityResult.none;
  }

  Stream<bool> get connectionChanges => _controller.stream.distinct();

  void dispose() => _controller.close();
}
