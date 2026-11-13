import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/routes/app_routes.dart';
import '../../domain/entities/player_stats.dart';
import '../../presentation/providers/players_provider.dart';
import '../../presentation/widgets/player_card.dart';
import 'add_player_page.dart';
import 'business_managers_page.dart';

class PlayersListPage extends StatelessWidget {
  const PlayersListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(create: (_) => PlayersProvider(), child: const _Content());
  }
}

class _Content extends StatelessWidget {
  const _Content();

  @override
  Widget build(BuildContext context) {
    final provider = context.read<PlayersProvider>();
    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'JUGADORES',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        actions: [
          Consumer<PlayersProvider>(
            builder:
                (context, current, _) =>
                    current.isAdmin
                        ? IconButton(
                          tooltip: 'Gestionar encargados',
                          icon: const Icon(Icons.manage_accounts),
                          onPressed:
                              () => Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const BusinessManagersPage()),
                              ),
                        )
                        : const SizedBox.shrink(),
          ),
        ],
      ),
      body: Consumer<PlayersProvider>(
        builder: (context, state, _) {
          if (state.isLoading) {
            return Center(child: CircularProgressIndicator(color: primary));
          }
          if (state.players.isEmpty) {
            return _EmptyState(onAdd: () => _openForm(context, provider));
          }
          return RefreshIndicator(
            onRefresh: provider.refresh,
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: state.players.length,
              itemBuilder: (_, index) {
                final player = state.players[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    children: [
                      PlayerCard(
                        player: player,
                        showActions: false,
                        onTap:
                            () => Navigator.pushNamed(
                              context,
                              AppRoutes.playerDetail,
                              arguments: player,
                            ),
                      ),
                      _PlayerRegistrationActions(
                        player: player,
                        provider: provider,
                        onEdit: () => _openForm(context, provider, player: player),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: primary,
        icon: const Icon(Icons.person_add),
        label: const Text('AGREGAR'),
        onPressed: () => _openForm(context, provider),
      ),
    );
  }

  void _openForm(BuildContext context, PlayersProvider provider, {PlayerEntity? player}) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddPlayerPage(playersProvider: provider, player: player)),
    );
  }
}

class _PlayerRegistrationActions extends StatelessWidget {
  final PlayerEntity player;
  final PlayersProvider provider;
  final VoidCallback onEdit;

  const _PlayerRegistrationActions({
    required this.player,
    required this.provider,
    required this.onEdit,
  });

  String _statusLabel() {
    if (player.archivedAt != null) return 'ARCHIVADO';
    if (player.isExpired) return 'VENCIDO';
    return player.isActive ? 'ACTIVO' : 'INACTIVO';
  }

  Future<void> _archive(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Archivar jugador'),
            content: Text(
              'Se desactivará ${player.name}. Su ficha se conservará para mantener el historial.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('CANCELAR'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('ARCHIVAR'),
              ),
            ],
          ),
    );
    if (confirmed != true || !context.mounted) return;
    await _run(context, () => provider.archive(player));
  }

  Future<void> _resetPassword(BuildContext context) async {
    late String password;
    var succeeded = false;
    await _run(context, () async {
      password = await provider.resetPassword(player);
      succeeded = true;
    });
    if (!succeeded || !context.mounted) return;
    await _showPassword(context, player.email, password);
  }

  Future<void> _renew(BuildContext context) async {
    await _run(context, () async {
      await provider.renew(player);
    });
  }

  Future<void> _share(BuildContext context) async {
    final details = [
      'Jugador: ${player.name}',
      if (player.nickname.isNotEmpty) 'Nickname: ${player.nickname}',
      if (player.playerCode.isNotEmpty) 'Código: ${player.playerCode}',
      'Handicap: ${List.filled(player.level, '★').join()}',
      if (player.phone.isNotEmpty) 'Teléfono: ${player.phone}',
    ];
    try {
      await SharePlus.instance.share(
        ShareParams(text: details.join('\n'), subject: 'Ficha de jugador: ${player.displayName}'),
      );
    } catch (e, st) {
      debugPrint('[PlayersListPage] Could not share player: $e\n$st');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo abrir el menú para compartir.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (e, st) {
      debugPrint('[PlayersListPage] Player action failed: $e\n$st');
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _showPassword(BuildContext context, String email, String password) async {
    var copied = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('CONTRASEÑA PROVISIONAL'),
                  content: SelectableText(
                    'Correo: $email\nContraseña temporal: $password\n\n'
                    'El jugador deberá cambiarla al iniciar sesión.',
                  ),
                  actions: [
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: 'Correo: $email\nContraseña: $password'),
                        );
                        setDialogState(() => copied = true);
                      },
                      icon: Icon(copied ? Icons.check : Icons.copy),
                      label: Text(copied ? 'COPIADO' : 'COPIAR ACCESO'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('CERRAR'),
                    ),
                  ],
                ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final expiry = DateTime.tryParse(player.expiresAt);
    final active = player.enrollmentIsActive;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              '${_statusLabel()}'
              '${expiry == null ? '' : ' · Vence ${MaterialLocalizations.of(context).formatMediumDate(expiry)}'}'
              '${player.playerCode.isEmpty ? '' : ' · ${player.playerCode}'}',
              style: TextStyle(
                color: active ? Colors.greenAccent : Colors.orangeAccent,
                fontSize: 11,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Acciones del jugador',
            onSelected: (action) {
              switch (action) {
                case 'edit':
                  onEdit();
                case 'share':
                  _share(context);
                case 'reset':
                  _resetPassword(context);
                case 'renew':
                  _renew(context);
                case 'archive':
                  _archive(context);
              }
            },
            itemBuilder:
                (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Editar ficha')),
                  const PopupMenuItem(value: 'share', child: Text('Compartir ficha')),
                  if (player.authUserId != null && player.isActive)
                    const PopupMenuItem(value: 'reset', child: Text('Restablecer contraseña')),
                  PopupMenuItem(
                    value: 'renew',
                    child: Text(
                      player.isActive && !player.isExpired
                          ? 'Renovar vigencia'
                          : 'Reactivar y renovar',
                    ),
                  ),
                  if (player.isActive && player.archivedAt == null)
                    const PopupMenuItem(value: 'archive', child: Text('Archivar jugador')),
                ],
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.group_outlined, size: 64, color: Colors.white.withValues(alpha: 0.06)),
          const SizedBox(height: 16),
          Text(
            'No hay jugadores registrados',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 15),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.person_add),
            label: const Text('AGREGAR PRIMER JUGADOR'),
          ),
        ],
      ),
    );
  }
}
