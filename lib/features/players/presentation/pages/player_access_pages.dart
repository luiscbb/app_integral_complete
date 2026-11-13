import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/routes/app_routes.dart';
import '../../../auth/data/auth_access_repository.dart';
import '../../domain/entities/player_stats.dart';

class ChangeTemporaryPasswordPage extends StatefulWidget {
  const ChangeTemporaryPasswordPage({super.key});

  @override
  State<ChangeTemporaryPasswordPage> createState() =>
      _ChangeTemporaryPasswordPageState();
}

class _ChangeTemporaryPasswordPageState
    extends State<ChangeTemporaryPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _access = AuthAccessRepository();
  bool _saving = false;
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await _access.finishPasswordChange(_password.text);
      final account = await _access.resolveCurrentAccount();
      if (!mounted) return;
      final route = switch (account.kind) {
        AccountKind.player => AppRoutes.playerPortal,
        AccountKind.manager => AppRoutes.managerPortal,
        AccountKind.owner => AppRoutes.home,
        AccountKind.unavailable => AppRoutes.login,
      };
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(route, (_) => false, arguments: account.player);
    } catch (e, st) {
      debugPrint(
        '[ChangeTemporaryPasswordPage] Password update failed: $e\n$st',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_errorMessage(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _errorMessage(Object error) {
    final text = error.toString();
    return text.startsWith('StateError: ')
        ? text.substring('StateError: '.length)
        : text;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CAMBIAR CONTRASEÑA')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                const Icon(Icons.lock_reset, size: 56, color: Colors.amber),
                const SizedBox(height: 16),
                const Text(
                  'Por seguridad, crea una contraseña personal para continuar.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'Nueva contraseña',
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                    ),
                  ),
                  validator:
                      (value) =>
                          (value?.length ?? 0) < 8
                              ? 'Usa al menos 8 caracteres'
                              : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _confirm,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirmar contraseña',
                  ),
                  validator:
                      (value) =>
                          value != _password.text
                              ? 'Las contraseñas no coinciden'
                              : null,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child:
                      _saving
                          ? const CircularProgressIndicator()
                          : const Text('GUARDAR Y CONTINUAR'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PlayerPortalPage extends StatelessWidget {
  final PlayerEntity player;

  const PlayerPortalPage({super.key, required this.player});

  Future<void> _signOut(BuildContext context) async {
    await Supabase.instance.client.auth.signOut();
    if (context.mounted) {
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final expiry = DateTime.tryParse(player.expiresAt);
    final status =
        player.archivedAt != null
            ? 'INSCRIPCIÓN ARCHIVADA'
            : player.isExpired
            ? 'INSCRIPCIÓN VENCIDA'
            : player.isActive
            ? 'INSCRIPCIÓN ACTIVA'
            : 'INSCRIPCIÓN INACTIVA';

    return Scaffold(
      appBar: AppBar(
        title: const Text('MI REGISTRO'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: () => _signOut(context),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              CircleAvatar(
                radius: 48,
                backgroundImage:
                    player.avatar.startsWith('http')
                        ? NetworkImage(player.avatar)
                        : null,
                child:
                    player.avatar.isEmpty
                        ? const Icon(Icons.person, size: 48)
                        : null,
              ),
              const SizedBox(height: 20),
              Text(
                player.displayName,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text('Código ${player.playerCode}', textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  6,
                  (index) => Icon(
                    index < player.level
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color: index < player.level ? Colors.amber : Colors.white24,
                  ),
                ),
              ),
              if (player.phone.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Teléfono ${player.phone}', textAlign: TextAlign.center),
              ],
              const SizedBox(height: 24),
              Card(
                child: ListTile(
                  leading: Icon(
                    player.enrollmentIsActive
                        ? Icons.verified_user
                        : Icons.warning_amber,
                  ),
                  title: Text(status),
                  subtitle: Text(
                    expiry == null
                        ? 'Vigencia no disponible'
                        : 'Válida hasta ${MaterialLocalizations.of(context).formatMediumDate(expiry)}',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => Navigator.pushNamed(context, AppRoutes.games),
                icon: const Icon(Icons.sports_bar),
                label: const Text('RETAS / TRAINING'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed:
                    () => Navigator.pushNamed(
                      context,
                      AppRoutes.playerDetail,
                      arguments: player,
                    ),
                icon: const Icon(Icons.trending_up),
                label: const Text('MIS ESTADÍSTICAS'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ManagerPortalPage extends StatelessWidget {
  const ManagerPortalPage({super.key});

  Future<void> _signOut(BuildContext context) async {
    await Supabase.instance.client.auth.signOut();
    if (context.mounted) {
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GESTIÓN DE JUGADORES'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: () => _signOut(context),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.groups, size: 64),
            const SizedBox(height: 16),
            const Text('Acceso de encargado'),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed:
                  () => Navigator.pushNamed(context, AppRoutes.playersHub),
              icon: const Icon(Icons.dashboard_customize),
              label: const Text('ABRIR GESTIÓN'),
            ),
          ],
        ),
      ),
    );
  }
}
