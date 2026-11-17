import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_session.dart';
import '../../../../core/storage/account_storage.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../data/repositories/staff_purchase_outbox.dart';
import '../../data/repositories/staff_purchases_repository.dart';
import '../../data/repositories/staff_provider_outbox.dart';
import '../../data/repositories/staff_providers_repository.dart';
import '../../domain/entities/provider_entity.dart';
import '../../domain/entities/purchase_entity.dart';
import '../../domain/entities/purchase_payment_terms.dart';
import '../../domain/entities/staff_purchase.dart';
import '../../domain/entities/staff_purchase_data.dart';
import '../../domain/entities/staff_provider_operation.dart';
import '../../domain/entities/staff_operation_rejection.dart';
import '../widgets/purchase_payment_dialog.dart';
import '../widgets/staff_provider_dialog.dart';

class StaffPurchasesPage extends StatefulWidget {
  const StaffPurchasesPage({
    super.key,
    this.enableForIntegration = false,
    this.repository,
    this.providersRepository,
    this.captureSession,
  }) : assert((repository == null) == (captureSession == null)),
       assert(providersRepository == null || repository != null);

  final bool enableForIntegration;
  final StaffPurchasesRepository? repository;
  final StaffProvidersRepository? providersRepository;
  final SyncSession Function()? captureSession;

  @override
  State<StaffPurchasesPage> createState() => _StaffPurchasesPageState();
}

class _StaffPurchasesPageState extends State<StaffPurchasesPage>
    with WidgetsBindingObserver {
  final _reference = TextEditingController();
  final _search = TextEditingController();
  final _cart = <int, StaffPurchaseItem>{};
  StaffPurchasesRepository? _repository;
  SyncSession Function()? _capture;
  SyncSession? _scope;
  StaffPurchaseData? _data;
  PendingStaffPurchase? _pending;
  StaffProvidersRepository? _providers;
  PendingStaffProvider? _pendingProvider;
  StreamSubscription<AuthState>? _authChanges;
  int? _providerId;
  String? _error;
  bool _busy = false;
  bool _reloadRequested = false;

  @override
  void initState() {
    super.initState();
    if (!widget.enableForIntegration) return;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_open());
  }

  Future<void> _open() => _run(() async {
    final provided = widget.repository;
    if (provided != null) {
      _repository = provided;
      _capture = widget.captureSession!;
    } else {
      if (!AccountStorage.instance.isActive) {
        throw StateError(
          'La cuenta ya no está activa. Reinicia la aplicación.',
        );
      }
      final client = Supabase.instance.client;
      final guard = SyncSessionGuard(client, PreferencesService());
      final session = guard.capture();
      final db = await DatabaseHelper.instance.database;
      guard.require(session);
      if (!mounted) return;
      _capture = guard.capture;
      _repository = StaffPurchasesRepository(
        client,
        StaffPurchaseOutbox(db, guard.require),
      );
    }
    _providers =
        widget.providersRepository ??
        StaffProvidersRepository(
          _repository!.client,
          StaffProviderOutbox(
            _repository!.outbox.database,
            _repository!.outbox.requireSession,
          ),
        );
    _authChanges = _repository!.client.auth.onAuthStateChange.listen((_) {
      if (!mounted) return;
      setState(() => _data = null);
      if (_busy) {
        _reloadRequested = true;
      } else {
        unawaited(_load());
      }
    });
    _reloadRequested = true;
  });

  SyncSession _session() {
    final session = _capture!();
    final scope = _scope;
    if (scope != null &&
        (scope.actorId != session.actorId ||
            scope.billarId != session.billarId ||
            scope.scopeGeneration != session.scopeGeneration)) {
      throw StateError('La cuenta o el billar de la pantalla cambió.');
    }
    _repository!.outbox.requireSession(session);
    _scope ??= session;
    return session;
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool refresh = false,
    bool clearError = true,
  }) async {
    if (!mounted || _busy) return;
    setState(() {
      _busy = true;
      if (clearError) _error = null;
    });
    try {
      await action();
    } on StaffOperationRejection catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } on StateError catch (error, stack) {
      _fail(error, stack);
    } on Exception catch (error, stack) {
      _fail(error, stack);
    } on ArgumentError catch (error, stack) {
      _fail(error, stack);
    } on TypeError catch (error, stack) {
      _fail(error, stack);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if ((refresh || _reloadRequested) && _repository != null) {
          _reloadRequested = false;
          unawaited(_load(keepError: true));
        }
      }
    }
  }

  void _fail(Object error, StackTrace stack) {
    log(
      'No se pudo completar Compras de personal',
      error: error,
      stackTrace: stack,
    );
    if (mounted) setState(() => _error = error.toString());
  }

  Future<void> _load({bool keepError = false}) {
    if (_repository == null) return _open();
    return _run(() async {
      setState(() => _data = null);
      final session = _session();
      final pending = await _repository!.outbox.pending(session);
      if (!mounted) return;
      setState(() => _pending = pending);
      final pendingProvider = await _providers!.outbox.pending(session);
      if (!mounted) return;
      setState(() => _pendingProvider = pendingProvider);
      final data = await _repository!.load(session);
      _repository!.outbox.requireSession(session);
      if (!mounted) return;
      setState(() {
        _data = data;
        if (!data.providers.any((provider) => provider.id == _providerId)) {
          _providerId = null;
        }
      });
    }, clearError: !keepError);
  }

  Future<void> _confirm() => _run(() async {
    final session = _session();
    final data = _data!;
    final items = List<StaffPurchaseItem>.unmodifiable(_cart.values);
    if (items.isEmpty) throw StateError('Agrega al menos un producto.');
    for (final item in items) {
      final current =
          data.products
              .where((product) => product.id == item.productId)
              .firstOrNull;
      if (current == null ||
          current.parentId != item.parentId ||
          current.piecesPerUnit != item.piecesPerUnit) {
        throw StateError(
          'Un producto o presentación cambió. Revisa el carrito antes de confirmar.',
        );
      }
    }
    final provider =
        data.providers
            .where((provider) => provider.id == _providerId)
            .firstOrNull;
    final reference = _reference.text.trim();
    final total = items.fold<double>(
      0,
      (sum, item) => sum + item.quantity * item.costPerUnit,
    );
    final payment = await showDialog<PurchasePaymentTerms>(
      context: context,
      builder: (_) => PurchasePaymentDialog(provider: provider, total: total),
    );
    if (payment == null || !mounted) return;
    _repository!.outbox.requireSession(session);
    final receipt = await _repository!.record(
      session,
      StaffPurchaseDraft(
        providerId: provider?.id,
        reference: reference,
        items: items,
        payment: payment,
        cashSource: payment.legacyCashSource,
      ),
    );
    _repository!.outbox.requireSession(session);
    if (!mounted) return;
    setState(() {
      _cart.clear();
      _reference.clear();
      _providerId = null;
      _data = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Compra #${receipt.purchaseId} confirmada · \$${receipt.total.toStringAsFixed(2)}',
        ),
      ),
    );
  }, refresh: true);

  Future<void> _recover({bool closeIfUnapplied = false}) => _run(() async {
    final session = _session();
    if (closeIfUnapplied && !await _confirmResolution()) return;
    _repository!.outbox.requireSession(session);
    final receipt =
        closeIfUnapplied
            ? await _repository!.resolvePending(session)
            : await _repository!.recover(session);
    _repository!.outbox.requireSession(session);
    if (!mounted) return;
    if (receipt == null) {
      throw StateError(
        'La solicitud pendiente ya no está disponible. Actualiza la pantalla.',
      );
    }
    setState(() {
      _cart.clear();
      _reference.clear();
      _providerId = null;
      _data = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Compra #${receipt.purchaseId} recuperada y confirmada.'),
      ),
    );
  }, refresh: true);

  Future<void> _editProvider(ProviderEntity? existing) => _run(() async {
    final session = _session();
    final products = _data!.products;
    if (_pending != null || _pendingProvider != null) {
      throw StateError('Recupera primero las solicitudes pendientes.');
    }
    final ids =
        existing == null
            ? <int>[]
            : await _providers!.productIds(session, existing.id!);
    _repository!.outbox.requireSession(session);
    if (!mounted) return;
    final draft = await showDialog<StaffProviderDraft>(
      context: context,
      builder:
          (_) => StaffProviderDialog(
            provider: existing,
            productIds: ids,
            products: products,
          ),
    );
    _repository!.outbox.requireSession(session);
    if (draft == null || !mounted) return;
    await _providers!.apply(session, draft);
    _repository!.outbox.requireSession(session);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Proveedor guardado con auditoría.')),
    );
  }, refresh: true);

  Future<void> _archiveProvider(ProviderEntity provider) => _run(() async {
    final session = _session();
    if (_pending != null || _pendingProvider != null) {
      throw StateError('Recupera primero las solicitudes pendientes.');
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('ARCHIVAR PROVEEDOR'),
            content: Text(
              '¿Archivar ${provider.name}? Se conservarán sus compras y relaciones históricas.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('CANCELAR'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('ARCHIVAR'),
              ),
            ],
          ),
    );
    _repository!.outbox.requireSession(session);
    if (confirmed != true || !mounted) return;
    await _providers!.apply(session, StaffProviderDraft.archive(provider.id!));
    _repository!.outbox.requireSession(session);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Proveedor archivado con auditoría.')),
    );
  }, refresh: true);

  Future<void> _recoverProvider({bool closeIfUnapplied = false}) =>
      _run(() async {
        final session = _session();
        if (closeIfUnapplied && !await _confirmResolution()) return;
        _repository!.outbox.requireSession(session);
        final receipt =
            closeIfUnapplied
                ? await _providers!.resolvePending(session)
                : await _providers!.recover(session);
        _repository!.outbox.requireSession(session);
        if (!mounted) return;
        if (receipt == null) {
          throw StateError('La solicitud de proveedor ya no está disponible.');
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Operación de proveedor recuperada y confirmada.'),
          ),
        );
      }, refresh: true);

  Future<bool> _confirmResolution() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('VERIFICAR SOLICITUD PENDIENTE'),
            content: const Text(
              'Si el servidor ya la aplicó, se recuperará su comprobante sin cancelar '
              'ni repetir cambios. Si no se aplicó, el servidor cerrará '
              'definitivamente esta solicitud y bloqueará sus reintentos. '
              'Solo después podrás corregir los datos y enviar una nueva. '
              'Si no hay confirmación, seguirá pendiente.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('VOLVER'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('VERIFICAR Y RESOLVER'),
              ),
            ],
          ),
    );
    return mounted && confirmed == true;
  }

  Future<void> _edit(StaffPurchaseProduct product) => _run(() async {
    final session = _session();
    if (_pending != null) {
      throw StateError('Recupera primero la compra pendiente.');
    }
    final current = _cart[product.id];
    final item = await showDialog<StaffPurchaseItem>(
      context: context,
      builder: (_) => _PurchaseItemDialog(product: product, current: current),
    );
    _repository!.outbox.requireSession(session);
    if (item != null && mounted) {
      setState(() => _cart[product.id] = item);
    }
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.enableForIntegration) {
      if (_busy) {
        _reloadRequested = true;
      } else {
        unawaited(_load());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_authChanges?.cancel());
    _reference.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final canEdit =
        !_busy && _pending == null && _pendingProvider == null && data != null;
    final total = _cart.values.fold<double>(
      0,
      (sum, item) => sum + item.quantity * item.costPerUnit,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('COMPRAS · PERSONAL'),
        actions: [
          if (widget.enableForIntegration)
            IconButton(
              tooltip: 'Actualizar compras',
              onPressed: _busy ? null : () => _load(),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body:
          !widget.enableForIntegration
              ? const Center(
                child: Text('Compras de personal aún no está habilitado.'),
              )
              : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_busy) const LinearProgressIndicator(),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _load(),
                      child: const Text('REINTENTAR CONSULTA'),
                    ),
                  ],
                  if (_pending != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Hay una compra pendiente de confirmación. No registres otra ni cambies su solicitud.',
                            ),
                            if (data != null)
                              Text(
                                'Referencia: ${_pending!.draft.reference} · \$${_pending!.draft.total.toStringAsFixed(2)}',
                              ),
                            FilledButton(
                              onPressed: _busy ? null : _recover,
                              child: const Text('RECUPERAR MISMA SOLICITUD'),
                            ),
                            TextButton(
                              onPressed:
                                  _busy
                                      ? null
                                      : () => _recover(closeIfUnapplied: true),
                              child: const Text('VERIFICAR CIERRE DE COMPRA'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_pendingProvider != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Hay un cambio de proveedor pendiente de confirmación. Recupera la misma solicitud antes de continuar.',
                            ),
                            FilledButton(
                              onPressed: _busy ? null : _recoverProvider,
                              child: const Text(
                                'RECUPERAR CAMBIO DE PROVEEDOR',
                              ),
                            ),
                            TextButton(
                              onPressed:
                                  _busy
                                      ? null
                                      : () => _recoverProvider(
                                        closeIfUnapplied: true,
                                      ),
                              child: const Text(
                                'VERIFICAR CIERRE DE PROVEEDOR',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (data != null) ...[
                    const Text(
                      'Registro online con auditoría. Sin cancelaciones. Los cambios de proveedores se registran con tu cuenta.',
                    ),
                    ExpansionTile(
                      title: const Text('GESTIONAR PROVEEDORES'),
                      children: [
                        TextButton.icon(
                          onPressed: canEdit ? () => _editProvider(null) : null,
                          icon: const Icon(Icons.add),
                          label: const Text('AGREGAR PROVEEDOR'),
                        ),
                        for (final provider in data.providers)
                          ListTile(
                            title: Text(provider.name),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Editar proveedor ${provider.name}',
                                  onPressed:
                                      canEdit
                                          ? () => _editProvider(provider)
                                          : null,
                                  icon: const Icon(Icons.edit),
                                ),
                                IconButton(
                                  tooltip:
                                      'Archivar proveedor ${provider.name}',
                                  onPressed:
                                      canEdit
                                          ? () => _archiveProvider(provider)
                                          : null,
                                  icon: const Icon(Icons.archive_outlined),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    DropdownButtonFormField<int>(
                      key: ValueKey(_providerId),
                      initialValue: _providerId,
                      decoration: const InputDecoration(labelText: 'Proveedor'),
                      items: [
                        const DropdownMenuItem<int>(
                          value: null,
                          child: Text('Sin proveedor'),
                        ),
                        for (final provider in data.providers)
                          DropdownMenuItem(
                            value: provider.id,
                            child: Text(provider.name),
                          ),
                      ],
                      onChanged:
                          canEdit
                              ? (value) => setState(() => _providerId = value)
                              : null,
                    ),
                    TextField(
                      controller: _reference,
                      enabled: canEdit,
                      decoration: const InputDecoration(
                        labelText: 'Referencia de compra',
                      ),
                    ),
                    TextField(
                      controller: _search,
                      enabled: canEdit,
                      decoration: const InputDecoration(
                        labelText: 'Buscar producto',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    for (final product in data.products.where(
                      (product) => product.name.toLowerCase().contains(
                        _search.text.trim().toLowerCase(),
                      ),
                    ))
                      ListTile(
                        title: Text(product.name),
                        subtitle: Text(
                          product.parentId == null
                              ? 'Unidad base'
                              : '${product.piecesPerUnit} piezas por presentación',
                        ),
                        trailing: IconButton(
                          tooltip: 'Agregar ${product.name}',
                          onPressed: canEdit ? () => _edit(product) : null,
                          icon: const Icon(Icons.add_shopping_cart),
                        ),
                      ),
                    const Divider(),
                    const Text('CARRITO'),
                    for (final item in _cart.values)
                      ListTile(
                        title: Text(
                          data.products
                                  .where(
                                    (product) => product.id == item.productId,
                                  )
                                  .firstOrNull
                                  ?.name ??
                              'Producto #${item.productId} no disponible',
                        ),
                        subtitle: Text(
                          '${item.quantity} × \$${item.costPerUnit.toStringAsFixed(2)}',
                        ),
                        trailing: IconButton(
                          tooltip: 'Quitar producto ${item.productId}',
                          onPressed:
                              canEdit
                                  ? () => setState(
                                    () => _cart.remove(item.productId),
                                  )
                                  : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                      ),
                    Text('Total: \$${total.toStringAsFixed(2)}'),
                    FilledButton(
                      onPressed: canEdit && _cart.isNotEmpty ? _confirm : null,
                      child: const Text('REVISAR Y CONFIRMAR COMPRA'),
                    ),
                    const Divider(),
                    const Text('HISTORIAL · ÚLTIMAS 50 COMPRAS'),
                    if (data.history.isEmpty)
                      const Text('No hay compras registradas.'),
                    for (final purchase in data.history)
                      ListTile(
                        title: Text(
                          '#${purchase.id} · ${purchase.reference} · \$${purchase.total.toStringAsFixed(2)}',
                        ),
                        subtitle: Text(
                          '${purchase.date.toLocal()}${purchase.cancelled ? ' · ANULADA' : ''}\n'
                          '${purchase.payment?.isCredit == true
                              ? 'Crédito · ${purchase.cancelled ? 'saldo histórico' : 'saldo'} \$${purchase.total.toStringAsFixed(2)} · vence ${purchase.payment!.snapshot(total: purchase.total, recordedAt: purchase.date)['due_date']}'
                              : purchase.payment == null
                              ? 'Condiciones históricas sin completar'
                              : PurchasePaymentOption.label(purchase.payment!.option)}',
                        ),
                      ),
                  ],
                ],
              ),
    );
  }
}

class _PurchaseItemDialog extends StatefulWidget {
  const _PurchaseItemDialog({required this.product, required this.current});
  final StaffPurchaseProduct product;
  final StaffPurchaseItem? current;

  @override
  State<_PurchaseItemDialog> createState() => _PurchaseItemDialogState();
}

class _PurchaseItemDialogState extends State<_PurchaseItemDialog> {
  final _form = GlobalKey<FormState>();
  late final _quantity = TextEditingController(
    text: widget.current?.quantity.toString() ?? '1',
  );
  late final _cost = TextEditingController(
    text:
        widget.current?.costPerUnit.toString() ??
        widget.product.cost?.toString() ??
        '',
  );

  @override
  void dispose() {
    _quantity.dispose();
    _cost.dispose();
    super.dispose();
  }

  String? _validate(String? value, {required bool quantity}) {
    final number = double.tryParse(value?.trim() ?? '');
    return number == null ||
            !number.isFinite ||
            (quantity ? number <= 0 : number < 0)
        ? 'Ingresa ${quantity ? 'una cantidad positiva' : 'un costo no negativo'}.'
        : null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.product.name),
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: _quantity,
            decoration: const InputDecoration(labelText: 'Cantidad'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: (value) => _validate(value, quantity: true),
          ),
          TextFormField(
            controller: _cost,
            decoration: const InputDecoration(
              labelText: 'Costo por presentación',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: (value) => _validate(value, quantity: false),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          Navigator.pop(
            context,
            StaffPurchaseItem(
              productId: widget.product.id,
              quantity: double.parse(_quantity.text.trim()),
              costPerUnit: double.parse(_cost.text.trim()),
              parentId: widget.product.parentId,
              piecesPerUnit: widget.product.piecesPerUnit,
            ),
          );
        },
        child: const Text('AGREGAR AL CARRITO'),
      ),
    ],
  );
}
