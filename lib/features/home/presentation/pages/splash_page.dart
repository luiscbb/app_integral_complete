import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/config_remote_repository.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/storage/account_storage.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../auth/data/auth_access_repository.dart';
import '../../../../features/sales/data/repositories/sales_repository.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key, this.enableStaffForIntegration = false});

  final bool enableStaffForIntegration;

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _rotationAnimation;
  bool _isOffline = false;
  bool _canRetry = false;
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_checkSessionAndNavigate());
    });
  }

  void _loadSplashLogo() {
    // El splash siempre muestra el logo de la app principal (Baumar).
    // El logo del negocio cliente solo se ve dentro de la app (header, tickets, config).
    _logoImage = null;
    debugPrint('[SplashPage] Usando logo de app principal en splash');
  }

  Future<void> _checkSessionAndNavigate() async {
    if (mounted) {
      setState(() {
        _isOffline = false;
        _canRetry = false;
      });
    }
    final prefs = PreferencesService();
    final initialSession = Supabase.instance.client.auth.currentSession;
    final start = DateTime.now();
    debugPrint('[SplashPage] _checkSessionAndNavigate start $start');

    try {
      await prefs.ensureLegacyPreferencesSnapshot();
      final session = initialSession;
      debugPrint('[SplashPage] session=${session != null}');

      if (session == null) {
        // No hay sesión activa: forzar login.
        if (mounted) {
          Navigator.of(context).pushReplacementNamed(AppRoutes.login);
        }
        return;
      }

      void requireInitialSession() {
        final current = Supabase.instance.client.auth.currentSession;
        if (current?.user.id != session.user.id ||
            current?.accessToken != session.accessToken) {
          throw StateError('La sesión cambió durante el inicio.');
        }
      }

      final account = await AuthAccessRepository(
        enableStaffForIntegration: widget.enableStaffForIntegration,
      ).resolveCurrentAccount().timeout(
        const Duration(seconds: 8),
      );
      requireInitialSession();
      if (account.kind == AccountKind.player || account.kind == AccountKind.manager ||
          account.kind == AccountKind.staff && widget.enableStaffForIntegration) {
        await AccountStorage.instance.activate(
          billarId: account.billarId,
          migrateLegacyOwner: false,
        );
        requireInitialSession();
        if (mounted) context.read<ThemeProvider>().reloadFromPreferences();
        if (account.billarId.isNotEmpty) {
          await prefs.setBillarId(account.billarId);
        }
        final route =
            account.mustChangePassword
                ? AppRoutes.changeTemporaryPassword
                : account.kind == AccountKind.player
                ? AppRoutes.playerPortal
                : account.kind == AccountKind.staff
                ? AppRoutes.staffPortal
                : AppRoutes.managerPortal;
        if (mounted) {
          Navigator.of(context).pushReplacementNamed(route, arguments: account.player);
        }
        return;
      }
      if (account.kind == AccountKind.blocked ||
          account.kind == AccountKind.staff ||
          (account.kind == AccountKind.unavailable &&
              requiresManagedAccountAccess(session.user))) {
        await Supabase.instance.client.auth.signOut();
        if (mounted) {
          Navigator.of(context).pushReplacementNamed(AppRoutes.login);
        }
        return;
      }
      final remote = ConfigRemoteRepository();
      debugPrint('[SplashPage] fetchSettings start');
      final remoteSettings = await remote.fetchSettings().timeout(
        const Duration(seconds: 8),
      );
      requireInitialSession();
      debugPrint('[SplashPage] fetchSettings end, tieneSettings=${remoteSettings != null}');

      if (account.kind != AccountKind.owner) {
        if (remoteSettings != null) {
          throw StateError('No se pudo verificar al administrador del negocio.');
        }
        if (mounted) Navigator.of(context).pushReplacementNamed(AppRoutes.initialSetup);
        return;
      }
      if (remoteSettings == null || account.mustChangePassword ||
          remoteSettings['billar_id'] != account.billarId) {
        throw StateError('No se pudo verificar la configuración del administrador.');
      }
      await AccountStorage.instance.activate(
        billarId: account.billarId,
        migrateLegacyOwner: true,
      );
      requireInitialSession();
      if (mounted) context.read<ThemeProvider>().reloadFromPreferences();
      await _applyRemoteSettings(prefs, remoteSettings);
      if (mounted) {
        Navigator.of(context).pushReplacementNamed(AppRoutes.home);
        SyncService().schedulePendingSync();
      }
      return;
    } catch (e, st) {
      debugPrint('[Splash] Error durante navegación inicial: $e');
      debugPrint('[Splash] Stack: $st');
      final current = Supabase.instance.client.auth.currentSession;
      if (current?.user.id != initialSession?.user.id ||
          current?.accessToken != initialSession?.accessToken) {
        if (mounted) unawaited(_checkSessionAndNavigate());
        return;
      }
      if ((e is SocketException || e is http.ClientException || e is TimeoutException) &&
          initialSession != null && !AccountStorage.instance.requiresRestart) {
        final billar = AccountStorage.instance.verifiedOwnerBillar(initialSession.user.id);
        if (billar != null) {
          try {
            await AccountStorage.instance.activate(
              billarId: billar, migrateLegacyOwner: false, offline: true,
            );
            if (mounted) {
              context.read<ThemeProvider>().reloadFromPreferences();
              Navigator.of(context).pushReplacementNamed(AppRoutes.home);
              SyncService().schedulePendingSync();
            }
            return;
          } catch (offlineError, offlineStack) {
            debugPrint('[Splash] No se pudo abrir la cuenta sin conexión: $offlineError\n$offlineStack');
          }
        }
      }
      if (mounted) {
        setState(() {
          _isOffline = true;
          _statusMessage = AccountStorage.instance.requiresRestart
              ? 'CIERRA Y VUELVE A ABRIR LA APLICACIÓN'
              : 'NO SE PUDO VERIFICAR LA CUENTA';
          _canRetry = !AccountStorage.instance.requiresRestart;
        });
      }
    }
    debugPrint(
      '[SplashPage] _checkSessionAndNavigate end ${DateTime.now().difference(start).inMilliseconds}ms',
    );
  }

  Future<void> _applyRemoteSettings(
    PreferencesService prefs,
    Map<String, dynamic> remoteSettings,
  ) async {
    // Siempre sincronizar la configuración remota activa (billar_id, tarifa, etc.)
    // para evitar que distintos dispositivos usen configuraciones locales desfasadas.
    final tableCount = (remoteSettings['table_count'] as num?)?.toInt() ?? 8;
    final primaryColor = (remoteSettings['primary_color'] as num?)?.toInt();
    final remoteLogoUrl = ConfigRemoteRepository.normalizeLogoUrl(
      remoteSettings['logo_url']?.toString(),
    );
    final logoUrl = remoteLogoUrl.isNotEmpty ? remoteLogoUrl : prefs.logoUrl;
    debugPrint('[SplashPage] Remoto logo_url recibido: "$logoUrl"');
    debugPrint('[SplashPage] Remoto business_name: ${remoteSettings['business_name']}');
    await prefs.setBusinessName(remoteSettings['business_name']?.toString() ?? 'Baumar Billar');
    await prefs.setBillarId(remoteSettings['billar_id']?.toString() ?? 'BILLAR_001');
    await prefs.setTableCount(tableCount);
    await prefs.setHourlyRate((remoteSettings['hourly_rate'] as num?)?.toDouble() ?? 0.0);
    await prefs.setLogoUrl(logoUrl);
    await prefs.setBusinessAddress(remoteSettings['business_address']?.toString() ?? '');
    await prefs.setBusinessStreet(remoteSettings['business_street']?.toString() ?? '');
    await prefs.setBusinessExtNumber(remoteSettings['business_ext_number']?.toString() ?? '');
    await prefs.setBusinessIntNumber(remoteSettings['business_int_number']?.toString() ?? '');
    await prefs.setBusinessColony(remoteSettings['business_colony']?.toString() ?? '');
    await prefs.setBusinessZipCode(remoteSettings['business_zip_code']?.toString() ?? '');
    await prefs.setBusinessCity(remoteSettings['business_city']?.toString() ?? '');
    await prefs.setBusinessState(remoteSettings['business_state']?.toString() ?? '');
    await prefs.setBusinessPhone(remoteSettings['business_phone']?.toString() ?? '');
    await prefs.setBusinessWhatsapp(remoteSettings['business_whatsapp']?.toString() ?? '');
    await prefs.setBusinessSlogan(remoteSettings['business_slogan']?.toString() ?? '');
    await prefs.setBusinessWebsite(remoteSettings['business_website']?.toString() ?? '');
    await prefs.setTicketFarewell(
      remoteSettings['ticket_farewell']?.toString() ?? 'GRACIAS POR SU COMPRA',
    );
    final remoteTicketCounter = (remoteSettings['ticket_counter'] as num?)?.toInt();
    if (remoteTicketCounter != null && remoteTicketCounter > prefs.ticketCounter) {
      await prefs.setTicketCounter(remoteTicketCounter);
    }

    final rawSocialNetworks = remoteSettings['social_networks'];
    if (rawSocialNetworks is Map) {
      await prefs.setSocialNetworks(
        rawSocialNetworks.map((key, value) => MapEntry(key.toString(), value.toString())),
      );
    } else if (rawSocialNetworks is String && rawSocialNetworks.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawSocialNetworks);
        if (decoded is Map) {
          await prefs.setSocialNetworks(
            decoded.map((key, value) => MapEntry(key.toString(), value.toString())),
          );
        }
      } on FormatException catch (e) {
        debugPrint('[SplashPage] social_networks inválido en configuración remota: $e');
      }
    }
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
                  child:
                      _logoImage != null
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
                  border: Border.all(
                    color: const Color(0xFFFF9800).withValues(alpha: 0.6),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.wifi_off,
                      color: const Color(0xFFFF9800).withValues(alpha: 0.9),
                      size: 18,
                    ),
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
            if (_canRetry)
              TextButton(
                onPressed: () => unawaited(_checkSessionAndNavigate()),
                child: const Text('REINTENTAR'),
              )
            else if (!_isOffline)
              SizedBox(
                width: 40,
                child: CircularProgressIndicator(
                  color: _isOffline ? const Color(0xFFFF9800) : primary,
                  backgroundColor: Colors.white10,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
