import 'package:flutter/material.dart';

import '../../domain/entities/provider_entity.dart';
import '../../domain/entities/purchase_entity.dart';
import '../../domain/entities/purchase_payment_terms.dart';

class PurchasePaymentDialog extends StatefulWidget {
  const PurchasePaymentDialog({
    super.key,
    required this.provider,
    required this.total,
  });

  final ProviderEntity? provider;
  final double total;

  @override
  State<PurchasePaymentDialog> createState() => _PurchasePaymentDialogState();
}

class _PurchasePaymentDialogState extends State<PurchasePaymentDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _days;
  late String _option;
  String _cashSource = CashSource.caja;
  String? _error;

  @override
  void initState() {
    super.initState();
    _option =
        widget.provider?.preferredPaymentMethod ?? PurchasePaymentOption.cash;
    _days = TextEditingController(
      text: widget.provider?.creditDays?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _days.dispose();
    super.dispose();
  }

  void _confirm() {
    if (!_form.currentState!.validate()) return;
    if (_option == PurchasePaymentOption.credit &&
        widget.provider?.id == null) {
      setState(
        () => _error = 'Selecciona un proveedor para comprar a crédito.',
      );
      return;
    }
    final payment = PurchasePaymentTerms(
      option: _option,
      cashSource: _option == PurchasePaymentOption.cash ? _cashSource : null,
      creditDays:
          _option == PurchasePaymentOption.credit
              ? int.parse(_days.text.trim())
              : null,
    );
    try {
      payment.snapshot(total: widget.total, recordedAt: DateTime.now().toUtc());
    } on ArgumentError catch (error) {
      setState(() => _error = error.message.toString());
      return;
    }
    Navigator.of(context).pop(payment);
  }

  @override
  Widget build(BuildContext context) {
    final credit = _option == PurchasePaymentOption.credit;
    return AlertDialog(
      title: const Text('CONFIRMAR COMPRA'),
      content: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.provider?.name ?? 'Sin proveedor'),
              Text(
                'Total: \$${widget.total.toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _option,
                decoration: const InputDecoration(labelText: 'Forma de pago'),
                items:
                    PurchasePaymentOption.values
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(PurchasePaymentOption.label(value)),
                          ),
                        )
                        .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _option = value;
                    _error = null;
                  });
                },
              ),
              if (_option == PurchasePaymentOption.cash) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _cashSource,
                  decoration: const InputDecoration(
                    labelText: 'Origen del efectivo',
                  ),
                  items:
                      [CashSource.caja, CashSource.cajero]
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(CashSource.label(value)),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _cashSource = value);
                  },
                ),
              ],
              if (credit) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _days,
                  decoration: const InputDecoration(
                    labelText: 'Días de crédito',
                    helperText:
                        '0: vence el mismo día. No se admiten anticipos.',
                  ),
                  keyboardType: TextInputType.number,
                  validator: (value) {
                    final days = int.tryParse(value?.trim() ?? '');
                    if (days == null || days < 0 || days > 2147483647) {
                      return 'Ingresa días enteros no negativos.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  'Pagado: \$0.00 · Saldo: \$${widget.total.toStringAsFixed(2)}',
                ),
                const Text('No se descontará dinero de caja.'),
              ] else if (_option != PurchasePaymentOption.cash) ...[
                const SizedBox(height: 12),
                const Text('Este pago no afecta el efectivo del cajón.'),
              ],
              const SizedBox(height: 16),
              const Text(
                'Estos cambios son solo para esta compra; no modifican las preferencias del proveedor.',
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
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
          onPressed: _confirm,
          child: const Text('CONFIRMAR Y REGISTRAR'),
        ),
      ],
    );
  }
}
