import 'package:flutter/material.dart';

class StockConflictDialog extends StatefulWidget {
  const StockConflictDialog({
    super.key,
    required this.productName,
    required this.localStock,
    required this.remoteStock,
  });

  final String productName;
  final double localStock;
  final double remoteStock;

  @override
  State<StockConflictDialog> createState() => _StockConflictDialogState();
}

class _StockConflictDialogState extends State<StockConflictDialog> {
  final _formKey = GlobalKey<FormState>();
  String _stockInput = '';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Revisar ${widget.productName}'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Existencia en este dispositivo: ${widget.localStock}'),
              Text('Existencia en el servidor: ${widget.remoteStock}'),
              const SizedBox(height: 12),
              const Text(
                'Revisa las ventas, compras y el inventario físico antes de indicar la existencia final.',
              ),
              const Text(
                'Las cantidades pueden coincidir aunque existan operaciones pendientes.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                onChanged: (value) => _stockInput = value,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Existencia final',
                ),
                validator: (value) {
                  final parsed = double.tryParse(
                    (value ?? '').trim().replaceAll(',', '.'),
                  );
                  return parsed == null || !parsed.isFinite
                      ? 'Ingresa una cantidad válida'
                      : null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.pop(
                context,
                double.parse(_stockInput.trim().replaceAll(',', '.')),
              );
            }
          },
          child: const Text('Guardar existencia'),
        ),
      ],
    );
  }
}
