import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_session.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../sales/presentation/services/ticket_service.dart';
import '../../data/staff_sale_cache.dart';
import '../controllers/staff_quick_sale_controller.dart';

class StaffQuickSalePage extends StatefulWidget {
  const StaffQuickSalePage({
    super.key,
    this.enableForIntegration = false,
    this.controller,
  });

  final bool enableForIntegration;
  final StaffQuickSaleController? controller;

  @override
  State<StaffQuickSalePage> createState() => _StaffQuickSalePageState();
}

class _StaffQuickSalePageState extends State<StaffQuickSalePage>
    with WidgetsBindingObserver {
  StaffQuickSaleController? _controller;
  String? _initializationError;
  bool _paymentOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.enableForIntegration) unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final provided = widget.controller;
      final StaffQuickSaleController controller;
      if (provided != null) {
        controller = provided;
      } else {
        final client = Supabase.instance.client;
        final guard = SyncSessionGuard(client, PreferencesService());
        final db = await DatabaseHelper.instance.database;
        if (!mounted) return;
        controller = StaffQuickSaleController(
          client: client,
          cache: StaffSaleCache(db, guard.require),
          captureSession: guard.capture,
        );
      }
      _controller = controller;
      controller.addListener(_changed);
      if (!controller.ready) await controller.load();
    } on StateError catch (error, stack) {
      _initializationFailed(error, stack);
    } on Exception catch (error, stack) {
      _initializationFailed(error, stack);
    }
  }

  void _initializationFailed(Object error, StackTrace stack) {
    log('No se pudo abrir venta de personal', error: error, stackTrace: stack);
    if (mounted) setState(() => _initializationError = error.toString());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller?.load());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.removeListener(_changed);
    if (widget.controller == null) _controller?.dispose();
    super.dispose();
  }

  Future<void> _pay(StaffQuickSaleController controller) async {
    if (_paymentOpen || controller.busy) return;
    _paymentOpen = true;
    final total = controller.total;
    final cart = controller.cart;
    try {
      final payment = await showDialog<(double, String)>(
        context: context,
        builder:
            (_) => ListenableBuilder(
              listenable: controller,
              builder:
                  (_, _) => _StaffPaymentDialog(
                    total: total,
                    canConfirm: !controller.busy,
                  ),
            ),
      );
      if (payment != null && mounted) {
        await controller.checkout(
          paid: payment.$1,
          paymentMethod: payment.$2,
          expectedTotal: total,
          expectedCart: cart,
        );
      }
    } finally {
      _paymentOpen = false;
    }
  }

  Future<void> _preview(StaffQuickSaleController controller) async {
    await controller.refreshReceipt();
    if (!mounted || controller.error != null) return;
    final receipt = controller.receipt;
    if (receipt == null) return;
    try {
      await TicketService().showPreviewSheet(
        context: context,
        items: receipt.items,
        total: receipt.total,
        paid: receipt.paid,
        paymentMethod: receipt.paymentMethod,
        saleType: 'Venta Rápida',
        ticketNumber: receipt.remoteId,
      );
    } on Exception catch (error, stack) {
      log(
        'Error mostrando comprobante de personal',
        error: error,
        stackTrace: stack,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Venta confirmada; no se pudo mostrar el comprobante: $error',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('VENTA RÁPIDA · PERSONAL'),
        actions: [
          if (controller != null)
            IconButton(
              tooltip: 'Actualizar',
              onPressed: controller.busy ? null : controller.load,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body:
          !widget.enableForIntegration
              ? const Center(
                child: Text('El acceso de personal aún no está habilitado.'),
              )
              : _initializationError != null
              ? Center(child: Text(_initializationError!))
              : controller == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                children: [
                  if (controller.busy) const LinearProgressIndicator(),
                  if (controller.error != null)
                    MaterialBanner(
                      content: Text(controller.error!),
                      actions: [
                        TextButton(
                          onPressed: controller.busy ? null : controller.load,
                          child: const Text('REINTENTAR'),
                        ),
                      ],
                    ),
                  if (controller.ready && controller.pending)
                    MaterialBanner(
                      content: const Text(
                        'Hay una venta pendiente. No cobres de nuevo ni cambies '
                        'el carrito; recupera su confirmación.',
                      ),
                      actions: [
                        FilledButton(
                          onPressed:
                              controller.busy ? null : controller.recover,
                          child: const Text('RECUPERAR VENTA'),
                        ),
                      ],
                    ),
                  if (controller.ready && controller.receipt != null)
                    ListTile(
                      title: Text(
                        'Venta confirmada #${controller.receipt!.remoteId}',
                      ),
                      subtitle: Text(
                        '\$${controller.receipt!.total.toStringAsFixed(2)}',
                      ),
                      trailing: TextButton(
                        onPressed:
                            controller.busy ? null : () => _preview(controller),
                        child: const Text('VER COMPROBANTE'),
                      ),
                    ),
                  if (controller.ready) ...[
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text(
                        'Las existencias se validan en el servidor al cobrar.',
                      ),
                    ),
                    Expanded(child: _catalog(controller)),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: FilledButton(
                        onPressed:
                            controller.busy ||
                                    controller.pending ||
                                    controller.cart.isEmpty
                                ? null
                                : () => _pay(controller),
                        child: Text(
                          'COBRAR \$${controller.total.toStringAsFixed(2)}',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
    );
  }

  Widget _catalog(StaffQuickSaleController controller) {
    final products = {
      for (final product in controller.products) product.id: product,
    };
    final visible =
        products.values
            .where(
              (product) =>
                  product.isActive || controller.cart.containsKey(product.id),
            )
            .toList();
    if (visible.isEmpty) {
      return const Center(child: Text('Sin productos de venta.'));
    }
    final editable = !controller.busy && !controller.pending;
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final product = visible[index];
        final quantity = controller.cart[product.id] ?? 0;
        final stock = product.availableStock(products, controller.cart);
        return ListTile(
          title: Text(product.name),
          subtitle: Text(
            product.isActive
                ? '\$${product.price.toStringAsFixed(2)} · Disponible: $stock'
                : 'No disponible: retíralo del carrito',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: ValueKey('remove-${product.id}'),
                tooltip: 'Quitar ${product.name}',
                onPressed:
                    editable && quantity > 0
                        ? () => controller.setQuantity(product.id, quantity - 1)
                        : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text('$quantity'),
              IconButton(
                key: ValueKey('add-${product.id}'),
                tooltip: 'Agregar ${product.name}',
                onPressed:
                    editable && product.isActive
                        ? () => controller.setQuantity(product.id, quantity + 1)
                        : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StaffPaymentDialog extends StatefulWidget {
  const _StaffPaymentDialog({required this.total, required this.canConfirm});

  final double total;
  final bool canConfirm;

  @override
  State<_StaffPaymentDialog> createState() => _StaffPaymentDialogState();
}

class _StaffPaymentDialogState extends State<_StaffPaymentDialog> {
  late final TextEditingController _amount;
  String _method = 'Efectivo';
  String? _error;

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(text: widget.total.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('COBRAR'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Total: \$${widget.total.toStringAsFixed(2)}'),
        DropdownButton<String>(
          value: _method,
          items:
              ['Efectivo', 'Tarjeta', 'Transferencia']
                  .map(
                    (value) =>
                        DropdownMenuItem(value: value, child: Text(value)),
                  )
                  .toList(),
          onChanged: (value) {
            if (value != null) setState(() => _method = value);
          },
        ),
        if (_method == 'Efectivo')
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Monto recibido',
              errorText: _error,
            ),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('CANCELAR'),
      ),
      FilledButton(
        onPressed:
            !widget.canConfirm
                ? null
                : () {
                  final paid =
                      _method == 'Efectivo'
                          ? double.tryParse(_amount.text)
                          : widget.total;
                  if (paid == null || !paid.isFinite || paid < 0) {
                    setState(() => _error = 'Ingresa un monto válido.');
                    return;
                  }
                  Navigator.pop(context, (paid, _method));
                },
        child: const Text('CONFIRMAR'),
      ),
    ],
  );
}
