import 'package:flutter/material.dart';

import '../../domain/staff_access.dart';

class StaffAccountForm extends StatefulWidget {
  const StaffAccountForm({super.key, this.initial});

  final StaffAccountDraft? initial;

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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
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
                TextFormField(
                  controller: _jobTitle,
                  maxLength: 80,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Puesto o rol'),
                  validator:
                      (value) =>
                          value == null || value.trim().isEmpty
                              ? 'Ingresa el puesto o rol.'
                              : null,
                ),
                const SizedBox(height: 16),
                const Text('MÓDULOS PERMITIDOS'),
                for (final module in StaffModule.pilotModules)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(module.label),
                    value: _modules.contains(module),
                    onChanged: (selected) {
                      setState(() {
                        if (selected == true) {
                          _modules.add(module);
                        } else {
                          _modules.remove(module);
                        }
                        _showModulesError = false;
                      });
                    },
                  ),
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
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCELAR'),
        ),
        ElevatedButton(onPressed: _submit, child: const Text('CONTINUAR')),
      ],
    );
  }
}
