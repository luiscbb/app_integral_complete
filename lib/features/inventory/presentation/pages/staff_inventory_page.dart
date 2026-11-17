import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/sync_session.dart';
import '../../../../core/storage/account_storage.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../data/repositories/staff_inventory_repository.dart';
import '../../domain/entities/staff_inventory_product.dart';

class StaffInventoryPage extends StatefulWidget {
  const StaffInventoryPage({super.key, this.enableForIntegration = false});

  final bool enableForIntegration;

  @override
  State<StaffInventoryPage> createState() => _StaffInventoryPageState();
}

class _StaffInventoryPageState extends State<StaffInventoryPage>
    with WidgetsBindingObserver {
  final _search = TextEditingController();
  StreamSubscription<AuthState>? _authChanges;
  SyncSession? _scope;
  List<StaffInventoryProduct> _products = [];
  String? _category;
  String? _error;
  bool _loading = false;
  int _request = 0;

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
      _products = [];
      _error = null;
      _loading = true;
    });
    try {
      if (!AccountStorage.instance.isActive) {
        throw StateError(
          'La cuenta ya no está activa. Reinicia la aplicación.',
        );
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
      final products = await StaffInventoryRepository(
        client,
        guard.require,
      ).load(session);
      guard.require(session);
      if (!mounted || request != _request) return;
      setState(() {
        _products = products;
        if (!_products.any((product) => product.category == _category)) {
          _category = null;
        }
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
      'No se pudo consultar el inventario de personal',
      error: error,
      stackTrace: stack,
    );
    if (mounted && request == _request) {
      setState(() => _error = error.toString());
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
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final products =
        _products
            .where(
              (product) =>
                  (_category == null || product.category == _category) &&
                  (query.isEmpty ||
                      product.name.toLowerCase().contains(query) ||
                      (product.barcode?.toLowerCase().contains(query) ??
                          false)),
            )
            .toList();
    final categories =
        _products
            .map((product) => product.category)
            .where((category) => category.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return Scaffold(
      appBar: AppBar(
        title: const Text('INVENTARIO · PERSONAL'),
        actions: [
          if (widget.enableForIntegration)
            IconButton(
              tooltip: 'Actualizar inventario',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body:
          !widget.enableForIntegration
              ? const Center(
                child: Text(
                  'El inventario de personal aún no está habilitado.',
                ),
              )
              : _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      TextButton(
                        onPressed: _load,
                        child: const Text('REINTENTAR'),
                      ),
                    ],
                  ),
                ),
              )
              : Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Productos activos · solo consulta · requiere conexión.\n'
                      'Stock registrado, sin descontar reservas. Las presentaciones '
                      'y promociones dependen de su producto base o componentes.',
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _search,
                      decoration: const InputDecoration(
                        labelText: 'Buscar por nombre o código',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _category,
                      hint: const Text('Todas las categorías'),
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('Todas las categorías'),
                        ),
                        for (final category in categories)
                          DropdownMenuItem(
                            value: category,
                            child: Text(category),
                          ),
                      ],
                      onChanged: (value) => setState(() => _category = value),
                    ),
                  ),
                  Expanded(
                    child:
                        products.isEmpty
                            ? const Center(
                              child: Text('Sin productos para esta consulta.'),
                            )
                            : ListView.builder(
                              itemCount: products.length,
                              itemBuilder: (_, index) {
                                final product = products[index];
                                return Card(
                                  child: ListTile(
                                    title: Text(product.name),
                                    subtitle: Text(
                                      [
                                        if (product.barcode != null)
                                          'Código: ${product.barcode}',
                                        if (product.category.isNotEmpty)
                                          product.category,
                                        if (product.presentation.isNotEmpty)
                                          product.presentation,
                                        if (product.isPromo) 'Promoción',
                                        if (product.parentId != null)
                                          'Presentación de producto base',
                                        'Stock registrado: ${product.stock.toStringAsFixed(2)}',
                                        'Precio: \$${product.price.toStringAsFixed(2)} · '
                                            'Costo: \$${product.cost.toStringAsFixed(2)}',
                                      ].join('\n'),
                                    ),
                                  ),
                                );
                              },
                            ),
                  ),
                ],
              ),
    );
  }
}
