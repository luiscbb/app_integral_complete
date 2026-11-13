import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/repositories/player_repository.dart';

class BusinessManagersPage extends StatefulWidget {
  const BusinessManagersPage({super.key});

  @override
  State<BusinessManagersPage> createState() => _BusinessManagersPageState();
}

class _BusinessManagersPageState extends State<BusinessManagersPage> {
  final _repository = PlayerRepository();
  late Future<List<Map<String, dynamic>>> _managers;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _managers = _repository.getManagers();
  }

  void _reload() => setState(() => _managers = _repository.getManagers());

  Future<void> _addManager() async {
    final form = await showDialog<({String name, String email})>(
      context: context,
      builder: (context) => const _ManagerFormDialog(),
    );
    if (form == null) return;
    setState(() => _busy = true);
    try {
      final result = await _repository.createManager(
        name: form.name,
        email: form.email,
      );
      if (!mounted) return;
      await _showTemporaryPassword(form.email, result.temporaryPassword);
      _reload();
    } catch (e, st) {
      debugPrint('[BusinessManagersPage] Create manager failed: $e\n$st');
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetPassword(Map<String, dynamic> manager) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restablecer contraseña'),
        content: Text(
          'Se invalidará la contraseña actual de ${manager['email']}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('RESTABLECER'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final password = await _repository.resetManagerPassword(
        manager['user_id'].toString(),
      );
      if (!mounted) return;
      await _showTemporaryPassword(manager['email']?.toString() ?? '', password);
      _reload();
    } catch (e, st) {
      debugPrint('[BusinessManagersPage] Reset password failed: $e\n$st');
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setActive(Map<String, dynamic> manager, bool active) async {
    setState(() => _busy = true);
    try {
      await _repository.setManagerActive(manager['user_id'].toString(), active);
      _reload();
    } catch (e, st) {
      debugPrint('[BusinessManagersPage] Update manager failed: $e\n$st');
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showTemporaryPassword(String email, String password) async {
    var copied = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('ACCESO PROVISIONAL'),
          content: SelectableText(
            'Correo: $email\nContraseña temporal: $password\n\n'
            'Entrégala al encargado. Deberá cambiarla en su primer inicio.',
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

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString()), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ENCARGADOS')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addManager,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('AGREGAR ENCARGADO'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _managers,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('No se pudieron cargar los encargados: ${snapshot.error}'),
                  TextButton(
                    onPressed: _reload,
                    child: const Text('REINTENTAR'),
                  ),
                ],
              ),
            );
          }
          final managers = snapshot.data ?? const [];
          if (managers.isEmpty) {
            return const Center(child: Text('No hay encargados registrados.'));
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            itemCount: managers.length,
            itemBuilder: (context, index) {
              final manager = managers[index];
              final active = manager['is_active'] == true;
              return Card(
                child: ListTile(
                  leading: Icon(
                    active ? Icons.badge_outlined : Icons.person_off_outlined,
                  ),
                  title: Text(manager['email']?.toString() ?? ''),
                  subtitle: Text(active ? 'Encargado activo' : 'Desactivado'),
                  trailing: PopupMenuButton<String>(
                    enabled: !_busy,
                    onSelected: (action) {
                      switch (action) {
                        case 'password':
                          _resetPassword(manager);
                        case 'toggle':
                          _setActive(manager, !active);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'password',
                        child: Text('Restablecer contraseña'),
                      ),
                      PopupMenuItem(
                        value: 'toggle',
                        child: Text(active ? 'Desactivar' : 'Activar'),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ManagerFormDialog extends StatefulWidget {
  const _ManagerFormDialog();

  @override
  State<_ManagerFormDialog> createState() => _ManagerFormDialogState();
}

class _ManagerFormDialogState extends State<_ManagerFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Agregar encargado'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (_, value) => value.copyWith(text: value.text.toUpperCase()),
                ),
              ],
              decoration: const InputDecoration(labelText: 'Nombre'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Ingresa el nombre'
                  : null,
            ),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Correo'),
              validator: (value) =>
                  RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value?.trim() ?? '')
                  ? null
                  : 'Ingresa un correo válido',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCELAR'),
        ),
        ElevatedButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(
              context,
              (name: _name.text.trim().toUpperCase(), email: _email.text.trim().toLowerCase()),
            );
          },
          child: const Text('CREAR'),
        ),
      ],
    );
  }
}
