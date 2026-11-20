import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/database_helper.dart';
import '../../../../core/services/sync_session.dart';
import '../../../../core/storage/account_storage.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/utils/uuid_v4.dart';
import '../../../auth/domain/staff_access.dart';
import '../../../inventory/data/repositories/product_repository.dart';
import '../../../inventory/domain/entities/product_entity.dart';
import '../../data/repositories/staff_table_checkout_outbox.dart';
import '../../data/repositories/staff_table_checkout_snapshot_repository.dart';
import '../../data/repositories/staff_table_conflict_repository.dart';
import '../../data/repositories/staff_table_late_adjustment_outbox.dart';
import '../../data/repositories/staff_table_late_adjustment_snapshot_repository.dart';
import '../../data/repositories/staff_table_service_outbox.dart';
import '../../data/repositories/staff_table_service_sync.dart';
import '../../data/repositories/staff_table_visibility_repository.dart';

typedef _ConsumptionSelection = ({ProductEntity product, double quantity});
typedef _PaymentSelection = ({String paymentMethod, double paid});

class StaffTableServicePage extends StatefulWidget {
  const StaffTableServicePage({
    super.key,
    required this.tableType,
    required this.allowedModules,
    this.enableForIntegration = false,
  });

  final String tableType;
  final Set<StaffModule> allowedModules;
  final bool enableForIntegration;

  @override
  State<StaffTableServicePage> createState() => _StaffTableServicePageState();
}

class _StaffTableServicePageState extends State<StaffTableServicePage>
    with WidgetsBindingObserver {
  StreamSubscription<AuthState>? _authChanges;
  SyncSession? _scope;
  StaffTableServiceOutbox? _outbox;
  StaffTableServiceSync? _serviceSync;
  StaffTableConflictRepository? _conflictRepository;
  StaffTableCheckoutSnapshotRepository? _checkoutSnapshots;
  StaffTableCheckoutOutbox? _checkoutOutbox;
  StaffTableCheckoutSender? _checkoutSender;
  StaffTableLateAdjustmentSnapshotRepository? _lateAdjustmentSnapshots;
  StaffTableLateAdjustmentOutbox? _lateAdjustmentOutbox;
  StaffTableLateAdjustmentSender? _lateAdjustmentSender;
  List<Map<String, dynamic>> _tables = [];
  List<ProductEntity> _products = [];
  List<PendingStaffTableCheckout> _pendingCheckouts = [];
  List<PendingStaffTableLateAdjustment> _pendingLateAdjustments = [];
  DateTime? _cachedAt;
  String? _error;
  String? _productError;
  bool _usingCache = false;
  bool _loading = false;
  int _request = 0;

  StaffModule get _openPermission =>
      widget.tableType == 'Comanda'
          ? StaffModule.dineInOpen
          : StaffModule.billiardTablesOpen;

  StaffModule get _consumePermission =>
      widget.tableType == 'Comanda'
          ? StaffModule.dineInConsume
          : StaffModule.billiardTablesConsume;

  bool get _canOpen => widget.allowedModules.contains(_openPermission);
  bool get _canConsume => widget.allowedModules.contains(_consumePermission);
  bool get _canCharge => widget.allowedModules.contains(
    widget.tableType == 'Comanda'
        ? StaffModule.dineInCharge
        : StaffModule.billiardTablesCharge,
  );

  bool get _canViewAll => widget.allowedModules.contains(
    widget.tableType == 'Comanda'
        ? StaffModule.dineInViewAll
        : StaffModule.billiardTablesViewAll,
  );

  @override
  void initState() {
    super.initState();
    if (!widget.enableForIntegration) return;
    WidgetsBinding.instance.addObserver(this);
    _authChanges = Supabase.instance.client.auth.onAuthStateChange.listen((_) {
      unawaited(_load());
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!mounted || !widget.enableForIntegration) return;
    final request = ++_request;
    setState(() {
      _tables = [];
      _error = null;
      _productError = null;
      _loading = true;
      _usingCache = false;
      _cachedAt = null;
    });
    try {
      if (!AccountStorage.instance.isActive) {
        throw StateError('La base local de la cuenta no está activa.');
      }
      final client = Supabase.instance.client;
      final guard = SyncSessionGuard(client, PreferencesService());
      final session = guard.capture();
      final previous = _scope;
      if (previous != null &&
          (previous.actorId != session.actorId ||
              previous.billarId != session.billarId ||
              previous.scopeGeneration != session.scopeGeneration)) {
        throw StateError('La cuenta o el billar de esta pantalla cambió.');
      }
      _scope ??= session;
      final database = await DatabaseHelper.instance.database;
      guard.require(session);
      final outbox = StaffTableServiceOutbox(database, guard.require);
      final visibility = StaffTableVisibilityRepository(
        client,
        guard.require,
        database: database,
      );
      final serviceSync = StaffTableServiceSync(client, outbox);
      final conflictRepository = StaffTableConflictRepository(
        client,
        guard.require,
      );
      final checkoutSnapshots = StaffTableCheckoutSnapshotRepository(
        client,
        guard.require,
      );
      final checkoutOutbox = StaffTableCheckoutOutbox(database, guard.require);
      final checkoutSender = StaffTableCheckoutSender(client, checkoutOutbox);
      final pendingCheckouts = await checkoutOutbox.pending(session);
      if (mounted && request == _request) {
        setState(() => _pendingCheckouts = pendingCheckouts);
      }
      final lateAdjustmentSnapshots =
          StaffTableLateAdjustmentSnapshotRepository(client, guard.require);
      final lateAdjustmentOutbox = StaffTableLateAdjustmentOutbox(
        database,
        guard.require,
      );
      final lateAdjustmentSender = StaffTableLateAdjustmentSender(
        client,
        lateAdjustmentOutbox,
      );
      final pendingLateAdjustments = await lateAdjustmentOutbox.pending(
        session,
      );
      if (mounted && request == _request) {
        setState(() => _pendingLateAdjustments = pendingLateAdjustments);
      }
      List<Map<String, dynamic>> visible;
      var usingCache = false;
      DateTime? cachedAt;
      try {
        visible = await visibility.read(
          session: session,
          tableType: widget.tableType,
        );
      } on SocketException catch (error, stack) {
        log(
          'No se pudo actualizar la visibilidad del servicio',
          error: error,
          stackTrace: stack,
        );
        final snapshot = await _readCached(visibility, session, error);
        visible = snapshot.tables;
        cachedAt = snapshot.fetchedAt;
        usingCache = true;
      } on TimeoutException catch (error, stack) {
        log(
          'La consulta de visibilidad agotó el tiempo de espera',
          error: error,
          stackTrace: stack,
        );
        final snapshot = await _readCached(visibility, session, error);
        visible = snapshot.tables;
        cachedAt = snapshot.fetchedAt;
        usingCache = true;
      } on http.ClientException catch (error, stack) {
        log(
          'No se pudo conectar para consultar la visibilidad',
          error: error,
          stackTrace: stack,
        );
        final snapshot = await _readCached(visibility, session, error);
        visible = snapshot.tables;
        cachedAt = snapshot.fetchedAt;
        usingCache = true;
      }

      for (final table in visible) {
        if (table['service_actor_id'] != session.actorId ||
            table['service_id'] is! String ||
            table['start_time'] is! String) {
          continue;
        }
        await outbox.adoptVisibleActive(
          session: session,
          serviceId: table['service_id'] as String,
          serviceActorId: table['service_actor_id'] as String,
          tableId: table['id'] as int,
          tableType: widget.tableType,
          openedAt: DateTime.parse(table['start_time'] as String),
          items: List<Map<String, dynamic>>.from(
            (table['service_items'] as List).map(
              (item) => Map<String, dynamic>.from(item as Map),
            ),
          ),
        );
      }
      final drafts = await outbox.drafts(session);
      final tables = await _mergeLocalDrafts(session, visible, drafts, outbox);
      List<ProductEntity> products = [];
      String? productError;
      if (_canConsume) {
        try {
          products = await ProductRepository().getAll(syncRemote: false);
          products = products
              .where(
                (product) =>
                    product.id != null &&
                    product.id! > 0 &&
                    product.isActive &&
                    product.price.isFinite &&
                    product.price >= 0,
              )
              .toList(growable: false);
        } on Exception catch (error, stack) {
          log(
            'No se pudo leer el catálogo local para el servicio',
            error: error,
            stackTrace: stack,
          );
          productError = error.toString();
        }
      }

      guard.require(session);
      if (!mounted || request != _request) return;
      _outbox = outbox;
      _serviceSync = serviceSync;
      _conflictRepository = conflictRepository;
      _checkoutSnapshots = checkoutSnapshots;
      _checkoutOutbox = checkoutOutbox;
      _checkoutSender = checkoutSender;
      _lateAdjustmentSnapshots = lateAdjustmentSnapshots;
      _lateAdjustmentOutbox = lateAdjustmentOutbox;
      _lateAdjustmentSender = lateAdjustmentSender;
      setState(() {
        _tables = tables;
        _products = products;
        _pendingCheckouts = pendingCheckouts;
        _pendingLateAdjustments = pendingLateAdjustments;
        _productError = productError;
        _usingCache = usingCache;
        _cachedAt = cachedAt;
      });
    } on StateError catch (error, stack) {
      _fail(request, error, stack);
    } on Exception catch (error, stack) {
      _fail(request, error, stack);
    } on TypeError catch (error, stack) {
      _fail(request, error, stack);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<StaffTableVisibilitySnapshot> _readCached(
    StaffTableVisibilityRepository repository,
    SyncSession session,
    Object networkError,
  ) async {
    final snapshot = await repository.readCached(
      session: session,
      tableType: widget.tableType,
      canViewAll: _canViewAll,
    );
    if (snapshot == null) {
      throw StateError(
        'No hay una consulta previa de mesas para mostrar. $networkError',
      );
    }
    return snapshot;
  }

  Future<List<Map<String, dynamic>>> _mergeLocalDrafts(
    SyncSession session,
    List<Map<String, dynamic>> visible,
    List<StaffTableServiceDraft> drafts,
    StaffTableServiceOutbox outbox,
  ) async {
    final tables = <int, Map<String, dynamic>>{
      for (final table in visible) table['id'] as int: Map.of(table),
    };
    for (final draft in drafts) {
      if (draft.tableType != widget.tableType) continue;
      final localItems = await outbox.consumptions(session, draft.id);
      final table =
          tables[draft.tableId] ??
          <String, dynamic>{
            'id': draft.tableId,
            'billar_id': session.billarId,
            'name': 'Mesa ${draft.tableId}',
            'table_type': widget.tableType,
            'is_occupied': 1,
            'start_time': draft.openedAt.toUtc().toIso8601String(),
            'orders': '[]',
            'is_deleted': 0,
            'service_id': null,
            'service_actor_id': null,
            'service_state': null,
            'service_items': <dynamic>[],
          };
      final serviceId = table['service_id'];
      final serviceActor = table['service_actor_id'];
      final itemsById = <String, Map<String, dynamic>>{
        for (final item in (table['service_items'] as List))
          if (item is Map && item['request_id'] is String)
            item['request_id'] as String: Map<String, dynamic>.from(item),
      };
      for (final item in localItems) {
        itemsById[item.requestId] = {
          'request_id': item.requestId,
          'productId': item.productId,
          'productName': item.productName,
          'quantity': item.quantity,
          'price': item.price,
          'recorded_at': item.recordedAt.toUtc().toIso8601String(),
          'late': item.late,
        };
      }
      final merged = {
        ...table,
        'service_items': itemsById.values.toList(growable: false),
        '_has_pending_consumption': localItems.any((item) => !item.confirmed),
      };
      if (serviceId == null || serviceId == draft.id) {
        merged
          ..['service_id'] = draft.id
          ..['service_actor_id'] = session.actorId
          ..['service_state'] = draft.state
          ..['_local_draft_state'] = draft.state;
      } else {
        merged['_pending_service_id'] = draft.id;
        merged['_local_draft_state'] = draft.state;
        if (serviceActor == session.actorId) {
          throw StateError('Hay servicios incompatibles en la misma mesa.');
        }
      }
      tables[draft.tableId] = merged;
    }
    return tables.values.toList()
      ..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
  }

  void _fail(int request, Object error, StackTrace stack) {
    log(
      'No se pudo cargar el servicio aislado de personal',
      error: error,
      stackTrace: stack,
    );
    if (mounted && request == _request) {
      setState(() => _error = error.toString());
    }
  }

  Future<void> _openTable(Map<String, dynamic> table) async {
    final outbox = _outbox;
    final sync = _serviceSync;
    final session = _scope;
    if (outbox == null || sync == null || session == null || !_canOpen) return;
    var savedLocally = false;
    try {
      final openedAt = DateTime.now().toUtc();
      final draft = await outbox.open(
        session: session,
        serviceId: newUuidV4(),
        tableId: table['id'] as int,
        tableType: widget.tableType,
        openedAt: openedAt,
      );
      savedLocally = true;
      final confirmed = await sync.synchronize(session, draft.id);
      if (!mounted) return;
      _showMessage(
        confirmed.state == 'conflict'
            ? 'La mesa ya fue ocupada; la apertura quedó para revisión.'
            : 'Apertura confirmada por el servidor.',
      );
    } on StateError catch (error, stack) {
      _operationFailed(error, stack, savedLocally);
    } on Exception catch (error, stack) {
      _operationFailed(error, stack, savedLocally);
    } on TypeError catch (error, stack) {
      _operationFailed(error, stack, savedLocally);
    } finally {
      await _load();
    }
  }

  Future<void> _addConsumption(Map<String, dynamic> table) async {
    final outbox = _outbox;
    final sync = _serviceSync;
    final session = _scope;
    final serviceId = table['_pending_service_id'] ?? table['service_id'];
    if (outbox == null ||
        sync == null ||
        session == null ||
        !_canConsume ||
        serviceId is! String ||
        table['service_actor_id'] != session.actorId ||
        table['service_state'] == 'conflict') {
      return;
    }
    final selection = await _selectConsumption();
    if (selection == null || !mounted) return;
    var savedLocally = false;
    try {
      final item = await outbox.addConsumption(
        session: session,
        requestId: newUuidV4(),
        serviceId: serviceId,
        productId: selection.product.id!,
        productName: selection.product.name,
        quantity: selection.quantity,
        price: selection.product.price,
        recordedAt: DateTime.now().toUtc(),
      );
      savedLocally = true;
      final state = await sync.synchronize(session, item.serviceId);
      if (!mounted) return;
      _showMessage(
        state.state == 'conflict'
            ? 'El consumo quedó guardado para revisión; no se agregó a una venta.'
            : 'Consumo guardado.',
      );
    } on StateError catch (error, stack) {
      _operationFailed(error, stack, savedLocally);
    } on Exception catch (error, stack) {
      _operationFailed(error, stack, savedLocally);
    } on TypeError catch (error, stack) {
      _operationFailed(error, stack, savedLocally);
    } finally {
      await _load();
    }
  }

  Future<void> _chargeService(Map<String, dynamic> table) async {
    final snapshots = _checkoutSnapshots;
    final outbox = _checkoutOutbox;
    final sender = _checkoutSender;
    final session = _scope;
    final serviceId = table['service_id'];
    if (!_canCharge ||
        snapshots == null ||
        outbox == null ||
        sender == null ||
        session == null ||
        serviceId is! String ||
        table['service_state'] != 'active' ||
        table['_has_pending_consumption'] == true) {
      return;
    }
    try {
      final pending =
          (await outbox.pending(
            session,
          )).where((item) => item.serviceId == serviceId).toList();
      if (pending.length > 1) {
        throw StateError('El servicio tiene cobros pendientes duplicados.');
      }
      var request = pending.isEmpty ? null : pending.single;
      if (request == null) {
        final snapshot = await snapshots.read(
          session: session,
          tableType: widget.tableType,
          serviceId: serviceId,
        );
        if (snapshot.actorId != table['service_actor_id'] ||
            snapshot.tableId != table['id']) {
          throw const FormatException(
            'El servicio cambió durante la consulta de cobro.',
          );
        }
        if (!mounted) return;
        final payment =
            await _StaffTableConflictDetailsDialogState.selectPayment(
              context: context,
              title: 'Cobrar servicio',
              tableId: snapshot.tableId,
              total: snapshot.total,
              items: snapshot.items,
              timeCost: snapshot.timeCost,
            );
        if (payment == null || !mounted) return;
        request = await outbox.prepare(
          session: session,
          snapshot: snapshot,
          paymentMethod: payment.paymentMethod,
          paid: payment.paid,
        );
      }
      final applied = await sender.send(session: session, request: request);
      if (applied.localSaleId == null) {
        throw StateError('El cobro sigue pendiente de aplicarse localmente.');
      }
      if (!mounted) return;
      setState(() => _pendingCheckouts = []);
      _showMessage('Cobro confirmado; la venta se registró.');
    } on StateError catch (error, stack) {
      log(
        'No se pudo recuperar el cobro de la mesa',
        error: error,
        stackTrace: stack,
      );
      if (mounted) _showMessage(error.toString());
    } on PostgrestException catch (error, stack) {
      log(
        'El servidor rechazó el cobro de la mesa',
        error: error,
        stackTrace: stack,
      );
      if (mounted) _showMessage('No se registró el cobro: ${error.message}');
    } on Exception catch (error, stack) {
      log(
        'No se pudo confirmar el cobro de la mesa',
        error: error,
        stackTrace: stack,
      );
      if (mounted) {
        _showMessage('El cobro queda pendiente de recuperar: $error');
      }
    } finally {
      await _load();
    }
  }

  Future<void> _synchronize(Map<String, dynamic> table) async {
    final sync = _serviceSync;
    final session = _scope;
    final serviceId = table['_pending_service_id'] ?? table['service_id'];
    final state = table['_local_draft_state'] ?? table['service_state'];
    if (sync == null ||
        session == null ||
        serviceId is! String ||
        !const {'pending', 'active'}.contains(state)) {
      return;
    }
    try {
      final result = await sync.synchronize(session, serviceId);
      if (!mounted) return;
      _showMessage(
        result.state == 'conflict'
            ? 'El servicio tiene un conflicto pendiente de revisión.'
            : 'Pendientes sincronizados.',
      );
    } on StateError catch (error, stack) {
      _operationFailed(error, stack, true);
    } on Exception catch (error, stack) {
      _operationFailed(error, stack, true);
    } on TypeError catch (error, stack) {
      _operationFailed(error, stack, true);
    } finally {
      await _load();
    }
  }

  Future<void> _reviewConflicts() async {
    final repository = _conflictRepository;
    final session = _scope;
    if (repository == null || session == null || !_canViewAll) return;
    await showDialog<void>(
      context: context,
      builder:
          (context) => _StaffTableConflictReviewDialog(
            repository: repository,
            lateAdjustmentSnapshots: _lateAdjustmentSnapshots!,
            lateAdjustmentOutbox: _lateAdjustmentOutbox!,
            lateAdjustmentSender: _lateAdjustmentSender!,
            session: session,
            tableType: widget.tableType,
            canCharge: _canCharge,
          ),
    );
  }

  Future<void> _recoverLateAdjustment() async {
    final outbox = _lateAdjustmentOutbox;
    final sender = _lateAdjustmentSender;
    final session = _scope;
    if (outbox == null || sender == null || session == null) return;
    try {
      final pending = await outbox.pending(session);
      if (pending.length != 1) {
        throw StateError('El ajuste pendiente no es único.');
      }
      final result = await sender.send(
        session: session,
        request: pending.single,
      );
      if (result.localSaleId == null) {
        throw StateError('El ajuste sigue pendiente de aplicarse localmente.');
      }
      if (!mounted) return;
      setState(() => _pendingLateAdjustments = []);
      _showMessage('Ajuste tardío recuperado y aplicado.');
      await _load();
    } on StateError catch (error, stack) {
      log(
        'No se pudo recuperar el ajuste tardío guardado',
        error: error,
        stackTrace: stack,
      );
      if (mounted) _showMessage(error.toString());
    } on Exception catch (error, stack) {
      log(
        'No se pudo recuperar el ajuste tardío guardado',
        error: error,
        stackTrace: stack,
      );
      if (mounted) {
        _showMessage('El ajuste sigue pendiente de confirmación: $error');
      }
    }
  }

  Future<void> _recoverCheckout() async {
    final outbox = _checkoutOutbox;
    final sender = _checkoutSender;
    final session = _scope;
    if (outbox == null || sender == null || session == null) return;
    try {
      final pending = await outbox.pending(session);
      if (pending.length != 1) {
        throw StateError('El cobro pendiente no es único.');
      }
      final result = await sender.send(
        session: session,
        request: pending.single,
      );
      if (result.localSaleId == null) {
        throw StateError('El cobro sigue pendiente de aplicarse localmente.');
      }
      if (!mounted) return;
      setState(() => _pendingCheckouts = []);
      _showMessage('Cobro recuperado y aplicado.');
    } on StateError catch (error, stack) {
      log(
        'No se pudo recuperar el cobro guardado',
        error: error,
        stackTrace: stack,
      );
      if (mounted) _showMessage(error.toString());
    } on Exception catch (error, stack) {
      log(
        'No se pudo recuperar el cobro guardado',
        error: error,
        stackTrace: stack,
      );
      if (mounted) {
        _showMessage('El cobro sigue pendiente de confirmación: $error');
      }
    } finally {
      await _load();
    }
  }

  void _operationFailed(Object error, StackTrace stack, bool savedLocally) {
    log(
      'No se pudo confirmar la operación del servicio',
      error: error,
      stackTrace: stack,
    );
    if (!mounted) return;
    _showMessage(
      savedLocally
          ? 'Quedó guardado localmente, sin confirmación del servidor: $error'
          : error.toString(),
    );
  }

  Future<_ConsumptionSelection?> _selectConsumption() async {
    if (_products.isEmpty) {
      _showMessage(
        _productError ??
            'No hay productos activos guardados en este dispositivo.',
      );
      return null;
    }
    var selected = _products.first;
    var quantity = '1';
    var quantityError = '';
    return showDialog<_ConsumptionSelection>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('Anotar consumo'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DropdownButtonFormField<ProductEntity>(
                        initialValue: selected,
                        isExpanded: true,
                        items: [
                          for (final product in _products)
                            DropdownMenuItem(
                              value: product,
                              child: Text(
                                '${product.name} · \$${product.price.toStringAsFixed(2)}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (product) {
                          if (product != null) {
                            setDialogState(() => selected = product);
                          }
                        },
                      ),
                      TextField(
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (value) => quantity = value,
                        decoration: InputDecoration(
                          labelText: 'Cantidad',
                          errorText:
                              quantityError.isEmpty ? null : quantityError,
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('CANCELAR'),
                    ),
                    FilledButton(
                      onPressed: () {
                        final parsed = double.tryParse(quantity.trim());
                        if (parsed == null || !parsed.isFinite || parsed <= 0) {
                          setDialogState(
                            () =>
                                quantityError = 'Ingresa una cantidad válida.',
                          );
                          return;
                        }
                        Navigator.pop(dialogContext, (
                          product: selected,
                          quantity: parsed,
                        ));
                      },
                      child: const Text('GUARDAR'),
                    ),
                  ],
                ),
          ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  @override
  void dispose() {
    _request++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_authChanges?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isComanda = widget.tableType == 'Comanda';
    return Scaffold(
      appBar: AppBar(
        title: Text(isComanda ? 'COMANDAS · PERSONAL' : 'MESAS · PERSONAL'),
        actions: [
          if (_canViewAll)
            IconButton(
              tooltip: 'Revisar conflictos',
              onPressed: _loading ? null : _reviewConflicts,
              icon: const Icon(Icons.fact_check_outlined),
            ),
          IconButton(
            tooltip: 'Actualizar visibilidad',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body:
          !widget.enableForIntegration
              ? const Center(
                child: Text('El servicio de personal aún no está habilitado.'),
              )
              : _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                children: [
                  if (_usingCache)
                    MaterialBanner(
                      content: Text(
                        'Sin conexión. Consulta guardada el '
                        '${_cachedAt?.toLocal()}. No confirma que una mesa siga libre; '
                        'el servidor decidirá aperturas simultáneas.',
                      ),
                      leading: const Icon(Icons.cloud_off),
                      actions: [
                        TextButton(
                          onPressed: _load,
                          child: const Text('REINTENTAR'),
                        ),
                      ],
                    ),
                  if (_pendingLateAdjustments.isNotEmpty)
                    MaterialBanner(
                      content: const Text(
                        'Hay un ajuste tardío pendiente. Reintentar recupera la misma solicitud y evita duplicar el cobro.',
                      ),
                      leading: const Icon(Icons.sync_problem),
                      actions: [
                        TextButton(
                          onPressed: _recoverLateAdjustment,
                          child: const Text('RECUPERAR AJUSTE'),
                        ),
                      ],
                    ),
                  if (_pendingCheckouts.isNotEmpty)
                    MaterialBanner(
                      content: const Text(
                        'Hay un cobro pendiente. Reintentar recupera la misma solicitud y evita duplicar la venta.',
                      ),
                      leading: const Icon(Icons.sync_problem),
                      actions: [
                        TextButton(
                          onPressed: _recoverCheckout,
                          child: const Text('RECUPERAR COBRO'),
                        ),
                      ],
                    ),
                  if (_error != null)
                    MaterialBanner(
                      content: Text(_error!),
                      leading: const Icon(Icons.error_outline),
                      actions: [
                        TextButton(
                          onPressed: _load,
                          child: const Text('REINTENTAR'),
                        ),
                      ],
                    ),
                  if (_productError != null)
                    MaterialBanner(
                      content: Text(
                        'No se pudo cargar el catálogo local: $_productError',
                      ),
                      leading: const Icon(Icons.inventory_2_outlined),
                      actions: const [],
                    ),
                  Expanded(
                    child:
                        _tables.isEmpty
                            ? const Center(
                              child: Text(
                                'No hay mesas visibles en esta consulta.',
                              ),
                            )
                            : ListView.builder(
                              padding: const EdgeInsets.all(12),
                              itemCount: _tables.length,
                              itemBuilder:
                                  (context, index) =>
                                      _buildTableCard(_tables[index]),
                            ),
                  ),
                ],
              ),
    );
  }

  Widget _buildTableCard(Map<String, dynamic> table) {
    final session = _scope;
    final serviceId = table['_pending_service_id'] ?? table['service_id'];
    final localState = table['_local_draft_state'];
    final actorId = table['service_actor_id'];
    final ownService = session != null && actorId == session.actorId;
    final foreignService = serviceId is String && !ownService;
    final free =
        serviceId == null &&
        table['_pending_service_id'] == null &&
        table['is_occupied'] == 0;
    final state = localState ?? table['service_state'];
    final conflict = state == 'conflict';
    final summary = (table['service_items'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) =>
              '${item['productName']} × ${item['quantity']}'
              '${item['late'] == true ? ' (tardío)' : ''}',
        )
        .take(4)
        .join(', ');
    final subtitle = StringBuffer();
    if (foreignService) {
      if (table['_pending_service_id'] is String) {
        subtitle.write(
          conflict
              ? 'Apertura local en conflicto · solo consulta del otro servicio'
              : 'Apertura local pendiente · servicio actual solo consulta',
        );
      } else {
        subtitle.write('Solo consulta · servicio de otro personal');
      }
    } else if (conflict) {
      subtitle.write('Conflicto pendiente de revisión');
    } else if (free) {
      subtitle.write(
        'Libre en ${_usingCache ? 'la última consulta' : 'servidor'}',
      );
    } else if (state == 'pending') {
      subtitle.write('Apertura pendiente de confirmación');
    } else {
      subtitle.write('Servicio ${state ?? 'activo'}');
    }
    if (summary.isNotEmpty) {
      if (subtitle.isNotEmpty) subtitle.write('\n');
      subtitle.write(summary);
    }
    final canOperateOwn =
        ownService &&
        !foreignService &&
        const {'pending', 'active'}.contains(state);
    final canSynchronize =
        (ownService || table['_pending_service_id'] is String) &&
        (state != 'active' || table['_has_pending_consumption'] == true) &&
        const {'pending', 'active'}.contains(state);
    final canCharge =
        _canCharge && serviceId is String && state == 'active' && !conflict;
    return Card(
      child: ListTile(
        title: Text(table['name'] as String),
        subtitle: Text(subtitle.toString()),
        isThreeLine: summary.isNotEmpty,
        trailing: Wrap(
          spacing: 4,
          children: [
            if (free && _canOpen)
              IconButton(
                tooltip: 'Iniciar servicio',
                onPressed: () => _openTable(table),
                icon: const Icon(Icons.play_arrow),
              ),
            if (canOperateOwn && _canConsume && !conflict)
              IconButton(
                tooltip: 'Anotar consumo',
                onPressed: () => _addConsumption(table),
                icon: const Icon(Icons.add_shopping_cart),
              ),
            if (canCharge)
              IconButton(
                tooltip:
                    table['_has_pending_consumption'] == true
                        ? 'Sincroniza los consumos antes de cobrar'
                        : 'Cobrar servicio',
                onPressed:
                    table['_has_pending_consumption'] == true
                        ? null
                        : () => _chargeService(table),
                icon: const Icon(Icons.point_of_sale),
              ),
            if (canSynchronize)
              IconButton(
                tooltip: 'Sincronizar pendientes',
                onPressed: () => _synchronize(table),
                icon: const Icon(Icons.sync),
              ),
          ],
        ),
      ),
    );
  }
}

class _StaffTableConflictReviewDialog extends StatefulWidget {
  const _StaffTableConflictReviewDialog({
    required this.repository,
    required this.lateAdjustmentSnapshots,
    required this.lateAdjustmentOutbox,
    required this.lateAdjustmentSender,
    required this.session,
    required this.tableType,
    required this.canCharge,
  });

  final StaffTableConflictRepository repository;
  final StaffTableLateAdjustmentSnapshotRepository lateAdjustmentSnapshots;
  final StaffTableLateAdjustmentOutbox lateAdjustmentOutbox;
  final StaffTableLateAdjustmentSender lateAdjustmentSender;
  final SyncSession session;
  final String tableType;
  final bool canCharge;

  @override
  State<_StaffTableConflictReviewDialog> createState() =>
      _StaffTableConflictReviewDialogState();
}

class _StaffTableConflictReviewDialogState
    extends State<_StaffTableConflictReviewDialog> {
  final _conflicts = <StaffTableConflict>[];
  bool _loading = false;
  bool _hasMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool nextPage = false}) async {
    if (_loading) return;
    final beforeOrdinal =
        nextPage && _conflicts.isNotEmpty ? _conflicts.last.ordinal : null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.repository.list(
        session: widget.session,
        tableType: widget.tableType,
        beforeOrdinal: beforeOrdinal,
      );
      if (!mounted) return;
      setState(() {
        _conflicts.addAll(page.items);
        _hasMore = page.hasMore;
      });
    } on StateError catch (error, stack) {
      log(
        'La sesión ya no permite consultar conflictos',
        error: error,
        stackTrace: stack,
      );
      if (mounted) setState(() => _error = error.toString());
    } on Exception catch (error, stack) {
      log(
        'No se pudieron consultar los conflictos del servicio',
        error: error,
        stackTrace: stack,
      );
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showDetails(StaffTableConflict conflict) async {
    final reviewed = await showDialog<bool>(
      context: context,
      builder:
          (context) => _StaffTableConflictDetailsDialog(
            repository: widget.repository,
            lateAdjustmentSnapshots: widget.lateAdjustmentSnapshots,
            lateAdjustmentOutbox: widget.lateAdjustmentOutbox,
            lateAdjustmentSender: widget.lateAdjustmentSender,
            session: widget.session,
            tableType: widget.tableType,
            conflict: conflict,
            canCharge: widget.canCharge,
          ),
    );
    if (reviewed == true && mounted) {
      setState(() {
        _conflicts.removeWhere((item) => item.serviceId == conflict.serviceId);
      });
    }
  }

  String _reasonLabel(String reason) =>
      reason == 'opening' ? 'Apertura rechazada' : 'Consumo tardío';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Revisión de conflictos'),
    content: SizedBox(
      width: 560,
      height: 420,
      child: Column(
        children: [
          const Text(
            'Consulta de solo lectura; no modifica ni descarta operaciones.',
          ),
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              leading: const Icon(Icons.error_outline),
              actions: [
                TextButton(
                  onPressed: () => _load(),
                  child: const Text('REINTENTAR'),
                ),
              ],
            ),
          Expanded(
            child:
                _loading && _conflicts.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : _conflicts.isEmpty
                    ? const Center(
                      child: Text('No hay conflictos pendientes de revisión.'),
                    )
                    : ListView.builder(
                      itemCount: _conflicts.length,
                      itemBuilder: (context, index) {
                        final conflict = _conflicts[index];
                        return ListTile(
                          title: Text(
                            '${_reasonLabel(conflict.reason)} · Mesa ${conflict.tableId}',
                          ),
                          subtitle: Text(
                            'Personal: ${conflict.actorId}\n'
                            'Apertura: ${conflict.openedAt.toLocal()}',
                          ),
                          isThreeLine: true,
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _showDetails(conflict),
                        );
                      },
                    ),
          ),
          if (_hasMore)
            TextButton(
              onPressed: _loading ? null : () => _load(nextPage: true),
              child: Text(_loading ? 'CARGANDO…' : 'CARGAR MÁS'),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('CERRAR'),
      ),
    ],
  );
}

class _StaffTableConflictDetailsDialog extends StatefulWidget {
  const _StaffTableConflictDetailsDialog({
    required this.repository,
    required this.lateAdjustmentSnapshots,
    required this.lateAdjustmentOutbox,
    required this.lateAdjustmentSender,
    required this.session,
    required this.tableType,
    required this.conflict,
    required this.canCharge,
  });

  final StaffTableConflictRepository repository;
  final StaffTableLateAdjustmentSnapshotRepository lateAdjustmentSnapshots;
  final StaffTableLateAdjustmentOutbox lateAdjustmentOutbox;
  final StaffTableLateAdjustmentSender lateAdjustmentSender;
  final SyncSession session;
  final String tableType;
  final StaffTableConflict conflict;
  final bool canCharge;

  @override
  State<_StaffTableConflictDetailsDialog> createState() =>
      _StaffTableConflictDetailsDialogState();
}

class _StaffTableConflictDetailsDialogState
    extends State<_StaffTableConflictDetailsDialog> {
  final _consumptions = <StaffTableConflictConsumption>[];
  bool _loading = false;
  bool _adjusting = false;
  bool _hasMore = false;
  String? _error;

  Future<void> _markOpeningReviewed() async {
    try {
      await widget.repository.reviewOpening(
        session: widget.session,
        tableType: widget.tableType,
        serviceId: widget.conflict.serviceId,
      );
      if (mounted) Navigator.pop(context, true);
    } on StateError catch (error, stack) {
      log(
        'La sesión ya no permite revisar esta apertura',
        error: error,
        stackTrace: stack,
      );
      if (mounted) setState(() => _error = error.toString());
    } on Exception catch (error, stack) {
      log(
        'No se pudo registrar la revisión de la apertura',
        error: error,
        stackTrace: stack,
      );
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _chargeLateConsumptions() async {
    if (!widget.canCharge || widget.conflict.reason != 'late_consumption') {
      return;
    }
    setState(() {
      _adjusting = true;
      _error = null;
    });
    try {
      var pending = await widget.lateAdjustmentOutbox.pendingForService(
        session: widget.session,
        serviceId: widget.conflict.serviceId,
      );
      if (pending == null) {
        final snapshot = await widget.lateAdjustmentSnapshots.read(
          session: widget.session,
          tableType: widget.tableType,
          serviceId: widget.conflict.serviceId,
        );
        if (!mounted) return;
        final payment =
            await _StaffTableConflictDetailsDialogState.selectPayment(
              context: context,
              title: 'Ajuste de consumo tardío',
              tableId: snapshot.tableId,
              total: snapshot.total,
              items: snapshot.items,
            );
        if (payment == null || !mounted) return;
        pending = await widget.lateAdjustmentOutbox.prepare(
          session: widget.session,
          snapshot: snapshot,
          paymentMethod: payment.paymentMethod,
          paid: payment.paid,
        );
      }
      final applied = await widget.lateAdjustmentSender.send(
        session: widget.session,
        request: pending,
      );
      if (applied.localSaleId == null) {
        throw StateError('El ajuste sigue pendiente de aplicarse localmente.');
      }
      if (mounted) Navigator.pop(context, true);
    } on StateError catch (error, stack) {
      log(
        'No se pudo recuperar el ajuste tardío',
        error: error,
        stackTrace: stack,
      );
      if (mounted) setState(() => _error = error.toString());
    } on PostgrestException catch (error, stack) {
      log(
        'El servidor rechazó el ajuste tardío',
        error: error,
        stackTrace: stack,
      );
      if (mounted) {
        setState(() => _error = 'No se registró el ajuste: ${error.message}');
      }
    } on Exception catch (error, stack) {
      log(
        'No se pudo registrar el ajuste tardío',
        error: error,
        stackTrace: stack,
      );
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _adjusting = false);
    }
  }

  static Future<_PaymentSelection?> selectPayment({
    required BuildContext context,
    required String title,
    required int tableId,
    required double total,
    required List<StaffTableConsumptionSnapshot> items,
    double timeCost = 0,
  }) async {
    final controller = TextEditingController(text: total.toString());
    var method = 'Efectivo';
    String? error;
    try {
      return await showDialog<_PaymentSelection>(
        context: context,
        builder:
            (dialogContext) => StatefulBuilder(
              builder:
                  (dialogContext, setDialogState) => AlertDialog(
                    title: Text(title),
                    content: SizedBox(
                      width: 480,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Mesa $tableId · ${items.length} consumos'),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 180,
                            child: ListView(
                              children: [
                                if (timeCost > 0)
                                  ListTile(
                                    dense: true,
                                    title: const Text('Tiempo de juego'),
                                    trailing: Text(
                                      '\$${timeCost.toStringAsFixed(2)}',
                                    ),
                                  ),
                                for (final item in items)
                                  ListTile(
                                    dense: true,
                                    title: Text(
                                      '${item.productName} × ${item.quantity}',
                                    ),
                                    trailing: Text(
                                      '\$${(item.quantity * item.price).toStringAsFixed(2)}',
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              'Total: \$${total.toStringAsFixed(2)}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          DropdownButton<String>(
                            value: method,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(
                                value: 'Efectivo',
                                child: Text('Efectivo'),
                              ),
                              DropdownMenuItem(
                                value: 'Tarjeta',
                                child: Text('Tarjeta'),
                              ),
                              DropdownMenuItem(
                                value: 'Transferencia',
                                child: Text('Transferencia'),
                              ),
                            ],
                            onChanged:
                                (value) => setDialogState(
                                  () => method = value ?? method,
                                ),
                          ),
                          TextField(
                            controller: controller,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Importe recibido',
                            ),
                          ),
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('CANCELAR'),
                      ),
                      FilledButton(
                        onPressed: () {
                          final paid = double.tryParse(
                            controller.text.trim().replaceAll(',', '.'),
                          );
                          if (paid == null || !paid.isFinite || paid < total) {
                            setDialogState(
                              () =>
                                  error =
                                      'El importe recibido debe cubrir el total.',
                            );
                            return;
                          }
                          Navigator.pop(dialogContext, (
                            paymentMethod: method,
                            paid: paid,
                          ));
                        },
                        child: const Text('CONFIRMAR'),
                      ),
                    ],
                  ),
            ),
      );
    } finally {
      controller.dispose();
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool nextPage = false}) async {
    if (_loading) return;
    final beforeOrdinal =
        nextPage && _consumptions.isNotEmpty
            ? _consumptions.last.ordinal
            : null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.repository.consumptions(
        session: widget.session,
        tableType: widget.tableType,
        serviceId: widget.conflict.serviceId,
        beforeOrdinal: beforeOrdinal,
      );
      if (!mounted) return;
      setState(() {
        _consumptions.addAll(page.items);
        _hasMore = page.hasMore;
      });
    } on StateError catch (error, stack) {
      log(
        'La sesión ya no permite consultar consumos del conflicto',
        error: error,
        stackTrace: stack,
      );
      if (mounted) setState(() => _error = error.toString());
    } on Exception catch (error, stack) {
      log(
        'No se pudieron consultar los consumos del conflicto',
        error: error,
        stackTrace: stack,
      );
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Mesa ${widget.conflict.tableId} · Consumos'),
    content: SizedBox(
      width: 560,
      height: 420,
      child: Column(
        children: [
          Text(
            widget.conflict.reason == 'opening'
                ? 'Marcar revisado conserva la auditoría y no ocupa ni reintenta la mesa.'
                : widget.canCharge
                ? 'El ajuste se registra como una venta separada; la venta original no cambia.'
                : 'Solo consulta. Se requiere permiso de cobro para crear un ajuste separado.',
          ),
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              leading: const Icon(Icons.error_outline),
              actions: [
                TextButton(
                  onPressed: () => _load(),
                  child: const Text('REINTENTAR'),
                ),
              ],
            ),
          Expanded(
            child:
                _loading && _consumptions.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : _consumptions.isEmpty
                    ? const Center(
                      child: Text(
                        'No hay consumos asociados a este conflicto.',
                      ),
                    )
                    : ListView.builder(
                      itemCount: _consumptions.length,
                      itemBuilder: (context, index) {
                        final item = _consumptions[index];
                        return ListTile(
                          title: Text('${item.productName} × ${item.quantity}'),
                          subtitle: Text(
                            '\$${item.price.toStringAsFixed(2)} c/u · '
                            '${item.recordedAt.toLocal()}',
                          ),
                        );
                      },
                    ),
          ),
          if (_hasMore)
            TextButton(
              onPressed: _loading ? null : () => _load(nextPage: true),
              child: Text(_loading ? 'CARGANDO…' : 'CARGAR MÁS'),
            ),
        ],
      ),
    ),
    actions: [
      if (widget.conflict.reason == 'opening')
        TextButton(
          onPressed: _loading || _adjusting ? null : _markOpeningReviewed,
          child: const Text('MARCAR REVISADO'),
        ),
      if (widget.conflict.reason == 'late_consumption' && widget.canCharge)
        FilledButton(
          onPressed: _loading || _adjusting ? null : _chargeLateConsumptions,
          child: Text(_adjusting ? 'PROCESANDO…' : 'COBRAR AJUSTE'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('CERRAR'),
      ),
    ],
  );
}
