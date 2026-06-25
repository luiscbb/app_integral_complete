import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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

    Timer(const Duration(seconds: 2), () async {
      if (!mounted) return;
      await _checkSessionAndNavigate();
    });
  }

  Future<void> _checkSessionAndNavigate() async {
    final prefs = PreferencesService();

    if (prefs.isFirstRun) {
      // Aun no se configuro localmente. Intentar recuperar sesion existente.
      final remote = ConfigRemoteRepository();
      final remoteSettings = await remote.fetchSettings();

      if (remoteSettings != null && mounted) {
        // Hay config en la nube: restaurar localmente y saltar setup
        final tableCount = (remoteSettings['table_count'] as num?)?.toInt() ?? 8;
        final primaryColor = (remoteSettings['primary_color'] as num?)?.toInt();
        await prefs.setBusinessName(remoteSettings['business_name']?.toString() ?? 'Baumar Billar');
        await prefs.setBillarId(remoteSettings['billar_id']?.toString() ?? 'BILLAR_001');
        await prefs.setTableCount(tableCount);
        await prefs.setHourlyRate((remoteSettings['hourly_rate'] as num?)?.toDouble() ?? 0.0);
        if (primaryColor != null) {
          await prefs.setPrimaryColorValue(primaryColor);
          if (mounted) {
            context.read<ThemeProvider>().setPrimaryColor(Color(primaryColor));
          }
        }
        await prefs.setIsFirstRun(false);

        // Recrear mesas en la base de datos local
        final repo = SalesRepository();
        await repo.ensureTablesExist(tableCount);

        if (mounted) {
          Navigator.of(context).pushReplacementNamed(AppRoutes.home);
        }
        return;
      }
    }

    if (mounted) {
      if (prefs.isFirstRun) {
        Navigator.of(context).pushReplacementNamed(AppRoutes.login);
      } else {
        Navigator.of(context).pushReplacementNamed(AppRoutes.home);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                child: Image.asset('assets/baumar_8_personal-sf.png', width: 180, height: 180),
              ),
            ),
            const SizedBox(height: 40),
            ScaleTransition(
              scale: _scaleAnimation,
              child: const Text(
                "BAUMAR APPS",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 6,
                ),
              ),
            ),
            const SizedBox(height: 25),
            const SizedBox(
              width: 40,
              child: CircularProgressIndicator(color: Colors.blue, backgroundColor: Colors.white10),
            ),
          ],
        ),
      ),
    );
  }
}
