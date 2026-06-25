import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/config_remote_repository.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../features/sales/data/repositories/sales_repository.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _prefs = PreferencesService();
  bool _loading = false;

  Future<void> _login() async {
    if (_emailCtrl.text.isEmpty || _passCtrl.text.isEmpty) return;
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.auth
          .signInWithPassword(email: _emailCtrl.text.trim(), password: _passCtrl.text.trim())
          .timeout(const Duration(seconds: 12));

      if (res.user != null) {
        await _prefs.setUserName(res.user!.userMetadata?['full_name'] ?? 'Administrador');
        await _prefs.setBusinessName(res.user!.userMetadata?['business_name'] ?? 'Baumar Billar');
        await _prefs.setBillarId(res.user!.userMetadata?['billar_id'] ?? 'BILLAR_001');

        // Descargar configuracion remota si existe
        final remote = ConfigRemoteRepository();
        final remoteSettings = await remote.fetchSettings();
        if (remoteSettings != null) {
          await _prefs.setBusinessName(remoteSettings['business_name']?.toString() ?? _prefs.businessName);
          await _prefs.setBillarId(remoteSettings['billar_id']?.toString() ?? _prefs.billarId);
          final tableCount = (remoteSettings['table_count'] as num?)?.toInt() ?? _prefs.tableCount;
          await _prefs.setTableCount(tableCount);
          await _prefs.setHourlyRate((remoteSettings['hourly_rate'] as num?)?.toDouble() ?? _prefs.hourlyRate);
          final primaryColor = (remoteSettings['primary_color'] as num?)?.toInt();
          if (primaryColor != null) {
            await _prefs.setPrimaryColorValue(primaryColor);
            if (mounted) {
              context.read<ThemeProvider>().setPrimaryColor(Color(primaryColor));
            }
          }

          // Recrear mesas en la base de datos local
          final repo = SalesRepository();
          await repo.ensureTablesExist(tableCount);

          await _prefs.setIsFirstRun(false);
          if (mounted) {
            Navigator.pushReplacementNamed(context, AppRoutes.home);
          }
        } else {
          // No hay config remota: es primera vez con este usuario
          // Mantener isFirstRun = true para forzar el setup
          await _prefs.setIsFirstRun(true);
          if (mounted) {
            Navigator.pushReplacementNamed(context, AppRoutes.initialSetup);
          }
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo iniciar sesión. Verifique sus datos.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } on TimeoutException catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No hay respuesta del servidor. Intente de nuevo más tarde.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } on AuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: ${e.message}'), backgroundColor: Colors.red));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error de conexión: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: primary.withValues(alpha: 0.4)),
                boxShadow: [
                  BoxShadow(
                    color: primary.withValues(alpha: 0.1),
                    blurRadius: 30,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sports_bar_rounded, size: 72, color: primary),
                  const SizedBox(height: 16),
                  const Text(
                    'BAUMAR POS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Sistema Integral de Punto de Venta',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  AppTextField(controller: _emailCtrl, label: 'Email', icon: Icons.email_outlined),
                  AppTextField(
                    controller: _passCtrl,
                    label: 'Contraseña',
                    icon: Icons.lock_outline,
                    obscure: true,
                  ),
                  const SizedBox(height: 8),
                  AppButton(
                    label: 'ENTRAR',
                    icon: Icons.login,
                    isLoading: _loading,
                    onPressed: _login,
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed:
                        () => Navigator.pushReplacementNamed(context, AppRoutes.initialSetup),
                    child: const Text(
                      'Continuar sin cuenta (modo local)',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
