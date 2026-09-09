import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../storage/preferences_service.dart';

/// Diálogo de autorización con PIN para operaciones críticas (Etapa 3).
///
/// Uso:
/// ```dart
/// final ok = await AdminPinDialog.authorize(context, accion: 'ANULAR VENTA');
/// if (ok) { ... }
/// ```
///
/// Reglas:
/// - Si no hay PIN configurado (`adminPin` vacío), la acción queda
///   DESHABILITADA y se pide configurarlo primero en Configuración.
class AdminPinDialog {
  static Future<bool> authorize(BuildContext context, {required String accion}) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const _AdminPinDialog(),
    );
    return result == true;
  }
}

class _AdminPinDialog extends StatefulWidget {
  const _AdminPinDialog();

  @override
  State<_AdminPinDialog> createState() => _AdminPinDialogState();
}

class _AdminPinDialogState extends State<_AdminPinDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final prefs = PreferencesService();
    final saved = prefs.adminPin;
    if (saved.isEmpty) {
      setState(() => _error = 'No hay PIN configurado. Configúralo en Configuración.');
      return;
    }
    if (_ctrl.text == saved) {
      if (mounted) Navigator.pop(context, true);
    } else {
      setState(() {
        _error = 'PIN incorrecto';
        _ctrl.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      title: const Text('AUTORIZACIÓN REQUERIDA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Ingresa el PIN de autorización para continuar.', style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
            style: const TextStyle(color: Colors.white, letterSpacing: 8, fontSize: 20),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              labelText: 'PIN',
              labelStyle: const TextStyle(color: Colors.white38),
              errorText: _error,
              errorStyle: const TextStyle(color: Colors.redAccent),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar', style: TextStyle(color: Colors.white38)),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('AUTORIZAR', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
