import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/config_remote_repository.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/services/sync_service.dart';
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
  bool _obscurePass = true;

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
          await _prefs.setBusinessName(
            remoteSettings['business_name']?.toString() ?? _prefs.businessName,
          );
          await _prefs.setBillarId(remoteSettings['billar_id']?.toString() ?? _prefs.billarId);
          await _prefs.setBusinessAddress(
            remoteSettings['business_address']?.toString() ?? _prefs.businessAddress,
          );
          await _prefs.setBusinessStreet(
            remoteSettings['business_street']?.toString() ?? _prefs.businessStreet,
          );
          await _prefs.setBusinessExtNumber(
            remoteSettings['business_ext_number']?.toString() ?? _prefs.businessExtNumber,
          );
          await _prefs.setBusinessIntNumber(
            remoteSettings['business_int_number']?.toString() ?? _prefs.businessIntNumber,
          );
          await _prefs.setBusinessColony(
            remoteSettings['business_colony']?.toString() ?? _prefs.businessColony,
          );
          await _prefs.setBusinessZipCode(
            remoteSettings['business_zip_code']?.toString() ?? _prefs.businessZipCode,
          );
          await _prefs.setBusinessCity(
            remoteSettings['business_city']?.toString() ?? _prefs.businessCity,
          );
          await _prefs.setBusinessState(
            remoteSettings['business_state']?.toString() ?? _prefs.businessState,
          );
          await _prefs.setBusinessPhone(
            remoteSettings['business_phone']?.toString() ?? _prefs.businessPhone,
          );
          await _prefs.setBusinessWhatsapp(
            remoteSettings['business_whatsapp']?.toString() ?? _prefs.businessWhatsapp,
          );
          await _prefs.setBusinessSlogan(
            remoteSettings['business_slogan']?.toString() ?? _prefs.businessSlogan,
          );
          await _prefs.setBusinessWebsite(
            remoteSettings['business_website']?.toString() ?? _prefs.businessWebsite,
          );
          await _prefs.setTicketFarewell(
            remoteSettings['ticket_farewell']?.toString() ?? _prefs.ticketFarewell,
          );
          final rawSocials = remoteSettings['social_networks'];
          if (rawSocials != null) {
            try {
              Map<String, String> parsed = {};
              if (rawSocials is String) {
                parsed = (jsonDecode(rawSocials) as Map<String, dynamic>).map(
                  (k, v) => MapEntry(k, v.toString()),
                );
              } else if (rawSocials is Map) {
                parsed = rawSocials.map((k, v) => MapEntry(k.toString(), v.toString()));
              }
              await _prefs.setSocialNetworks(parsed);
            } catch (_) {}
          }
          final tableCount = (remoteSettings['table_count'] as num?)?.toInt() ?? _prefs.tableCount;
          await _prefs.setTableCount(tableCount);
          await _prefs.setHourlyRate(
            (remoteSettings['hourly_rate'] as num?)?.toDouble() ?? _prefs.hourlyRate,
          );
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

          // Descargar mesas desde la nube
          await SyncService().pullTablesFromCloud();

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

  Future<void> _forgotPassword() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      _showError('Ingresa tu correo electrónico para enviarte el código');
      return;
    }
    final emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+');
    if (!emailRegex.hasMatch(email)) {
      _showError('Ingresa un correo electrónico válido');
      return;
    }
    setState(() => _loading = true);
    try {
      await Supabase.instance.client.auth
          .resetPasswordForEmail(email)
          .timeout(const Duration(seconds: 12));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Código enviado. Revisa tu correo e ingrésalo.'),
            backgroundColor: Colors.green,
          ),
        );
        await _showCodeResetDialog(email);
      }
    } on TimeoutException catch (_) {
      _showError('No hay respuesta del servidor. Intenta más tarde.');
    } on AuthException catch (e) {
      _showErrorDialog('Error', e.message);
    } catch (e) {
      _showErrorDialog('Error', e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showCodeResetDialog(String email) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => _CodeResetDialog(
            email: email,
            onSuccess: () {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Contraseña actualizada. Inicia sesión.'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            },
          ),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.orange));
  }

  Future<void> _showRecoveryLinkDialog() async {
    final linkCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text(
              'RESTABLECER CON CONTRASEÑA',
              style: TextStyle(color: Colors.orange, fontSize: 14),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Pega el enlace completo que recibiste por correo y la app lo procesará.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 12),
                AppTextField(controller: linkCtrl, label: 'Pega el enlace', icon: Icons.link),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar', style: TextStyle(color: Colors.white38)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('CONTINUAR', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
    );

    if (confirmed != true) return;
    final raw = linkCtrl.text.trim();
    if (raw.isEmpty) return;

    Uri? uri;
    try {
      uri = Uri.parse(raw);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enlace no válido'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    String? token;
    if (uri.fragment.isNotEmpty) {
      final params = Uri.splitQueryString(uri.fragment);
      token = params['access_token'];
    }
    if (token == null && uri.queryParameters.containsKey('access_token')) {
      token = uri.queryParameters['access_token'];
    }
    if (token == null && uri.queryParameters.containsKey('token')) {
      token = uri.queryParameters['token'];
    }

    if (token == null || token.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se encontró el token de recuperación en el enlace.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    if (token.startsWith('pkce_')) {
      _showErrorDialog(
        'Enlace no compatible',
        'El enlace que recibiste es del tipo PKCE y solo puede abrirse automáticamente desde la app cuando tocas el botón en el correo.\n\n'
            'Si no funciona el botón del correo, pide el código numérico de 6 dígitos o espera unos minutos y vuelve a enviar el correo con un esquema de app configurado.',
      );
      return;
    }

    setState(() => _loading = true);
    try {
      await Supabase.instance.client.auth
          .verifyOTP(type: OtpType.recovery, token: token)
          .timeout(const Duration(seconds: 12));
      if (mounted) {
        Navigator.pushReplacementNamed(context, AppRoutes.resetPassword);
      }
    } on TimeoutException catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No hay respuesta del servidor. Intenta más tarde.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } on AuthException catch (e) {
      if (mounted) {
        _showErrorDialog('Error de autenticación', e.message);
      }
    } catch (e, st) {
      if (mounted) {
        _showErrorDialog('Error inesperado', e.toString());
        debugPrint('[RecoveryLink] ERROR: $e');
        debugPrint('[RecoveryLink] STACK: $st');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(title, style: const TextStyle(color: Colors.redAccent, fontSize: 16)),
            content: SingleChildScrollView(
              child: Text(message, style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cerrar', style: TextStyle(color: Colors.white54)),
              ),
            ],
          ),
    );
  }

  Widget _buildLogoWidget() {
    return Image.asset('assets/baumar_8_personal-sf.png', width: 160, height: 160);
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
                  _buildLogoWidget(),
                  const SizedBox(height: 16),
                  const Text(
                    'BAUMAR',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 6,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'BILLIARDS POS',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Sistema Integral de Punto de Venta',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  AppTextField(
                    controller: _emailCtrl,
                    label: 'Email',
                    icon: Icons.email_outlined,
                    selectAllOnTap: true,
                  ),
                  AppTextField(
                    controller: _passCtrl,
                    label: 'Contraseña',
                    icon: Icons.lock_outline,
                    obscure: _obscurePass,
                    selectAllOnTap: true,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePass ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white54,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscurePass = !_obscurePass),
                    ),
                  ),
                  const SizedBox(height: 16),
                  AppButton(
                    label: 'ENTRAR',
                    icon: Icons.login,
                    isLoading: _loading,
                    onPressed: _login,
                  ),
                  Align(
                    alignment: Alignment.center,
                    child: TextButton(
                      onPressed: _loading ? null : _forgotPassword,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        '¿Olvidaste tu contraseña?',
                        style: TextStyle(color: primary.withValues(alpha: 0.8), fontSize: 12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.center,
                    child: TextButton(
                      onPressed: _loading ? null : _showRecoveryLinkDialog,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        //Tengo un enlace de recuperación
                        '',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
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

class _CodeResetDialog extends StatefulWidget {
  final String email;
  final VoidCallback onSuccess;
  const _CodeResetDialog({required this.email, required this.onSuccess});

  @override
  State<_CodeResetDialog> createState() => _CodeResetDialogState();
}

class _CodeResetDialogState extends State<_CodeResetDialog> {
  final _codeCtrl = TextEditingController();
  bool _saving = false;

  Future<void> _verify() async {
    final code = _codeCtrl.text.trim();

    if (code.length < 6) {
      _showError('Código incompleto', 'Ingresa los 6 dígitos del correo.');
      return;
    }

    setState(() => _saving = true);
    try {
      await Supabase.instance.client.auth
          .verifyOTP(type: OtpType.recovery, token: code, email: widget.email)
          .timeout(const Duration(seconds: 12));
      if (mounted) {
        Navigator.pop(context);
        Navigator.pushReplacementNamed(context, AppRoutes.resetPassword);
      }
    } on TimeoutException catch (_) {
      _showError('Sin respuesta', 'No hay respuesta del servidor. Intenta más tarde.');
    } on AuthException catch (e) {
      _showError('Error', e.message);
    } catch (e) {
      _showError('Error', e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(String title, String message) {
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(title, style: const TextStyle(color: Colors.redAccent, fontSize: 16)),
            content: Text(message, style: const TextStyle(color: Colors.white70, fontSize: 13)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cerrar', style: TextStyle(color: Colors.white54)),
              ),
            ],
          ),
    );
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'RESTABLECER CONTRASEÑA',
        style: TextStyle(color: Colors.orange, fontSize: 15),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Ingresa el código de 6 dígitos enviado a ${widget.email}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: _codeCtrl,
              label: 'Código de 6 dígitos',
              icon: Icons.pin,
              isNumber: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar', style: TextStyle(color: Colors.white38)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
          onPressed: _saving ? null : _verify,
          child:
              _saving
                  ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                  : const Text('VERIFICAR', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
