import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/routes/app_routes.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_text_field.dart';

class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key});

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _loading = false;
  bool _obscurePass = true;
  bool _obscureConfirm = true;

  Future<void> _updatePassword() async {
    final pass = _passCtrl.text.trim();
    final confirm = _confirmCtrl.text.trim();

    if (pass.length < 6) {
      _show('La contraseña debe tener al menos 6 caracteres', Colors.orange);
      return;
    }
    if (pass != confirm) {
      _show('Las contraseñas no coinciden', Colors.orange);
      return;
    }

    setState(() => _loading = true);
    try {
      await Supabase.instance.client.auth
          .updateUser(UserAttributes(password: pass))
          .timeout(const Duration(seconds: 12));
      if (mounted) {
        _show('Contraseña actualizada correctamente', Colors.green);
        Navigator.pushReplacementNamed(context, AppRoutes.login);
      }
    } on TimeoutException catch (_) {
      _show('No hay respuesta del servidor. Intenta más tarde.', Colors.red);
    } on AuthException catch (e) {
      _show('Error: ${e.message}', Colors.red);
    } catch (e) {
      _show('Error: ${e.toString()}', Colors.red);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _show(String msg, Color color) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'NUEVA CONTRASEÑA',
                  style: TextStyle(color: primary, fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Ingresa una nueva contraseña para tu cuenta.',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                AppTextField(
                  controller: _passCtrl,
                  label: 'Nueva contraseña',
                  icon: Icons.lock_outline,
                  obscure: _obscurePass,
                  selectAllOnTap: true,
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePass ? Icons.visibility_off : Icons.visibility, color: Colors.white54, size: 20),
                    onPressed: () => setState(() => _obscurePass = !_obscurePass),
                  ),
                ),
                const SizedBox(height: 12),
                AppTextField(
                  controller: _confirmCtrl,
                  label: 'Confirmar contraseña',
                  icon: Icons.lock_outline,
                  obscure: _obscureConfirm,
                  selectAllOnTap: true,
                  suffixIcon: IconButton(
                    icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility, color: Colors.white54, size: 20),
                    onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                  ),
                ),
                const SizedBox(height: 16),
                AppButton(
                  label: 'GUARDAR',
                  icon: Icons.save,
                  isLoading: _loading,
                  onPressed: _updatePassword,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
