import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/routes/app_router.dart';
import 'core/routes/app_routes.dart';
import 'core/storage/preferences_service.dart';
import 'core/theme/theme_provider.dart';

void main() async {
  debugPrint('[MAIN] Start ${DateTime.now()}');
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[MAIN] WidgetsFlutterBinding OK');

  // Silenciar errores de teclado específicos de Flutter en Android
  PlatformDispatcher.instance.onError = (error, stack) {
    final msg = error.toString();
    if (error is AssertionError &&
        msg.contains('KeyUpEvent') &&
        msg.contains('physical key is not pressed')) {
      return true;
    }
    return false;
  };

  debugPrint('[MAIN] Supabase init start');
  await Supabase.initialize(
    url: 'https://lxsikbxeuktwufhmsucs.supabase.co',
    anonKey: 'sb_publishable_55e5z0F8Nnk-rUsvTSTV8A_uusxlMgq',
  );
  debugPrint('[MAIN] Supabase init done');

  final prefs = PreferencesService();
  await prefs.init();
  debugPrint('[MAIN] Prefs init done');

  final themeProvider = ThemeProvider()..init();
  debugPrint('[MAIN] ThemeProvider init done');

  runApp(ChangeNotifierProvider.value(
    value: themeProvider,
    child: const BaumarPOSApp(),
  ));
  debugPrint('[MAIN] runApp done');
}

class BaumarPOSApp extends StatelessWidget {
  const BaumarPOSApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    return MaterialApp(
      title: 'Baumar POS',
      debugShowCheckedModeBanner: false,
      theme: themeProvider.currentTheme,
      initialRoute: AppRoutes.splash,
      onGenerateRoute: AppRouter.onGenerateRoute,
    );
  }
}
