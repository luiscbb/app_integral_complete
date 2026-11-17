import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/storage/preferences_service.dart';
import '../../data/staff_account_creation_repository.dart';
import '../../data/staff_account_request_store.dart';
import '../../domain/staff_access.dart';
import 'staff_account_form.dart';

class StaffManagementSection extends StatefulWidget {
  const StaffManagementSection({
    super.key,
    required this.enabled,
    this.repository,
  });

  final bool enabled;
  final StaffAccountCreationRepository? repository;

  @override
  State<StaffManagementSection> createState() => _StaffManagementSectionState();
}

class _StaffManagementSectionState extends State<StaffManagementSection> {
  late final StaffAccountCreationRepository _repository;
  StreamSubscription<AuthState>? _authSubscription;
  List<StaffAccount> _accounts = [];
  List<PendingStaffAccountRequest> _pending = [];
  Object? _error;
  bool _loading = false;
  bool _working = false;
  int _generation = 0;
  bool Function()? _viewSession;

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) return;
    _repository =
        widget.repository ??
        StaffAccountCreationRepository(
          client: Supabase.instance.client,
          requests: StaffAccountRequestStore(),
          currentBillarId: () => PreferencesService().billarId,
        );
    _authSubscription = _repository.authChanges.listen(
      (_) {
        if (!mounted || _viewSession == null || _viewSession!()) return;
        _invalidateSession();
      },
      onError: (Object error, StackTrace stack) {
        debugPrint(
          '[StaffAccountManagement] Error de sesión: ${error.runtimeType}',
        );
        if (mounted) _invalidateSession();
      },
    );
    _refresh();
  }

  void _invalidateSession() {
    _generation++;
    setState(() {
      _viewSession = null;
      _accounts = [];
      _pending = [];
      _loading = false;
      _error = StateError('La sesión cambió. Vuelve a cargar el personal.');
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _viewSession = _repository.guardCurrentSession();
      final accounts = await _repository.listStaff();
      final pending = await _repository.pending();
      if (!mounted || generation != _generation) return;
      setState(() {
        _accounts = accounts;
        _pending = pending;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _accounts = [];
        _pending = [];
        _error = error;
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  String _message(Object error) {
    final text = error.toString();
    return text.startsWith('Bad state: ') ? text.substring(11) : text;
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_message(error)), backgroundColor: Colors.red),
    );
  }

  Future<void> _perform(
    bool Function() sessionUnchanged,
    Future<void> Function() operation,
  ) async {
    if (_working) return;
    if (!sessionUnchanged()) {
      _showError(
        StateError('La sesión cambió. Vuelve a iniciar la operación.'),
      );
      return;
    }
    setState(() => _working = true);
    try {
      await operation();
      if (mounted && sessionUnchanged()) await _refresh();
    } catch (error) {
      _showError(error);
      if (mounted && sessionUnchanged()) await _refresh();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _showResult(StaffAccountCreationResult result) async {
    if (!_repository.isResultSessionCurrent(result)) {
      throw StateError(
        'La sesión cambió. Recupera la solicitud desde la cuenta original.',
      );
    }
    final acknowledged = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder:
          (_) =>
              _StaffCredentialsDialog(result: result, repository: _repository),
    );
    if (acknowledged == true) await _repository.acknowledge(result);
  }

  Future<void> _add() async {
    try {
      final sessionUnchanged = _repository.guardCurrentSession();
      final draft = await showDialog<StaffAccountDraft>(
        context: context,
        builder: (_) => const StaffAccountForm(),
      );
      if (draft == null || !mounted) return;
      await _perform(sessionUnchanged, () async {
        final result = await _repository.create(draft);
        if (mounted) await _showResult(result);
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _retry(PendingStaffAccountRequest request) async {
    try {
      final guard = _repository.guardCurrentSession();
      await _perform(guard, () async {
        final result = await _repository.retry(request.requestId);
        if (mounted) await _showResult(result);
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _edit(StaffAccount account) async {
    try {
      final guard = _repository.guardCurrentSession();
      final draft = await showDialog<StaffAccountDraft>(
        context: context,
        builder: (_) => StaffAccountForm(initial: account.draft),
      );
      if (draft == null || !mounted) return;
      await _perform(guard, () async {
        await _repository.updateStaff(
          account: account,
          draft: draft,
          isActive: account.isActive,
        );
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _setActive(StaffAccount account) async {
    try {
      final guard = _repository.guardCurrentSession();
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text(
                account.isActive ? 'DESACTIVAR USUARIO' : 'ACTIVAR USUARIO',
              ),
              content: Text(
                account.isActive
                    ? 'Se retirará el acceso de ${account.draft.username}.'
                    : 'Se restablecerá el acceso de ${account.draft.username}.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('CANCELAR'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('CONFIRMAR'),
                ),
              ],
            ),
      );
      if (confirmed != true || !mounted) return;
      await _perform(guard, () async {
        await _repository.updateStaff(
          account: account,
          draft: account.draft,
          isActive: !account.isActive,
        );
      });
    } catch (error) {
      _showError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PERSONAL',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 16),
          Text('La gestión de personal aún no está habilitada.'),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'PERSONAL',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _loading || _working || _error != null ? null : _add,
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text('AGREGAR USUARIO'),
        ),
        const SizedBox(height: 16),
        if (_loading)
          const CircularProgressIndicator()
        else if (_error != null) ...[
          Text('No se pudo cargar el personal: ${_message(_error!)}'),
          TextButton(
            onPressed: _working ? null : _refresh,
            child: const Text('REINTENTAR'),
          ),
        ] else ...[
          if (_pending.isNotEmpty) const Text('SOLICITUDES PENDIENTES'),
          for (final request in _pending)
            ListTile(
              title: Text(request.draft.username),
              subtitle: const Text('La creación debe confirmarse.'),
              trailing: TextButton(
                onPressed: _working ? null : () => _retry(request),
                child: const Text('RECUPERAR'),
              ),
            ),
          if (_accounts.isEmpty)
            const Text('No hay usuarios de personal registrados.'),
          for (final account in _accounts)
            Card(
              child: ListTile(
                title: Text(account.draft.fullName),
                subtitle: Text(
                  '${account.draft.username} · ${account.draft.jobTitle}\n'
                  '${account.isActive ? 'Activo' : 'Desactivado'}',
                ),
                isThreeLine: true,
                trailing: PopupMenuButton<String>(
                  enabled: !_working,
                  onSelected: (action) {
                    if (action == 'edit') _edit(account);
                    if (action == 'active') _setActive(account);
                  },
                  itemBuilder:
                      (_) => [
                        const PopupMenuItem(
                          value: 'edit',
                          child: Text('Editar'),
                        ),
                        PopupMenuItem(
                          value: 'active',
                          child: Text(
                            account.isActive ? 'Desactivar' : 'Activar',
                          ),
                        ),
                      ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _StaffCredentialsDialog extends StatefulWidget {
  const _StaffCredentialsDialog({
    required this.result,
    required this.repository,
  });

  final StaffAccountCreationResult result;
  final StaffAccountCreationRepository repository;

  @override
  State<_StaffCredentialsDialog> createState() =>
      _StaffCredentialsDialogState();
}

class _StaffCredentialsDialogState extends State<_StaffCredentialsDialog> {
  bool _invalidated = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: widget.repository.authChanges,
      builder: (context, snapshot) {
        if (snapshot.hasError ||
            !widget.repository.isResultSessionCurrent(widget.result)) {
          _invalidated = true;
        }
        final valid = !_invalidated;
        final password = widget.result.temporaryPassword;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('ACCESO DE PERSONAL'),
            content: SelectableText(
              !valid
                  ? 'La sesión cambió. Recupera la solicitud desde la cuenta original.'
                  : password == null
                  ? 'La contraseña temporal ya no está disponible y no se puede volver a mostrar.'
                  : 'Usuario: ${widget.result.username}\nContraseña temporal: $password\n\n'
                      'Entrégala al usuario. Debe cambiarla al iniciar sesión.',
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context, valid),
                child: Text(
                  !valid
                      ? 'CERRAR'
                      : password == null
                      ? 'ENTENDIDO'
                      : 'GUARDÉ EL ACCESO',
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
