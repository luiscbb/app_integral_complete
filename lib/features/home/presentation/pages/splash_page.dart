import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/config_remote_repository.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../features/sales/data/repositories/sales_repository.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _rotationAnimation;
  bool _isOffline = false;
  String _statusMessage = 'INICIANDO...';

  ImageProvider? _logoImage;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(duration: const Duration(milliseconds: 2000), vsync: this);

    _scaleAnimation = CurvedAnimation(parent: _controller, curve: Curves.elasticOut);

    _rotationAnimation = Tween<double>(
      begin: 0,
      end: 2,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic));

    _controller.forward();

    _loadSplashLogo();

    Future.delayed(const Duration(seconds: 2), () async {
      if (!mounted) return;
      _checkSessionAndNavigate();
    });
  }

  void _loadSplashLogo() {
    // El splash siempre muestra el logo de la app principal (Baumar).
    // El logo del negocio cliente solo se ve dentro de la app (header, tickets, config).
    _logoImage = null;
    debugPrint('[SplashPage] Usando logo de app principal en splash');
  }

  void _setOfflineStatus(String message) {
    if (!mounted) return;
    setState(() {
      _isOffline = true;
      _statusMessage = message;
    });
  }

  Future<void> _checkSessionAndNavigate() async {
    final prefs = PreferencesService();
    final start = DateTime.now();
    debugPrint('[SplashPage] _checkSessionAndNavigate start $start');

    try {
      final session = Supabase.instance.client.auth.currentSession;
      debugPrint('[SplashPage] session=${session != null}');

      if (session == null) {
        // No hay sesión activa: forzar login.
        if (mounted) {
          Navigator.of(context).pushReplacementNamed(AppRoutes.login);
        }
        return;
      }

      final remote = ConfigRemoteRepository();
      debugPrint('[SplashPage] fetchSettings start');
      final remoteSettings = await remote.fetchSettings().timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          _setOfflineStatus('SIN CONEXIÓN - MODO LOCAL');
          return null;
        },
      );
      debugPrint('[SplashPage] fetchSettings end, tieneSettings=${remoteSettings != null}');

      if (remoteSettings != null) {
        await _applyRemoteSettings(prefs, remoteSettings);

        if (mounted) {
          Navigator.of(context).pushReplacementNamed(AppRoutes.home);
        }
        return;
      }

      // No hay configuración remota. Si localmente tampoco se configuró, ir al setup.
      if (mounted) {
        if (prefs.isFirstRun) {
          Navigator.of(context).pushReplacementNamed(AppRoutes.initialSetup);
        } else {
          Navigator.of(context).pushReplacementNamed(AppRoutes.home);
        }
      }
    } catch (e, st) {
      debugPrint('[Splash] Error durante navegación inicial: $e');
      debugPrint('[Splash] Stack: $st');
      _setOfflineStatus('SIN CONEXIÓN - MODO LOCAL');
      // En cualquier error de red/auth: descartar sesión y forzar login.
      try {
        await Supabase.instance.client.auth.signOut();
      } catch (_) {
        // Ignorar error al cerrar sesión.
      }
      if (mounted) {
        Navigator.of(context).pushReplacementNamed(AppRoutes.login);
      }
    }
    debugPrint('[SplashPage] _checkSessionAndNavigate end ${DateTime.now().difference(start).inMilliseconds}ms');
  }

  Future<void> _applyRemoteSettings(
    PreferencesService prefs,
    Map<String, dynamic> remoteSettings,
  ) async {
    // Siempre sincronizar la configuración remota activa (billar_id, tarifa, etc.)
    // para evitar que distintos dispositivos usen configuraciones locales desfasadas.
    final tableCount = (remoteSettings['table_count'] as num?)?.toInt() ?? 8;
    final primaryColor = (remoteSettings['primary_color'] as num?)?.toInt();
    final logoUrl = remoteSettings['logo_url']?.toString() ?? '';
    debugPrint('[SplashPage] Remoto logo_url recibido: "$logoUrl"');
    debugPrint('[SplashPage] Remoto business_name: ${remoteSettings['business_name']}');
    await prefs.setBusinessName(remoteSettings['business_name']?.toString() ?? 'Baumar Billar');
    await prefs.setBillarId(remoteSettings['billar_id']?.toString() ?? 'BILLAR_001');
    await prefs.setTableCount(tableCount);
    await prefs.setHourlyRate((remoteSettings['hourly_rate'] as num?)?.toDouble() ?? 0.0);
    await prefs.setLogoUrl(logoUrl);
    if (primaryColor != null) {
      await prefs.setPrimaryColorValue(0xFF000000 | (primaryColor.toInt() & 0x00FFFFFF));
      if (mounted) {
        context.read<ThemeProvider>().setPrimaryColor(Color(prefs.primaryColorValue));
      }
    }
    await prefs.setIsFirstRun(false);

    // Recrear mesas en la base de datos local según la config remota
    final repo = SalesRepository();
    await repo.ensureTablesExist(tableCount);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = context.watch<ThemeProvider>().primaryColor;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RotationTransition(
              turns: _rotationAnimation,
              child: ScaleTransition(
                scale: _scaleAnimation,
                child: Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: primary.withValues(alpha: 0.5), width: 2),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _logoImage != null
                      ? Image(image: _logoImage!, fit: BoxFit.cover)
                      : Image.asset('assets/baumar_8_personal-sf.png', fit: BoxFit.cover),
                ),
              ),
            ),
            const SizedBox(height: 40),
            ScaleTransition(
              scale: _scaleAnimation,
              child: const Text(
                "BAUMAR BILLIARDS POS",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 6,
                ),
              ),
            ),
            const SizedBox(height: 25),
            if (_isOffline)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9800).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFFF9800).withValues(alpha: 0.6), width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wifi_off, color: const Color(0xFFFF9800).withValues(alpha: 0.9), size: 18),
                    const SizedBox(width: 8),
                    Text(
                      _statusMessage,
                      style: TextStyle(
                        color: const Color(0xFFFF9800).withValues(alpha: 0.9),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            SizedBox(
              width: 40,
              child: CircularProgressIndicator(color: _isOffline ? const Color(0xFFFF9800) : primary, backgroundColor: Colors.white10),
            ),
          ],
        ),
      ),
    );
  }
}
