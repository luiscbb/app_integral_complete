import '../network/connectivity_service.dart';

class AppServices {
  static final ConnectivityService connectivityService = ConnectivityService();

  static void dispose() {
    connectivityService.dispose();
  }
}
