import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import '../../../../core/storage/account_storage.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../auth/domain/staff_access.dart';
import '../../data/repositories/staff_report_repository.dart';
import '../services/report_receipt_service.dart';

class StaffReportsPage extends StatefulWidget {
  const StaffReportsPage({
    super.key,
    this.enableForIntegration = false,
    this.allowedReports = const {StaffModule.reportsPurchases},
  });

  final bool enableForIntegration;
  final Set<StaffModule> allowedReports;

  @override
  State<StaffReportsPage> createState() => _StaffReportsPageState();
}

class _StaffReportsPageState extends State<StaffReportsPage>
    with WidgetsBindingObserver {
  StreamSubscription<AuthState>? _authChanges;
  SyncSession? _scope;
  StaffReport? _report;
  List<StaffReportItem> _items = [];
  StaffModule? _selectedReport;
  String? _error;
  bool _loading = false;
  int _request = 0;
  final _today = DateTime.now();
  late DateTime _start = DateTime(_today.year, _today.month, _today.day - 29);
  late DateTime _end = DateTime(_today.year, _today.month, _today.day + 1);

  @override
  void initState() {
    super.initState();
    _selectedReport =
        StaffModule.values
            .where(
              (module) =>
                  module.parent == StaffModule.reports &&
                  widget.allowedReports.contains(module),
            )
            .firstOrNull;
    if (!widget.enableForIntegration) return;
    WidgetsBinding.instance.addObserver(this);
    _authChanges = Supabase.instance.client.auth.onAuthStateChange.listen((_) {
      unawaited(_load());
    });
    unawaited(_load());
  }

  Future<void> _load({bool append = false}) async {
    if (!mounted || !widget.enableForIntegration) return;
    final request = ++_request;
    final beforeId = append && _items.isNotEmpty ? _items.last.id : null;
    setState(() {
      if (!append) {
        _report = null;
        _items = [];
      }
      _error = null;
      _loading = true;
    });
    try {
      if (!AccountStorage.instance.isActive) {
        throw StateError(
          'La cuenta ya no está activa. Reinicia la aplicación.',
        );
      }
      final selected = _selectedReport;
      if (selected == null || !widget.allowedReports.contains(selected)) {
        throw StateError('No tienes informes autorizados.');
      }
      final client = Supabase.instance.client;
      final guard = SyncSessionGuard(client, PreferencesService());
      final session = guard.capture();
      final scope = _scope;
      if (scope != null &&
          (scope.actorId != session.actorId ||
              scope.billarId != session.billarId ||
              scope.scopeGeneration != session.scopeGeneration)) {
        throw StateError('La cuenta o el billar de la pantalla cambió.');
      }
      _scope ??= session;
      final report = await StaffReportRepository(
        client,
        guard.require,
      ).load(session, selected, _start, _end, beforeId: beforeId);
      guard.require(session);
      if (!mounted || request != _request) return;
      setState(() {
        _report = report;
        _items = append ? [..._items, ...report.items] : report.items;
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

  void _fail(int request, Object error, StackTrace stack) {
    log(
      'No se pudo consultar el informe de personal',
      error: error,
      stackTrace: stack,
    );
    if (mounted && request == _request) {
      setState(() {
        _report = null;
        _items = [];
        _error = error.toString();
      });
    }
  }

  Future<void> _pickRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(
        start: _start,
        end: _end.subtract(const Duration(days: 1)),
      ),
    );
    if (range == null || !mounted) return;
    setState(() {
      _start = range.start;
      _end = DateTime(range.end.year, range.end.month, range.end.day + 1);
    });
    await _load();
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
    final report = _report;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'INFORMES · ${_sectionLabel(_selectedReport).toUpperCase()}',
        ),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            tooltip: 'Actualizar informe',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body:
          !widget.enableForIntegration
              ? const Center(
                child: Text('El informe de personal aún no está habilitado.'),
              )
              : _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(
                      onPressed: _load,
                      child: const Text('REINTENTAR'),
                    ),
                    TextButton(
                      onPressed: _pickRange,
                      child: const Text('CAMBIAR FECHAS'),
                    ),
                  ],
                ),
              )
              : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (widget.allowedReports.length > 1)
                    DropdownButton<StaffModule>(
                      value: _selectedReport,
                      isExpanded: true,
                      items: [
                        for (final module in StaffModule.values)
                          if (module.parent == StaffModule.reports &&
                              widget.allowedReports.contains(module))
                            DropdownMenuItem(
                              value: module,
                              child: Text(_sectionLabel(module)),
                            ),
                      ],
                      onChanged: (module) {
                        if (module == null) return;
                        setState(() => _selectedReport = module);
                        unawaited(_load());
                      },
                    ),
                  const Text(
                    'Solo consulta · requiere conexión · datos sincronizados.\n'
                    'Totales de todo el rango; listado por registro más reciente. Máximo 366 días.',
                  ),
                  TextButton.icon(
                    onPressed: _pickRange,
                    icon: const Icon(Icons.date_range),
                    label: Text(
                      '${_start.day}/${_start.month}/${_start.year} — '
                      '${_end.subtract(const Duration(days: 1)).day}/'
                      '${_end.subtract(const Duration(days: 1)).month}/'
                      '${_end.subtract(const Duration(days: 1)).year}',
                    ),
                  ),
                  if (report != null) ...[
                    Text('Registros: ${report.count}'),
                    for (final entry in report.metrics.entries)
                      Text(
                        '${entry.key}: ${entry.value == null ? 'No disponible' : formatReportMoney(entry.value!)}',
                      ),
                    if (_selectedReport == StaffModule.reportsPurchases)
                      const Text(
                        'El total comprado no equivale a salida de efectivo.',
                      ),
                    if (report.incompleteExpenses)
                      const Text(
                        'Hay retiros/gastos antiguos sin clasificación. '
                        'No se calcula utilidad para evitar tratar retiros como gastos.',
                      ),
                    if (_selectedReport == StaffModule.reportsCashFlow)
                      const Text(
                        'No incluye fondos iniciales ni cortes que existan solo en un teléfono.',
                      ),
                  ],
                  if (_items.isEmpty)
                    Text(
                      _selectedReport == StaffModule.reportsPurchases
                          ? 'No hay compras en este rango.'
                          : report?.count == 0
                          ? 'No hay registros en este rango.'
                          : '',
                    ),
                  for (final item in _items)
                    ListTile(
                      title: Text('#${item.id} · ${item.label}'),
                      subtitle: Text('${item.date}\n${item.details}'),
                      trailing: Text(
                        _selectedReport == StaffModule.reportsKardex
                            ? item.amount.toStringAsFixed(2)
                            : formatReportMoney(item.amount),
                      ),
                    ),
                  if (report?.hasMore == true)
                    TextButton(
                      onPressed: () => _load(append: true),
                      child: const Text('CARGAR MÁS'),
                    ),
                ],
              ),
    );
  }

  String _sectionLabel(StaffModule? module) {
    for (final entry in StaffModule.reports.sectionPermissions.entries) {
      if (entry.value == module) return entry.key;
    }
    return 'Sin acceso';
  }
}
