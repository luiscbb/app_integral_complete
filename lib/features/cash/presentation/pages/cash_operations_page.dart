import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/services/business_logo_loader.dart';
import '../../../../core/services/sync_service.dart';
import '../../../reports/data/repositories/reports_repository.dart';
import '../../../reports/presentation/services/report_receipt_service.dart';
import '../../data/repositories/shared_cash_repository.dart';

class CashOperationsPage extends StatefulWidget {
  const CashOperationsPage({super.key, this.repository});
  final ReportsRepository? repository;
  @override
  State<CashOperationsPage> createState() => _CashOperationsPageState();
}

class _CashOperationsPageState extends State<CashOperationsPage>
    with WidgetsBindingObserver {
  late ReportsRepository _reportsRepo;
  StreamSubscription<AuthState>? _authChanges;
  bool _repositorySelected = false;
  bool _legacyTurn = false;
  bool _history = false;
  bool _moreSessions = false;
  bool _moreMovements = false;
  bool _pending = false;
  int _request = 0;
  List<Map<String, dynamic>> _sessions = [];
  final _today = DateTime.now();
  late DateTime _historyStart = DateTime(
    _today.year,
    _today.month,
    _today.day - 29,
  );
  late DateTime _historyEnd = DateTime(
    _today.year,
    _today.month,
    _today.day + 1,
  );
  Map<String, dynamic>? _openSession;
  Map<String, double> _cashFlow = {};
  List<String> _concepts = [];
  bool _isLoading = true;
  bool _working = false;
  Object? _error;
  List<Map<String, dynamic>> _outflows = [];

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString()), backgroundColor: Colors.red),
    );
  }

  double? _readAmount(String text, {bool positive = false}) {
    final amount = double.tryParse(text.trim());
    if (amount == null ||
        !amount.isFinite ||
        (positive ? amount <= 0 : amount < 0)) {
      _showError(
        FormatException(
          positive
              ? 'Ingresa un monto válido mayor a cero.'
              : 'Ingresa un monto válido mayor o igual a cero.',
        ),
      );
      return null;
    }
    return amount;
  }

  Future<void> _perform(
    Future<void> Function() operation, {
    bool refresh = true,
  }) async {
    if (_working) {
      _showError(StateError('Hay una operación de caja en curso.'));
      return;
    }
    setState(() => _working = true);
    try {
      await operation();
    } catch (error, stack) {
      debugPrint('[CashOperations] Error de operación: $error\n$stack');
      _showError(error);
    } finally {
      if (mounted) setState(() => _working = false);
      if (mounted && refresh && _reportsRepo is SharedCashRepository) {
        await _load();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _reportsRepo = widget.repository ?? ReportsRepository();
    _repositorySelected = widget.repository != null;
    if (widget.repository == null) {
      WidgetsBinding.instance.addObserver(this);
      _authChanges = Supabase.instance.client.auth.onAuthStateChange.listen((
        _,
      ) {
        unawaited(_load());
      });
    }
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    await _load();
    if (_reportsRepo is! SharedCashRepository) {
      await SyncService().pullOutflowsFromCloud();
      if (mounted) await _load();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final request = ++_request;
    setState(() {
      _isLoading = true;
      _error = null;
      _openSession = null;
      _cashFlow = {};
      _outflows = [];
      _sessions = [];
    });
    try {
      if (!_repositorySelected) {
        final legacy = ReportsRepository();
        _legacyTurn = await legacy.getOpenSession() != null;
        _reportsRepo = _legacyTurn ? legacy : SharedCashRepository();
        _repositorySelected = true;
      }
      if (_reportsRepo case final SharedCashRepository shared) {
        final pending = await shared.pending() != null;
        if (mounted && request == _request) setState(() => _pending = pending);
        final now = DateTime.now();
        final result = await shared.state(
          _history ? _historyStart : DateTime(now.year, now.month, now.day),
          _history ? _historyEnd : DateTime(now.year, now.month, now.day + 1),
        );
        final concepts = await shared.getConcepts();
        if (!mounted || request != _request) return;
        setState(() {
          _openSession = result['session'] as Map<String, dynamic>?;
          _cashFlow = result['summary'] as Map<String, double>;
          _outflows = result['movements'] as List<Map<String, dynamic>>;
          _sessions = result['sessions'] as List<Map<String, dynamic>>;
          _moreSessions = result['more_sessions'] as bool;
          _moreMovements = result['more_movements'] as bool;
          _pending = pending;
          _concepts = concepts;
        });
        return;
      }
      final session = await _reportsRepo.getOpenSession();
      final concepts = await _reportsRepo.getConcepts();
      final outflows = await _reportsRepo.getCashOutflows(
        DateTime.now(),
        DateTime.now(),
      );
      final summary =
          session == null
              ? <String, double>{}
              : await _reportsRepo.getSessionCashFlowSummary(session);
      if (!mounted || request != _request) return;
      setState(() {
        _openSession = session;
        _concepts = concepts;
        _cashFlow = summary;
        _outflows = outflows;
      });
    } catch (error, stack) {
      debugPrint('[CashOperations] Error cargando caja: $error\n$stack');
      if (mounted && request == _request) setState(() => _error = error);
    } finally {
      if (mounted && request == _request) setState(() => _isLoading = false);
    }
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
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: const Text('CAJA Y TURNOS'),
        actions: [
          if (_reportsRepo is SharedCashRepository)
            IconButton(
              tooltip: _history ? 'Volver a operaciones' : 'Historial de caja',
              onPressed:
                  _working
                      ? null
                      : () {
                        setState(() => _history = !_history);
                        unawaited(_load());
                      },
              icon: Icon(_history ? Icons.point_of_sale : Icons.history),
            ),
          IconButton(
            tooltip: 'Actualizar caja',
            onPressed: _working ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('No se pudo cargar caja: $_error'),
                    TextButton(
                      onPressed: _load,
                      child: const Text('REINTENTAR'),
                    ),
                    if (_pending && _reportsRepo is SharedCashRepository)
                      TextButton(
                        onPressed:
                            _working
                                ? null
                                : () => _perform(
                                  () => (_reportsRepo as SharedCashRepository)
                                      .resolvePending(cancel: true),
                                ),
                        child: const Text(
                          'RESOLVER SOLICITUD PENDIENTE SIN REPETIRLA',
                        ),
                      ),
                  ],
                ),
              )
              : _history
              ? _buildHistory()
              : _buildOperations(primary),
    );
  }

  Future<void> _addOutflow({bool contribution = false}) async {
    final targetSession = _openSession;
    if (targetSession == null) {
      _showError(StateError('Actualiza caja: no hay un turno abierto.'));
      return;
    }
    final prefs = PreferencesService();
    var paymentMethod = 'Efectivo';
    var kind = contribution ? 'contribution' : 'expense';
    String type = _concepts.isNotEmpty ? _concepts.first : 'GASTO';
    final descCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    final route = DialogRoute<void>(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, updateDialog) => AlertDialog(
                  backgroundColor: const Color(0xFF1A1A1A),
                  title: Text(
                    contribution
                        ? 'REGISTRAR APORTE MANUAL'
                        : 'REGISTRAR RETIRO / GASTO',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (contribution)
                        const Text(
                          'Aumenta el efectivo; no es venta ni utilidad.',
                        ),
                      if (!contribution && _reportsRepo is SharedCashRepository)
                        DropdownButtonFormField<String>(
                          initialValue: kind,
                          decoration: const InputDecoration(
                            labelText: 'Clasificación',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'expense',
                              child: Text('Gasto del negocio'),
                            ),
                            DropdownMenuItem(
                              value: 'withdrawal',
                              child: Text('Retiro (no afecta utilidad)'),
                            ),
                          ],
                          onChanged:
                              (value) => updateDialog(() {
                                kind = value!;
                                paymentMethod = 'Efectivo';
                              }),
                        ),
                      if (!contribution)
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue: type,
                                dropdownColor: const Color(0xFF1A1A1A),
                                style: const TextStyle(color: Colors.white),
                                decoration: const InputDecoration(
                                  labelText: 'Concepto',
                                  labelStyle: TextStyle(color: Colors.white38),
                                ),
                                items: [
                                  if (_concepts.isEmpty)
                                    const DropdownMenuItem(
                                      value: 'GASTO',
                                      child: Text('GASTO'),
                                    ),
                                  ..._concepts.map(
                                    (c) => DropdownMenuItem(
                                      value: c,
                                      child: Text(c),
                                    ),
                                  ),
                                ],
                                onChanged: (v) => type = v!,
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.add_circle,
                                color: Theme.of(ctx).colorScheme.primary,
                              ),
                              tooltip: 'Agregar concepto',
                              onPressed: () async {
                                await _showAddConceptDialog(ctx);
                                await _reloadConceptsOnly();
                                if (ctx.mounted && _concepts.isNotEmpty) {
                                  type = _concepts.first;
                                }
                              },
                            ),
                          ],
                        ),
                      TextField(
                        controller: amountCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Monto',
                          labelStyle: TextStyle(color: Colors.white38),
                        ),
                      ),
                      TextField(
                        controller: descCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Descripción (opcional)',
                          labelStyle: TextStyle(color: Colors.white38),
                        ),
                      ),
                      DropdownButtonFormField<String>(
                        key: ValueKey(kind),
                        initialValue: paymentMethod,
                        decoration: const InputDecoration(
                          labelText: 'Forma de pago',
                        ),
                        items: [
                          for (final method
                              in kind == 'expense'
                                  ? ['Efectivo', 'Tarjeta', 'Transferencia']
                                  : ['Efectivo'])
                            DropdownMenuItem(
                              value: method,
                              child: Text(method),
                            ),
                        ],
                        onChanged: (value) => paymentMethod = value!,
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text(
                        'Cancelar',
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () async {
                        final amount = _readAmount(
                          amountCtrl.text,
                          positive: true,
                        );
                        if (amount == null) return;
                        if (type.isEmpty) {
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(
                                content: Text('Selecciona un concepto'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                          return;
                        }
                        final description = descCtrl.text.trim();
                        await _perform(() async {
                          final repository = _reportsRepo;
                          final outflowId =
                              repository is SharedCashRepository
                                  ? await repository.addMovement(
                                    sessionId: targetSession['id'] as int,
                                    kind: kind,
                                    amount: amount,
                                    description:
                                        contribution
                                            ? (description.isEmpty
                                                ? 'Aporte manual'
                                                : description)
                                            : '$type${description.isEmpty ? '' : ': $description'}',
                                    paymentMethod: paymentMethod,
                                  )
                                  : await repository.addCashOutflow(
                                    outflowType: type,
                                    amount: amount,
                                    description: description,
                                    paymentMethod: paymentMethod,
                                    createdBy: prefs.userName,
                                  );
                          // Disparar subida inmediata del retiro a Supabase (mismo
                          // patrón que ventas: sin esto el retiro queda local hasta
                          // el próximo ciclo automático y el otro dispositivo no lo ve).
                          SyncService().schedulePendingSync();
                          if (ctx.mounted) Navigator.pop(ctx);
                          await _load();
                          if (mounted) {
                            await showReportReceipt(
                              context,
                              title:
                                  '${contribution
                                      ? 'APORTE MANUAL'
                                      : kind == 'withdrawal'
                                      ? 'RETIRO'
                                      : 'GASTO'} #$outflowId',
                              subtitle:
                                  contribution
                                      ? 'No es ingreso por venta'
                                      : 'Concepto: $type',
                              bodyLines: [
                                'Monto: ${formatReportMoney(amount)}',
                                if (description.isNotEmpty)
                                  'Descripción: $description',
                                'Forma de pago: $paymentMethod',
                                'Registrado por: ${prefs.userName}',
                              ],
                              boldLabel: 'Total en caja',
                              boldAmount: _currentCashTotal(),
                            );
                          }
                        });
                      },
                      child: const Text(
                        'GUARDAR',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
          ),
    );
    try {
      await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
    } finally {
      descCtrl.dispose();
      amountCtrl.dispose();
    }
  }

  Future<void> _reloadConceptsOnly() async {
    final concepts = await _reportsRepo.getConcepts();
    if (mounted) setState(() => _concepts = concepts);
  }

  Future<void> _showAddConceptDialog(BuildContext parentCtx) async {
    final ctrl = TextEditingController();
    await showDialog(
      context: parentCtx,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text(
              'NUEVO CONCEPTO',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Nombre del concepto',
                labelStyle: TextStyle(color: Colors.white38),
              ),
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (oldValue, newValue) =>
                      newValue.copyWith(text: newValue.text.toUpperCase()),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  'Cancelar',
                  style: TextStyle(color: Colors.white38),
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  final name = ctrl.text.trim();
                  if (name.isNotEmpty) {
                    await _reportsRepo.addConcept(name);
                    if (ctx.mounted) Navigator.pop(ctx);
                  }
                },
                child: const Text(
                  'CREAR',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
    );
  }

  Future<void> _showConceptManager() async {
    await _reloadConceptsOnly();
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder:
              (ctx, setSheetState) => DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.8,
                maxChildSize: 0.95,
                builder:
                    (_, ctrl) => Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: const BoxDecoration(
                            color: Color(0xFF1A1A1A),
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(24),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Text(
                                'CONCEPTOS DE RETIRO / GASTO',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: Icon(
                                  Icons.add,
                                  color: Theme.of(ctx).colorScheme.primary,
                                ),
                                tooltip: 'Agregar concepto',
                                onPressed: () async {
                                  await _showAddConceptDialog(ctx);
                                  final concepts =
                                      await _reportsRepo.getConcepts();
                                  setSheetState(() => _concepts = concepts);
                                },
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.white54,
                                ),
                                onPressed: () => Navigator.pop(ctx),
                              ),
                            ],
                          ),
                        ),
                        const Divider(color: Colors.white10, height: 1),
                        Expanded(
                          child:
                              _concepts.isEmpty
                                  ? const Center(
                                    child: Text(
                                      'Sin conceptos. Agrega uno con el +',
                                      style: TextStyle(color: Colors.white24),
                                    ),
                                  )
                                  : ListView.builder(
                                    controller: ctrl,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    itemCount: _concepts.length,
                                    itemBuilder: (_, i) {
                                      final c = _concepts[i];
                                      return ListTile(
                                        leading: const Icon(
                                          Icons.label,
                                          color: Colors.orangeAccent,
                                        ),
                                        title: Text(
                                          c,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              icon: const Icon(
                                                Icons.edit,
                                                color: Colors.white54,
                                              ),
                                              tooltip: 'Renombrar',
                                              onPressed: () async {
                                                await _showRenameConceptDialog(
                                                  ctx,
                                                  c,
                                                );
                                                final concepts =
                                                    await _reportsRepo
                                                        .getConcepts();
                                                setSheetState(
                                                  () => _concepts = concepts,
                                                );
                                              },
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.delete,
                                                color: Colors.redAccent,
                                              ),
                                              tooltip: 'Eliminar',
                                              onPressed: () async {
                                                final ok = await showDialog<
                                                  bool
                                                >(
                                                  context: ctx,
                                                  builder:
                                                      (dctx) => AlertDialog(
                                                        backgroundColor:
                                                            const Color(
                                                              0xFF1A1A1A,
                                                            ),
                                                        title: const Text(
                                                          'ELIMINAR CONCEPTO',
                                                          style: TextStyle(
                                                            color: Colors.white,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            fontSize: 15,
                                                          ),
                                                        ),
                                                        content: Text(
                                                          '¿Eliminar "$c"?',
                                                          style: const TextStyle(
                                                            color:
                                                                Colors.white70,
                                                          ),
                                                        ),
                                                        actions: [
                                                          TextButton(
                                                            onPressed:
                                                                () =>
                                                                    Navigator.pop(
                                                                      dctx,
                                                                      false,
                                                                    ),
                                                            child: const Text(
                                                              'Cancelar',
                                                              style: TextStyle(
                                                                color:
                                                                    Colors
                                                                        .white38,
                                                              ),
                                                            ),
                                                          ),
                                                          ElevatedButton(
                                                            onPressed:
                                                                () =>
                                                                    Navigator.pop(
                                                                      dctx,
                                                                      true,
                                                                    ),
                                                            child: const Text(
                                                              'ELIMINAR',
                                                              style: TextStyle(
                                                                color:
                                                                    Colors
                                                                        .white,
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                );
                                                if (ok == true) {
                                                  await _reportsRepo
                                                      .deleteConcept(c);
                                                  final concepts =
                                                      await _reportsRepo
                                                          .getConcepts();
                                                  setSheetState(
                                                    () => _concepts = concepts,
                                                  );
                                                }
                                              },
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                        ),
                      ],
                    ),
              ),
        );
      },
    );
  }

  Future<void> _showRenameConceptDialog(
    BuildContext parentCtx,
    String current,
  ) async {
    final ctrl = TextEditingController(text: current);
    await showDialog(
      context: parentCtx,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text(
              'RENOMBRAR CONCEPTO',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Nuevo nombre',
                labelStyle: TextStyle(color: Colors.white38),
              ),
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (oldValue, newValue) =>
                      newValue.copyWith(text: newValue.text.toUpperCase()),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  'Cancelar',
                  style: TextStyle(color: Colors.white38),
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  final name = ctrl.text.trim();
                  if (name.isNotEmpty) {
                    await _reportsRepo.renameConcept(current, name);
                    if (ctx.mounted) Navigator.pop(ctx);
                  }
                },
                child: const Text(
                  'GUARDAR',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
    );
  }

  Future<void> _openTurn() async {
    final prefs = PreferencesService();
    final nameCtrl = TextEditingController(text: prefs.userName);
    final amountCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text(
              'ABRIR TURNO',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Cajero (quien abre)',
                    labelStyle: TextStyle(color: Colors.white38),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Monto inicial en caja',
                    labelStyle: TextStyle(color: Colors.white38),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  'Cancelar',
                  style: TextStyle(color: Colors.white38),
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  final amount = _readAmount(amountCtrl.text);
                  if (amount != null) {
                    await _perform(() async {
                      final cashier =
                          nameCtrl.text.trim().isEmpty
                              ? prefs.userName
                              : nameCtrl.text.trim();
                      await _reportsRepo.openSession(
                        openingAmount: amount,
                        createdBy: cashier,
                      );
                      if (ctx.mounted) Navigator.pop(ctx);
                      await _load();
                      if (mounted) {
                        await showReportReceipt(
                          context,
                          title: 'COMPROBANTE DE APERTURA',
                          subtitle: 'Cajero que abre: $cashier',
                          bodyLines: [
                            'Monto inicial en caja: ${formatReportMoney(amount)}',
                          ],
                          boldLabel: 'Total en caja',
                          boldAmount: _currentCashTotal(),
                        );
                      }
                    });
                  }
                },
                child: const Text(
                  'ABRIR',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
    );
  }

  Future<void> _partialCutoff() async {
    final targetSession = _openSession;
    final amountCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text(
              'CORTE PARCIAL',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Monto retirado',
                    labelStyle: TextStyle(color: Colors.white38),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Notas (opcional)',
                    labelStyle: TextStyle(color: Colors.white38),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  'Cancelar',
                  style: TextStyle(color: Colors.white38),
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  final amount = _readAmount(amountCtrl.text, positive: true);
                  if (amount != null) {
                    await _perform(() async {
                      await _reportsRepo.addPartialClosure(
                        amount: amount,
                        notes: notesCtrl.text.trim(),
                        createdBy: PreferencesService().userName,
                        sessionId: targetSession?['id'] as int?,
                      );
                      SyncService().schedulePendingSync();
                      if (ctx.mounted) Navigator.pop(ctx);
                      await _load();
                      if (mounted) {
                        final session = _openSession;
                        if (session == null) {
                          throw StateError('El turno cambió. Actualiza caja.');
                        }
                        final summary = await _reportsRepo
                            .getSessionCashFlowSummary(session);
                        await _showCutoffPdf(
                          openingAmount:
                              (session['opening_amount'] as num?)?.toDouble() ??
                              0,
                          openedBy: (session['created_by'] ?? '').toString(),
                          closingAmount: amount,
                          closedBy: '',
                          summary: summary,
                          isPartial: true,
                        );
                      }
                    });
                  }
                },
                child: const Text(
                  'GUARDAR',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
    );
  }

  Future<void> _totalCutoff() async {
    final session = _openSession;
    if (session == null) {
      _showError(StateError('No hay un turno abierto.'));
      return;
    }
    final prefs = PreferencesService();
    final closedByCtrl = TextEditingController(text: prefs.userName);
    final closingCtrl = TextEditingController();
    final nextOpeningCtrl = TextEditingController();
    var reopen = false;
    var syncedConfirmed = false;
    final route = DialogRoute<void>(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, updateDialog) => AlertDialog(
                  backgroundColor: const Color(0xFF1A1A1A),
                  title: const Text(
                    'CORTE TOTAL',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Abrió: ${session['created_by'] ?? '?'}  con  ${formatReportMoney(((session['opening_amount'] as num?) ?? 0).toDouble())}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          'Efectivo esperado: ${formatReportMoney(_currentCashTotal())}',
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: closedByCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: 'Cajero que cierra',
                            labelStyle: TextStyle(color: Colors.white38),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: closingCtrl,
                          onChanged: (_) => updateDialog(() {}),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: 'Efectivo contado',
                            labelStyle: TextStyle(color: Colors.white38),
                          ),
                        ),
                        if (double.tryParse(closingCtrl.text)?.isFinite == true)
                          Text(
                            'Diferencia: ${formatReportMoney(double.parse(closingCtrl.text) - _currentCashTotal())}',
                          ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Cerrar y abrir nuevo turno'),
                          value: reopen,
                          onChanged:
                              _legacyTurn
                                  ? null
                                  : (value) => updateDialog(
                                    () => reopen = value == true,
                                  ),
                        ),
                        if (_reportsRepo is SharedCashRepository)
                          CheckboxListTile(
                            title: const Text(
                              'Confirmé que TODOS los teléfonos están sincronizados',
                            ),
                            subtitle: const Text(
                              'El corte conserva lo recibido por el servidor. '
                              'Operaciones tardías se marcarán para conciliación.',
                            ),
                            value: syncedConfirmed,
                            onChanged:
                                (value) => updateDialog(
                                  () => syncedConfirmed = value == true,
                                ),
                          ),
                        if (reopen)
                          TextField(
                            controller: nextOpeningCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Fondo inicial del nuevo turno',
                            ),
                          ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text(
                        'Cancelar',
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                    ElevatedButton(
                      onPressed:
                          _reportsRepo is SharedCashRepository &&
                                  !syncedConfirmed
                              ? null
                              : () async {
                                final closing = _readAmount(closingCtrl.text);
                                if (closing == null) return;
                                final nextOpening =
                                    reopen
                                        ? _readAmount(nextOpeningCtrl.text)
                                        : null;
                                if (reopen && nextOpening == null) return;
                                final closedBy =
                                    closedByCtrl.text.trim().isEmpty
                                        ? prefs.userName
                                        : closedByCtrl.text.trim();
                                await _perform(() async {
                                  final summary = await _reportsRepo
                                      .closeSession(
                                        closingAmount: closing,
                                        closedBy: closedBy,
                                        sessionId: session['id'] as int,
                                        nextOpeningAmount: nextOpening,
                                        nextCreatedBy: closedBy,
                                      );
                                  if (_legacyTurn) _repositorySelected = false;
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  await _load();
                                  if (mounted) {
                                    await _showCutoffPdf(
                                      openingAmount:
                                          (session['opening_amount'] as num?)
                                              ?.toDouble() ??
                                          0,
                                      openedBy:
                                          (session['created_by'] ?? '')
                                              .toString(),
                                      closingAmount: closing,
                                      closedBy: closedBy,
                                      summary: summary,
                                      isPartial: false,
                                      nextOpeningAmount: nextOpening,
                                    );
                                  }
                                });
                              },
                      child: const Text(
                        'CERRAR TURNO',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
          ),
    );
    try {
      await Navigator.of(context, rootNavigator: true).push(route);
      // The fields remain mounted during the dialog's closing transition.
      await route.completed;
    } finally {
      closedByCtrl.dispose();
      closingCtrl.dispose();
      nextOpeningCtrl.dispose();
    }
  }

  Future<void> _showCutoffPdf({
    required double openingAmount,
    required String openedBy,
    required double closingAmount,
    required String closedBy,
    required Map<String, double> summary,
    required bool isPartial,
    double? nextOpeningAmount,
    String? reprintLabel,
    DateTime? receiptDate,
  }) async {
    final prefs = PreferencesService();
    final businessName =
        prefs.businessName.trim().isEmpty
            ? 'MI NEGOCIO'
            : prefs.businessName.trim();
    final primaryColor = PdfColor.fromInt(prefs.primaryColorValue);

    pw.MemoryImage? logoImage;
    final logoBytes = await _loadLogoBytes();
    if (logoBytes != null) {
      logoImage = pw.MemoryImage(logoBytes);
    }

    final pdf = pw.Document();
    final now = receiptDate ?? DateTime.now();
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}  ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final titleStyle = pw.TextStyle(
      fontWeight: pw.FontWeight.bold,
      fontSize: 12,
      color: PdfColors.black,
      letterSpacing: 1,
    );
    final normalStyle = pw.TextStyle(fontSize: 9.5, color: PdfColors.black);
    final boldStyle = pw.TextStyle(
      fontWeight: pw.FontWeight.bold,
      fontSize: 10,
      color: PdfColors.black,
    );
    final smallStyle = pw.TextStyle(fontSize: 8, color: PdfColors.grey700);

    final sales = summary['sales'] ?? 0;
    final purchases = summary['purchases'] ?? 0;
    final outflows = summary['outflows'] ?? 0;
    final net = summary['netCash'] ?? 0;
    final expected = openingAmount + net;
    final difference = closingAmount - expected;

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        build: (pw.Context ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.SizedBox(height: 4),
              if (logoImage != null) ...[
                pw.Center(child: pw.Image(logoImage, width: 56, height: 56)),
                pw.SizedBox(height: 4),
              ],
              pw.Center(
                child: pw.Text(businessName.toUpperCase(), style: titleStyle),
              ),
              pw.SizedBox(height: 2),
              pw.Center(
                child: pw.Text(
                  isPartial ? 'CORTE PARCIAL DE CAJA' : 'CORTE TOTAL DE CAJA',
                  style: boldStyle,
                ),
              ),
              if (reprintLabel != null)
                pw.Text('REIMPRESIÓN · $reprintLabel', style: boldStyle),
              pw.SizedBox(height: 2),
              pw.Center(child: pw.Text(dateStr, style: smallStyle)),
              pw.SizedBox(height: 2),
              pw.Divider(color: primaryColor, thickness: 0.8),
              pw.Text('Abrió: $openedBy', style: normalStyle),
              pw.Text(
                'Monto inicial: ${formatReportMoney(openingAmount)}',
                style: normalStyle,
              ),
              if (!isPartial) ...[
                pw.SizedBox(height: 2),
                pw.Text('Cerró: $closedBy', style: normalStyle),
              ],
              pw.Divider(color: primaryColor, thickness: 0.8),
              pw.Text(
                'Ventas: ${formatReportMoney(sales)}',
                style: normalStyle,
              ),
              if (summary['inflows'] case final inflows?)
                pw.Text(
                  'Aportes manuales: ${formatReportMoney(inflows)}',
                  style: normalStyle,
                ),
              pw.Text(
                'Compras (caja): ${formatReportMoney(purchases)}',
                style: normalStyle,
              ),
              pw.Text(
                'Retiros/Gastos: ${formatReportMoney(outflows)}',
                style: normalStyle,
              ),
              pw.SizedBox(height: 2),
              pw.Divider(color: primaryColor, thickness: 0.8),
              pw.Text(
                'Total en caja: ${formatReportMoney(expected)}',
                style: boldStyle,
              ),
              pw.SizedBox(height: 2),
              pw.Divider(color: primaryColor, thickness: 0.8),
              if (isPartial) ...[
                pw.Text(
                  'Retiro parcial: ${formatReportMoney(closingAmount)}',
                  style: boldStyle,
                ),
              ] else ...[
                pw.Text(
                  'Efectivo esperado: ${formatReportMoney(expected)}',
                  style: boldStyle,
                ),
                pw.Text(
                  'Efectivo contado: ${formatReportMoney(closingAmount)}',
                  style: normalStyle,
                ),
                pw.Text(
                  'Diferencia: ${formatReportMoney(difference)}',
                  style: boldStyle,
                ),
                if (nextOpeningAmount != null)
                  pw.Text(
                    'Nuevo turno: fondo ${formatReportMoney(nextOpeningAmount)}',
                    style: normalStyle,
                  ),
              ],
              pw.SizedBox(height: 10),
              pw.Center(
                child: pw.Text(
                  'Documento interno / control de caja',
                  style: const pw.TextStyle(fontSize: 7),
                ),
              ),
            ],
          );
        },
      ),
    );

    final bytes = await pdf.save();
    if (!mounted) return;

    await showReportPdfPreview(
      context,
      bytes,
      isPartial ? 'CORTE PARCIAL' : 'CORTE TOTAL',
      'corte_${now.millisecondsSinceEpoch}.pdf',
    );
  }

  Future<Uint8List?> _loadLogoBytes() => loadBusinessLogo(PreferencesService());

  double _currentCashTotal() {
    final net = _cashFlow['netCash'] ?? 0;
    final opening = (_openSession?['opening_amount'] as num?)?.toDouble() ?? 0;
    return opening + net;
  }

  Widget _buildOperations(Color primary) {
    final session = _openSession;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_legacyTurn)
            const Text(
              'TURNO LOCAL ANTERIOR: ciérralo para pasar a caja compartida. '
              'No se importará ni duplicará automáticamente.',
            ),
          if (_reportsRepo is SharedCashRepository) ...[
            const Text(
              'Caja única compartida · requiere conexión · solo operaciones sincronizadas. '
              'Los turnos y movimientos locales antiguos se conservan aparte.',
            ),
            if (_pending) ...[
              const Text(
                'Hay una solicitud sin confirmar. No repitas el registro. '
                'Cancelar no revierte una operación ya aplicada.',
              ),
              Wrap(
                children: [
                  TextButton(
                    onPressed:
                        _working
                            ? null
                            : () => _perform(
                              () => (_reportsRepo as SharedCashRepository)
                                  .resolvePending(cancel: false),
                            ),
                    child: const Text('REINTENTAR PENDIENTE'),
                  ),
                  TextButton(
                    onPressed:
                        _working
                            ? null
                            : () => _perform(
                              () => (_reportsRepo as SharedCashRepository)
                                  .resolvePending(cancel: true),
                            ),
                    child: const Text('RESOLVER / CANCELAR PENDIENTE'),
                  ),
                ],
              ),
            ],
            ElevatedButton.icon(
              onPressed:
                  _working || session == null || _pending
                      ? null
                      : () => _addOutflow(contribution: true),
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('REGISTRAR APORTE MANUAL'),
            ),
          ],
          _TurnInfoRow(
            icon: Icons.payments,
            label: 'Efectivo esperado del turno',
            value: formatReportMoney(_currentCashTotal()),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: const Icon(Icons.money_off, color: Colors.white),
            label: const Text(
              'REGISTRAR RETIRO / GASTO',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            onPressed: _working || session == null ? null : _addOutflow,
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2A2A2A),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: Icon(Icons.category, color: Colors.orangeAccent),
            label: const Text(
              'CONCEPTOS (catalogo)',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            onPressed: _working ? null : _showConceptManager,
          ),
          const Divider(color: Colors.white10, height: 32),
          // ── Sección de TURNO / CORTE DE CAJA ──
          if (session == null) ...[
            Text(
              'SIN TURNO ABIERTO',
              style: TextStyle(
                color: primary,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: primary,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.play_circle, color: Colors.white),
              label: const Text(
                'ABRIR TURNO',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onPressed: _working ? null : _openTurn,
            ),
          ] else ...[
            Text(
              'TURNO ABIERTO',
              style: TextStyle(
                color: Colors.greenAccent,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            _TurnInfoRow(
              icon: Icons.person,
              label: 'Abrió',
              value: (session['created_by'] ?? '?').toString(),
            ),
            _TurnInfoRow(
              icon: Icons.payments,
              label: 'Monto inicial',
              value: formatReportMoney(
                ((session['opening_amount'] as num?) ?? 0).toDouble(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orangeAccent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(
                      Icons.content_cut,
                      color: Colors.white,
                      size: 18,
                    ),
                    label: const Text(
                      'CORTE PARCIAL',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    onPressed: _working ? null : _partialCutoff,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(
                      Icons.stop_circle,
                      color: Colors.white,
                      size: 18,
                    ),
                    label: const Text(
                      'CORTE TOTAL',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    onPressed: _working ? null : _totalCutoff,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'El corte de caja permite registrar quién abre y quién cierra la caja, y cuánto dinero se entrega entre turnos.',
            style: const TextStyle(color: Colors.white24, fontSize: 11),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          const Text('MOVIMIENTOS DE HOY'),
          if (_moreMovements)
            const Text(
              'Se muestran los últimos 50. Abre Historial para consultar los demás.',
            ),
          for (final movement in _outflows)
            ListTile(
              title: Text(
                '${movement['outflow_type']} · ${formatReportMoney((movement['amount'] as num).toDouble())}',
              ),
              subtitle: Text(
                '${movement['created_at']} · ${movement['payment_method']}',
              ),
              trailing: IconButton(
                tooltip: 'Reimprimir comprobante',
                icon: const Icon(Icons.receipt_long),
                onPressed:
                    _working
                        ? null
                        : () => _perform(
                          () => showReportReceipt(
                            context,
                            title:
                                'REIMPRESIÓN · MOVIMIENTO #${movement['id']}',
                            subtitle: 'Concepto: ${movement['outflow_type']}',
                            bodyLines: [
                              'Registrado: ${movement['created_at']}',
                              'Forma de pago: ${movement['payment_method']}',
                              'Registrado por: ${movement['created_by']}',
                              if ((movement['description'] as String?)
                                      ?.isNotEmpty ==
                                  true)
                                'Descripción: ${movement['description']}',
                            ],
                            boldLabel: 'Monto del movimiento',
                            boldAmount: (movement['amount'] as num).toDouble(),
                          ),
                        ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _moreHistory({required bool sessions}) async {
    await _perform(() async {
      final repository = _reportsRepo;
      if (repository is! SharedCashRepository) {
        throw StateError('Caja no compartida.');
      }
      final result = await repository.state(
        _historyStart,
        _historyEnd,
        beforeSession: sessions ? _sessions.last['id'] as int : null,
        beforeMovement: sessions ? null : _outflows.last['id'] as int,
      );
      if (!mounted) return;
      setState(() {
        if (sessions) {
          _sessions.addAll(result['sessions'] as List<Map<String, dynamic>>);
          _moreSessions = result['more_sessions'] as bool;
        } else {
          _outflows.addAll(result['movements'] as List<Map<String, dynamic>>);
          _moreMovements = result['more_movements'] as bool;
        }
      });
    }, refresh: false);
  }

  Widget _buildHistory() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'TURNOS COMPARTIDOS · no incluye los turnos locales anteriores',
      ),
      for (final session in _sessions)
        ListTile(
          onTap:
              _working || session['closed_at'] == null
                  ? null
                  : () => _perform(
                    () => _showCutoffPdf(
                      openingAmount:
                          (session['opening_amount'] as num).toDouble(),
                      openedBy: session['opened_by'] as String,
                      closingAmount:
                          (session['closing_amount'] as num).toDouble(),
                      closedBy: session['closed_by'] as String,
                      summary:
                          session['closing_summary'] as Map<String, double>,
                      isPartial: false,
                      reprintLabel: 'TURNO #${session['id']}',
                      receiptDate:
                          DateTime.parse(
                            session['closed_at'] as String,
                          ).toLocal(),
                    ),
                    refresh: false,
                  ),
          title: Text(
            'Turno #${session['id']} · ${session['closed_at'] == null ? 'ABIERTO' : 'CERRADO'}',
          ),
          subtitle: Text(
            '${session['opened_at']}\nAbrió: ${session['opened_by']}\n'
            '${session['closed_at'] == null ? '' : 'Cerró: ${session['closed_by']} · ${session['closed_at']}'}'
            '${session['closed_at'] == null ? '' : '\nContado: ${formatReportMoney((session['closing_amount'] as num).toDouble())} · Esperado: ${formatReportMoney((session['expected_amount'] as num).toDouble())}\nToca para reimprimir.'}'
            '${session['needs_reconciliation'] == true ? '\nREQUIERE CONCILIACIÓN: cambiaron operaciones después del corte.' : ''}',
          ),
          trailing:
              session['closed_at'] == null
                  ? null
                  : Text(
                    'Diferencia: ${formatReportMoney((session['difference'] as num).toDouble())}',
                  ),
        ),
      if (_moreSessions)
        TextButton(
          onPressed: _working ? null : () => _moreHistory(sessions: true),
          child: const Text('MÁS TURNOS'),
        ),
      const Divider(),
      const Text('MOVIMIENTOS COMPARTIDOS'),
      TextButton.icon(
        icon: const Icon(Icons.date_range),
        label: Text(
          '${_historyStart.toLocal()} — ${_historyEnd.subtract(const Duration(days: 1)).toLocal()}',
        ),
        onPressed:
            _working
                ? null
                : () async {
                  final range = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                    initialDateRange: DateTimeRange(
                      start: _historyStart,
                      end: _historyEnd.subtract(const Duration(days: 1)),
                    ),
                  );
                  if (range == null || !mounted) return;
                  setState(() {
                    _historyStart = range.start;
                    _historyEnd = DateTime(
                      range.end.year,
                      range.end.month,
                      range.end.day + 1,
                    );
                  });
                  await _load();
                },
      ),
      for (final movement in _outflows)
        ListTile(
          title: Text(
            '${movement['outflow_type']} · ${formatReportMoney((movement['amount'] as num).toDouble())}',
          ),
          subtitle: Text(
            '${movement['created_at']} · turno #${movement['session_id']}\n${movement['description']}',
          ),
        ),
      if (_moreMovements)
        TextButton(
          onPressed: _working ? null : () => _moreHistory(sessions: false),
          child: const Text('MÁS MOVIMIENTOS'),
        ),
    ],
  );
}

class _TurnInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _TurnInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: Colors.white54, size: 18),
          const SizedBox(width: 8),
          Text(
            '$label:',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
