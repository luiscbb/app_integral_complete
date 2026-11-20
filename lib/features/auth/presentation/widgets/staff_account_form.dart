import 'package:flutter/material.dart';

import '../../data/staff_role_template_repository.dart';
import '../../domain/staff_access.dart';

class StaffAccountForm extends StatefulWidget {
  const StaffAccountForm({super.key, this.initial, this.roleTemplates});

  final StaffAccountDraft? initial;
  final StaffRoleTemplateStore? roleTemplates;

  @override
  State<StaffAccountForm> createState() => _StaffAccountFormState();
}

class _StaffAccountFormState extends State<StaffAccountForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _username;
  late final TextEditingController _jobTitle;
  final _modules = <StaffModule>{};
  bool _showModulesError = false;
  StaffRoleRecommendation? _recommendation;
  List<StaffRoleTemplate>? _savedRoles;
  String? _roleError;
  bool _roleWorking = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.fullName);
    _username = TextEditingController(text: widget.initial?.username);
    _jobTitle = TextEditingController(text: widget.initial?.jobTitle);
    _modules.addAll(widget.initial?.modules ?? {});
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _jobTitle.dispose();
    super.dispose();
  }

  void _submit() {
    final validForm = _formKey.currentState!.validate();
    setState(() => _showModulesError = _modules.isEmpty);
    if (!validForm || _modules.isEmpty) return;

    Navigator.pop(
      context,
      StaffAccountDraft(
        fullName: _name.text.trim(),
        username: normalizeStaffUsername(_username.text),
        jobTitle: _jobTitle.text.trim(),
        modules: _modules,
      ),
    );
  }

  void _selectModule(StaffModule module, bool? selected) {
    setState(() {
      if (module.isOperationalPermission) {
        final parent = module.parent!;
        if (selected == true) {
          _modules
            ..add(parent)
            ..add(module);
        } else {
          _modules.remove(module);
          if (!StaffModule.values.any(
            (permission) =>
                permission.isOperationalPermission &&
                permission.parent == parent &&
                _modules.contains(permission),
          )) {
            _modules.remove(parent);
          }
        }
        _showModulesError = false;
        return;
      }
      final permissions = module.sectionPermissions.values;
      final targets = permissions.isEmpty ? [module] : permissions;
      if (permissions.isNotEmpty) _modules.remove(module);
      if (selected == true) {
        _modules.addAll(targets);
        if (module == StaffModule.billiardTables ||
            module == StaffModule.dineIn) {
          _modules.add(module);
        }
      } else {
        _modules.removeAll(targets);
      }
      _showModulesError = false;
    });
  }

  Future<void> _applyRecommendation() async {
    final recommendation = _recommendation;
    if (recommendation == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('APLICAR ${recommendation.title.toUpperCase()}'),
            content: Text(
              '${recommendation.description}\n\n'
              'Se reemplazarán el puesto y los módulos seleccionados en este '
              'formulario. Después puedes ajustarlos manualmente. '
              'Los permisos no disponibles no se activarán.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('CANCELAR'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('APLICAR'),
              ),
            ],
          ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      _jobTitle.text = recommendation.title;
      _modules
        ..clear()
        ..addAll(recommendation.modules);
      _showModulesError = false;
    });
  }

  Future<bool> _confirmRoleAction(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text(title),
              content: Text(message),
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
      ) ==
      true;

  Future<void> _loadRoles() async {
    final store = widget.roleTemplates;
    if (store == null || _roleWorking) return;
    setState(() {
      _roleWorking = true;
      _roleError = null;
    });
    try {
      final roles = await store.list();
      if (mounted) setState(() => _savedRoles = roles);
    } catch (error) {
      if (mounted) {
        setState(() => _roleError = 'No se pudieron cargar los roles: $error');
      }
    } finally {
      if (mounted) setState(() => _roleWorking = false);
    }
  }

  Future<void> _saveRole({StaffRoleTemplate? existing}) async {
    final store = widget.roleTemplates;
    if (store == null || _roleWorking) return;
    final name = _jobTitle.text.trim();
    final modules = Set<StaffModule>.of(_modules);
    if (name.isEmpty ||
        name.length > 80 ||
        !modules.every(StaffModule.pilotModules.contains)) {
      setState(
        () =>
            _roleError =
                'Escribe un puesto y selecciona solo módulos disponibles para guardar el rol.',
      );
      return;
    }
    if (existing != null &&
        !await _confirmRoleAction(
          'ACTUALIZAR ROL',
          'Se guardarán el puesto y los módulos actuales en la plantilla '
              '${existing.name}. Las cuentas existentes no cambiarán.',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _roleWorking = true;
      _roleError = null;
    });
    try {
      await store.save(existing: existing, name: name, modules: modules);
      if (!mounted) return;
      setState(() => _savedRoles = null);
      final roles = await store.list();
      if (mounted) setState(() => _savedRoles = roles);
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _roleError =
                  'No se pudo confirmar el rol o actualizar la lista: $error. '
                  'Vuelve a cargar los roles antes de reintentar.',
        );
      }
    } finally {
      if (mounted) setState(() => _roleWorking = false);
    }
  }

  Future<void> _deleteRole(StaffRoleTemplate role) async {
    final store = widget.roleTemplates;
    if (store == null ||
        _roleWorking ||
        !await _confirmRoleAction(
          'ELIMINAR ROL',
          'Se eliminará la plantilla ${role.name}; las cuentas existentes '
              'no cambiarán.',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _roleWorking = true;
      _roleError = null;
    });
    try {
      await store.delete(role);
      if (!mounted) return;
      setState(() => _savedRoles = null);
      final roles = await store.list();
      if (mounted) setState(() => _savedRoles = roles);
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _roleError =
                  'No se pudo confirmar la eliminación o actualizar la lista: $error. '
                  'Vuelve a cargar los roles antes de reintentar.',
        );
      }
    } finally {
      if (mounted) setState(() => _roleWorking = false);
    }
  }

  Future<void> _applySavedRole(StaffRoleTemplate role) async {
    final store = widget.roleTemplates;
    if (store == null || _roleWorking) return;
    setState(() {
      _roleWorking = true;
      _roleError = null;
    });
    try {
      final roles = await store.list();
      if (!mounted) return;
      setState(() => _savedRoles = roles);
      if (!roles.any(
        (current) => current.id == role.id && current.revision == role.revision,
      )) {
        setState(
          () =>
              _roleError =
                  'La plantilla cambió o ya no existe. Selecciónala nuevamente.',
        );
        return;
      }
    } catch (error) {
      if (mounted) {
        setState(() => _roleError = 'No se pudo verificar el rol: $error');
      }
      return;
    } finally {
      if (mounted) setState(() => _roleWorking = false);
    }
    if (!mounted) return;
    if (!await _confirmRoleAction(
          'APLICAR ROL',
          'Se reemplazarán el puesto y los módulos del formulario por los de '
              '${role.name}. Puedes ajustarlos después.',
        ) ||
        !mounted) {
      return;
    }
    setState(() {
      _jobTitle.text = role.name;
      _modules
        ..clear()
        ..addAll(role.modules);
      _showModulesError = false;
    });
  }

  Widget _buildModule(StaffModule module) {
    final available = module.canAssignWhole;
    final partial = module.sectionPermissions.values.any(_modules.contains);
    final complete =
        module.sectionPermissions.isNotEmpty &&
        module.sectionPermissions.values.every(_modules.contains);
    return ExpansionTile(
      key: ValueKey('staff_module_${module.id}'),
      tilePadding: EdgeInsets.zero,
      leading: Checkbox(
        key: ValueKey('staff_module_checkbox_${module.id}'),
        tristate: true,
        value:
            _modules.contains(module) || complete
                ? true
                : partial
                ? null
                : false,
        semanticLabel: 'Asignar ${module.label}',
        onChanged:
            available
                ? (_) => _selectModule(
                  module,
                  !(_modules.contains(module) || complete),
                )
                : null,
      ),
      title: Text(module.label),
      subtitle: Text(
        available
            ? 'Módulo completo disponible'
            : module.sectionPermissions.isNotEmpty
            ? 'Solo subcategorías habilitadas'
            : 'Pendiente de integración',
      ),
      children: [
        for (final section in module.sections)
          if (module.sectionPermissions[section] case final permission?)
            CheckboxListTile(
              key: ValueKey('staff_permission_${permission.id}'),
              title: Text(section),
              value: _modules.contains(permission),
              onChanged:
                  permission.canAssignWhole || _modules.contains(permission)
                      ? (selected) => _selectModule(permission, selected)
                      : null,
              subtitle: Text(
                permission.isOperationalPermission
                    ? permission.canAssignWhole
                        ? 'Permiso independiente; no concede otras acciones.'
                        : 'Pendiente de integración del servicio.'
                    : 'Solo consulta · permiso independiente',
              ),
            )
          else
            ListTile(
              dense: true,
              leading: Icon(
                available ? Icons.layers_outlined : Icons.lock_outline,
              ),
              title: Text(section),
              subtitle: Text(
                available
                    ? 'Incluido al asignar el módulo completo'
                    : 'Pendiente de autorización para personal',
              ),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_roleWorking,
      child: AlertDialog(
        title: Text(
          widget.initial == null ? 'AGREGAR USUARIO' : 'EDITAR USUARIO',
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: _name,
                    maxLength: 120,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Nombre completo',
                    ),
                    validator:
                        (value) =>
                            value == null || value.trim().isEmpty
                                ? 'Ingresa el nombre completo.'
                                : null,
                  ),
                  TextFormField(
                    controller: _username,
                    maxLength: 32,
                    autocorrect: false,
                    readOnly: widget.initial != null,
                    decoration: const InputDecoration(labelText: 'Usuario'),
                    validator:
                        (value) =>
                            isValidStaffUsername(value ?? '')
                                ? null
                                : 'Usa 3 a 32 letras sin acentos, números, puntos, '
                                    'guiones o guiones bajos; inicia con letra o número.',
                  ),
                  DropdownButtonFormField<StaffRoleRecommendation>(
                    key: const ValueKey('staff_role_recommendation'),
                    initialValue: _recommendation,
                    decoration: const InputDecoration(
                      labelText: 'Recomendación de rol',
                    ),
                    items: [
                      for (final role in StaffRoleRecommendation.values)
                        DropdownMenuItem(value: role, child: Text(role.title)),
                    ],
                    onChanged: (role) => setState(() => _recommendation = role),
                  ),
                  const Text(
                    'Las recomendaciones son iniciales y no modifican otras '
                    'cuentas.',
                  ),
                  if (_recommendation != null) ...[
                    Text(_recommendation!.description),
                    TextButton(
                      onPressed: _applyRecommendation,
                      child: const Text('APLICAR RECOMENDACIÓN'),
                    ),
                  ],
                  TextFormField(
                    controller: _jobTitle,
                    maxLength: 80,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Puesto o rol',
                    ),
                    validator:
                        (value) =>
                            value == null || value.trim().isEmpty
                                ? 'Ingresa el puesto o rol.'
                                : null,
                  ),
                  if (widget.roleTemplates != null) ...[
                    const SizedBox(height: 12),
                    const Text('ROLES GUARDADOS'),
                    const Text(
                      'Guarda el puesto y los módulos seleccionados como plantilla. '
                      'Editar o eliminar una plantilla no modifica cuentas existentes.',
                    ),
                    TextButton(
                      onPressed: _roleWorking ? null : _loadRoles,
                      child: const Text('CARGAR ROLES GUARDADOS'),
                    ),
                    if (_savedRoles != null) ...[
                      if (_savedRoles!.isEmpty)
                        const Text('No hay roles guardados.'),
                      for (final role in _savedRoles!)
                        ListTile(
                          title: Text(role.name),
                          subtitle: Text('${role.modules.length} módulos'),
                          trailing: PopupMenuButton<String>(
                            enabled: !_roleWorking,
                            onSelected: (action) {
                              if (action == 'apply') _applySavedRole(role);
                              if (action == 'update') _saveRole(existing: role);
                              if (action == 'delete') _deleteRole(role);
                            },
                            itemBuilder:
                                (_) => const [
                                  PopupMenuItem(
                                    value: 'apply',
                                    child: Text('Aplicar al formulario'),
                                  ),
                                  PopupMenuItem(
                                    value: 'update',
                                    child: Text('Actualizar con el formulario'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Eliminar plantilla'),
                                  ),
                                ],
                          ),
                        ),
                      TextButton(
                        onPressed: _roleWorking ? null : _saveRole,
                        child: const Text('GUARDAR COMO ROL NUEVO'),
                      ),
                    ],
                    if (_roleWorking) const CircularProgressIndicator(),
                    if (_roleError != null)
                      Text(
                        _roleError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                  const Text('MÓDULOS PERMITIDOS'),
                  const Text(
                    'Marca la casilla para asignar el módulo completo. '
                    'Despliega su nombre para ver las subcategorías. '
                    'Las subcategorías con casilla se asignan por separado; '
                    'los módulos sin integración no se pueden activar. '
                    'Puedes escribir otro puesto y ajustar sus módulos.',
                  ),
                  for (final module in StaffModule.values)
                    if (module.parent == null) _buildModule(module),
                  if (_showModulesError)
                    Text(
                      'Selecciona al menos un módulo.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  const SizedBox(height: 8),
                  if (widget.initial == null)
                    const Text(
                      'Se generará una contraseña temporal para el primer inicio de sesión.',
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _roleWorking ? null : () => Navigator.pop(context),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: _roleWorking ? null : _submit,
            child: const Text('CONTINUAR'),
          ),
        ],
      ),
    );
  }
}
