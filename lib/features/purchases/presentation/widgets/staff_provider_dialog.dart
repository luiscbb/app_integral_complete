import 'package:flutter/material.dart';

import '../../domain/entities/provider_entity.dart';
import '../../domain/entities/purchase_entity.dart';
import '../../domain/entities/staff_provider_operation.dart';
import '../../domain/entities/staff_purchase_data.dart';

class StaffProviderDialog extends StatefulWidget {
  const StaffProviderDialog({
    super.key,
    required this.provider,
    required this.productIds,
    required this.products,
  });

  final ProviderEntity? provider;
  final List<int> productIds;
  final List<StaffPurchaseProduct> products;

  @override
  State<StaffProviderDialog> createState() => _StaffProviderDialogState();
}

class _StaffProviderDialogState extends State<StaffProviderDialog> {
  final _form = GlobalKey<FormState>();
  static const _labels = {
    'name': 'Nombre',
    'phone': 'Teléfono',
    'email': 'Correo',
    'address': 'Dirección',
    'contact_name': 'Nombre de contacto',
    'notes': 'Notas',
    'category': 'Categoría',
  };
  static const _days = [
    'Lunes',
    'Martes',
    'Miércoles',
    'Jueves',
    'Viernes',
    'Sábado',
    'Domingo',
  ];
  late final _fields = {
    for (final field in _labels.keys)
      field: TextEditingController(
        text:
            widget.provider?.toMap()[field] as String? ??
            (field == 'category' ? 'General' : ''),
      ),
  };
  late final _creditDays = TextEditingController(
    text: widget.provider?.creditDays?.toString() ?? '',
  );
  late final _selected = widget.productIds.toSet();
  late final _visitDays = {...?widget.provider?.visitDays};
  late String? _payment = widget.provider?.preferredPaymentMethod;

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    _creditDays.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final provider = ProviderEntity.fromMap({
      'id': widget.provider?.id,
      for (final field in _fields.entries) field.key: field.value.text.trim(),
      'visit_days': _visitDays.join(','),
      'credit_days': int.tryParse(_creditDays.text.trim()),
      'preferred_payment_method': _payment,
    });
    Navigator.pop(
      context,
      StaffProviderDraft.save(
        provider: provider,
        productIds: _selected.toList()..sort(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final products = {
      for (final product in widget.products) product.id: product,
    };
    final available = {
      for (final product in widget.products)
        if (product.parentId == null) product.id,
      ...widget.productIds,
    };
    return AlertDialog(
      title: Text(
        widget.provider == null ? 'NUEVO PROVEEDOR' : 'EDITAR PROVEEDOR',
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final field in _labels.entries)
                  TextFormField(
                    controller: _fields[field.key],
                    decoration: InputDecoration(labelText: field.value),
                    keyboardType:
                        field.key == 'phone'
                            ? TextInputType.phone
                            : field.key == 'email'
                            ? TextInputType.emailAddress
                            : TextInputType.text,
                    validator:
                        field.key == 'name'
                            ? (value) =>
                                value == null || value.trim().isEmpty
                                    ? 'El nombre es obligatorio.'
                                    : null
                            : null,
                  ),
                TextFormField(
                  controller: _creditDays,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Días de crédito',
                    helperText: 'Vacío: sin definir. 0: vence el mismo día.',
                  ),
                  validator: (value) {
                    final text = value?.trim() ?? '';
                    final days = int.tryParse(text);
                    return text.isNotEmpty &&
                            (days == null || days < 0 || days > 2147483647)
                        ? 'Ingresa días enteros entre 0 y 2147483647.'
                        : null;
                  },
                ),
                DropdownButtonFormField<String>(
                  initialValue: _payment,
                  decoration: const InputDecoration(
                    labelText: 'Pago preferido del proveedor',
                  ),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('Sin definir'),
                    ),
                    for (final option in PurchasePaymentOption.values)
                      DropdownMenuItem(
                        value: option,
                        child: Text(PurchasePaymentOption.label(option)),
                      ),
                  ],
                  onChanged: (value) => setState(() => _payment = value),
                ),
                const Text(
                  'Estas preferencias no cambian compras anteriores ni registran pagos.',
                ),
                const SizedBox(height: 12),
                const Text('DÍAS DE VISITA'),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final day in {..._days, ..._visitDays})
                      FilterChip(
                        label: Text(day),
                        selected: _visitDays.contains(day),
                        onSelected:
                            (selected) => setState(() {
                              selected
                                  ? _visitDays.add(day)
                                  : _visitDays.remove(day);
                            }),
                      ),
                  ],
                ),
                const Text('PRODUCTOS QUE SURTE'),
                const Text(
                  'Las relaciones existentes se conservan, incluso si el producto ya no aparece en el catálogo.',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final id in available)
                      FilterChip(
                        label: Text(
                          products[id]?.name ?? 'Producto #$id no disponible',
                        ),
                        selected: _selected.contains(id),
                        onSelected:
                            (selected) => setState(() {
                              selected
                                  ? _selected.add(id)
                                  : _selected.remove(id);
                            }),
                      ),
                  ],
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
        FilledButton(onPressed: _save, child: const Text('GUARDAR PROVEEDOR')),
      ],
    );
  }
}
