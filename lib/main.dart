import 'dart:async';
import 'dart:ui';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/routes/app_router.dart';
import 'core/routes/app_routes.dart';
import 'core/services/sync_service.dart';
import 'core/storage/account_storage.dart';
import 'core/storage/preferences_service.dart';
import 'core/theme/theme_provider.dart';

void main() {
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

  runApp(const AppBootstrap());
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  ThemeProvider? _themeProvider;
  Object? _initializationError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeServices();
    });
  }

  Future<void> _initializeServices() async {
    try {
      debugPrint('[MAIN] Supabase init start');
      // Cargar credenciales desde .env (no versionado). Fallback a --dart-define.
      try {
        await dotenv.load(fileName: '.env');
      } catch (e) {
        debugPrint('[MAIN] .env no encontrado, usando dart-define si existe: $e');
      }
      final supabaseUrl =
          dotenv.maybeGet('SUPABASE_URL') ?? const String.fromEnvironment('SUPABASE_URL');
      final supabaseAnonKey =
          dotenv.maybeGet('SUPABASE_ANON_KEY') ?? const String.fromEnvironment('SUPABASE_ANON_KEY');

      if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
        throw StateError(
          'Faltan credenciales de Supabase. Crea un archivo .env con '
          'SUPABASE_URL y SUPABASE_ANON_KEY (ver .env.example).',
        );
      }

      await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey);
      debugPrint('[MAIN] Supabase init done');

      await PreferencesService().init();
      debugPrint('[MAIN] Prefs init done');
      AccountStorage.initialize(Supabase.instance.client);

      final themeProvider = ThemeProvider()..init();
      debugPrint('[MAIN] ThemeProvider init done');
      if (!mounted) return;
      setState(() => _themeProvider = themeProvider);
      debugPrint('[MAIN] App services ready');
    } catch (error, stackTrace) {
      debugPrint('[MAIN] Initialization failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) setState(() => _initializationError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = _themeProvider;
    if (themeProvider != null) {
      return ChangeNotifierProvider.value(
        value: themeProvider,
        child: const BaumarPOSApp(),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: _initializationError == null
              ? const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.orangeAccent),
                    SizedBox(height: 16),
                    Text('Preparando aplicación...', style: TextStyle(color: Colors.white70)),
                  ],
                )
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No se pudo iniciar la aplicación.\n\n$_initializationError',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
        ),
      ),
    );
  }
}

class BaumarPOSApp extends StatefulWidget {
  const BaumarPOSApp({super.key});

  @override
  State<BaumarPOSApp> createState() => _BaumarPOSAppState();
}

class _BaumarPOSAppState extends State<BaumarPOSApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _appLinks = AppLinks();
  StreamSubscription? _deepLinkSubscription;
  StreamSubscription? _authSubscription;
  bool _skipFirstResumeSync = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initDeepLinkListener();
    _initAuthStateListener();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_skipFirstResumeSync) {
        _skipFirstResumeSync = false;
        return;
      }
      if (AccountStorage.instance.isActive &&
          Supabase.instance.client.auth.currentUser?.appMetadata['account_type'] != 'staff') {
        SyncService().schedulePendingSync();
      }
    }
  }

  void _initDeepLinkListener() async {
    // Capturar link cuando la app está cerrada o en segundo plano.
    final initial = await _appLinks.getInitialLink();
    _handleDeepLink(initial);
    _deepLinkSubscription = _appLinks.uriLinkStream.listen(_handleDeepLink);
  }

  void _handleDeepLink(Uri? uri) async {
    if (uri == null) return;
    debugPrint('[AUTH] Deep link recibido: $uri');
    if (uri.scheme != 'com.example.app_integral_complete') return;

    final fragment = uri.fragment;
    final params = Uri.splitQueryString(fragment);
    final type = uri.queryParameters['type'] ?? params['type'];
    final accessToken = params['access_token'];

    // Links de recuperación de Supabase v2 usan PKCE. Si hay access_token en
    // el fragmento, establecemos sesión manualmente; si no, confiamos en que
    // Supabase ya procesó el URI y navegamos a cambiar contraseña.
    if (type == 'recovery') {
      try {
        if (accessToken != null && accessToken.isNotEmpty) {
          await Supabase.instance.client.auth.setSession(accessToken);
        }
        _navigatorKey.currentState?.pushReplacementNamed(AppRoutes.resetPassword);
      } catch (e) {
        debugPrint('[AUTH] Error procesando deep link: $e');
      }
    }
  }

  void _initAuthStateListener() {
    // Fallback por si Supabase ya procesó la sesión de recuperación.
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
      debugPrint('[AUTH] event=${data.event} session=${data.session != null}');
      if (data.event == AuthChangeEvent.passwordRecovery) {
        _navigatorKey.currentState?.pushReplacementNamed(AppRoutes.resetPassword);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deepLinkSubscription?.cancel();
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    return MaterialApp(
      title: 'Baumar POS',
      debugShowCheckedModeBanner: false,
      theme: themeProvider.currentTheme,
      locale: const Locale('es', 'MX'),
      supportedLocales: const [Locale('es', 'MX')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      navigatorKey: _navigatorKey,
      initialRoute: AppRoutes.splash,
      onGenerateRoute: AppRouter.onGenerateRoute,
    );
  }
}
