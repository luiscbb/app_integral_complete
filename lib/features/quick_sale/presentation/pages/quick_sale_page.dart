import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/product_realtime_service.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../../../core/utils/smart_image.dart';
import '../../../../features/inventory/data/repositories/product_repository.dart';
import '../../../../features/inventory/domain/entities/product_entity.dart';
import '../../../../features/inventory/presentation/widgets/product_sale_card.dart';
import '../../../sales/domain/entities/sale_item_entity.dart';
import '../../../sales/data/repositories/sales_repository.dart';
import '../../../sales/data/repositories/stock_reservation_service.dart';
import '../../../sales/presentation/services/ticket_service.dart';

class QuickSalePage extends StatefulWidget {
  const QuickSalePage({super.key});

  @override
  State<QuickSalePage> createState() => _QuickSalePageState();
}

class _QuickSalePageState extends State<QuickSalePage> {
  final _productRepo = ProductRepository();
  final _salesRepo = SalesRepository();
  final _reservationService = StockReservationService();
  final _ticket = TicketService();
  final _prefs = PreferencesService();
  final _searchCtrl = TextEditingController();

  List<ProductEntity> _all = [];
  List<ProductEntity> _filtered = [];
  final Map<int, int> _cart = {};
  // Componentes de cada promo: promoId -> { childId -> cantidad }
  final Map<int, Map<int, int>> _promoComponents = {};
  Map<int, double> _tableReserved = {};
  bool _isLoading = true;
  bool _isGrid = true;
  StreamSubscription<void>? _productChangesSubscription;
  Timer? _productRefreshDebounce;
  bool _refreshingFromRealtime = false;
  bool _productRefreshRequestedWhileRunning = false;
  RealtimeChannel? _tablesChannel;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_filter);
    _productChangesSubscription = ProductRealtimeService.instance.changes
        .listen((_) {
          _productRefreshDebounce?.cancel();
          _productRefreshDebounce = Timer(
            const Duration(milliseconds: 250),
            _refreshProductsFromRealtime,
          );
        });
    _subscribeToTableChanges();
    // Recargar stock cada vez que se vuelve a esta pantalla
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _productRefreshDebounce?.cancel();
    _productChangesSubscription?.cancel();
    _tablesChannel?.unsubscribe();
    super.dispose();
  }

  void _subscribeToTableChanges() {
    final billarId = _prefs.billarId;
    if (billarId.isEmpty) return;
    _tablesChannel =
        Supabase.instance.client
            .channel('public:billiard_tables:quick-sale-$billarId')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'billiard_tables',
              callback: (payload) async {
                final record =
                    payload.newRecord.isNotEmpty
                        ? payload.newRecord
                        : payload.oldRecord;
                if (record['billar_id']?.toString() != billarId) return;
                try {
                  await _salesRepo.refreshTablesFromCloud();
                  final reserved = await _salesRepo.getReservedQuantities(
                    excludeSource: 'quick_sale',
                  );
                  if (mounted) setState(() => _tableReserved = reserved);
                } catch (e) {
                  log(
                    '[QuickSalePage] Error actualizando apartados de mesas/comandas: $e',
                  );
                }
              },
            )
            .subscribe();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final data = await _productRepo.getAll();
    final compMap = <int, Map<int, int>>{};
    for (final p in data) {
      if (p.isPromo == 1 && p.id != null) {
        compMap[p.id!] = await _productRepo.getPromoComponents(p.id!);
      }
    }
    await _salesRepo.refreshTablesFromCloud();
    final reserved = await _salesRepo.getReservedQuantities(
      excludeSource: 'quick_sale',
    );
    // Restaurar carrito de venta rápida si había una reserva activa.
    final quickReserved = await _reservationService.getReservedQuantities(
      includeSource: 'quick_sale',
    );
    final restoredCart = <int, int>{};
    for (final entry in quickReserved.entries) {
      final pid = entry.key;
      final qty = entry.value.toInt();
      if (qty > 0 && data.any((p) => p.id == pid)) {
        restoredCart[pid] = qty;
      }
    }
    if (mounted) {
      setState(() {
        _all = data;
        _filtered = data;
        _promoComponents
          ..clear()
          ..addAll(compMap);
        _tableReserved = reserved;
        _cart
          ..clear()
          ..addAll(restoredCart);
        _isLoading = false;
      });
      _filter();
    }
  }

  Future<void> _refreshProductsFromRealtime() async {
    if (_refreshingFromRealtime) {
      _productRefreshRequestedWhileRunning = true;
      return;
    }
    _refreshingFromRealtime = true;
    try {
      do {
        _productRefreshRequestedWhileRunning = false;
        final data = await _productRepo.refreshFromCloud();
        final compMap = <int, Map<int, int>>{};
        for (final product in data) {
          if (product.isPromo == 1 && product.id != null) {
            compMap[product.id!] = await _productRepo.getPromoComponents(
              product.id!,
            );
          }
        }
        final reserved = await _salesRepo.getReservedQuantities(
          excludeSource: 'quick_sale',
        );
        var cartChanged = false;
        if (mounted) {
          setState(() {
            _all = data;
            _promoComponents
              ..clear()
              ..addAll(compMap);
            _tableReserved = reserved;
            final existingIds = data.map((product) => product.id).toSet();
            final oldLength = _cart.length;
            _cart.removeWhere(
              (productId, _) => !existingIds.contains(productId),
            );
            cartChanged = _cart.length != oldLength;
          });
          _filter();
        }
        if (cartChanged) await _persistReservation();
      } while (_productRefreshRequestedWhileRunning);
    } catch (e) {
      log('[QuickSalePage] Error actualizando productos por Realtime: $e');
    } finally {
      _refreshingFromRealtime = false;
    }
  }

  /// Unidades reservadas en el carrito para un producto, incluyendo las que
  /// aportan las promos seleccionadas (cada promo consume sus componentes).
  int _reservedFor(int? productId) {
    if (productId == null) return 0;
    int reserved = _cart[productId] ?? 0;
    for (final entry in _cart.entries) {
      final comps = _promoComponents[entry.key];
      if (comps != null) {
        final perPromo = comps[productId] ?? 0;
        reserved += perPromo * entry.value;
      }
    }
    return reserved;
  }

  /// Stock disponible visible = stock real menos lo reservado por el carrito.
  double _availableStock(ProductEntity p) {
    final reservedInTables = p.id != null ? (_tableReserved[p.id] ?? 0) : 0.0;
    final avail = p.stock - _reservedFor(p.id) - reservedInTables;
    return avail < 0 ? 0 : avail;
  }

  bool get _allowNegativeStock => _prefs.allowNegativeStockSales;

  void _filter() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filtered =
          _all.where((p) {
            final matchesSearch = q.isEmpty || p.name.toLowerCase().contains(q);
            final hasStock = _allowNegativeStock || _availableStock(p) > 0;
            return matchesSearch && hasStock;
          }).toList();
      // Ordenar: promos primero, luego el resto
      _filtered.sort((a, b) {
        if (a.isPromo == b.isPromo) return a.name.compareTo(b.name);
        return b.isPromo.compareTo(a.isPromo);
      });
    });
  }

  int get _cartCount => _cart.values.fold(0, (a, b) => a + b);
  double get _total => _cart.entries.fold(0.0, (acc, e) {
    final p = _all.firstWhere(
      (x) => x.id == e.key,
      orElse: () => const ProductEntity(name: '', price: 0, stock: 0),
    );
    return acc + p.price * e.value;
  });

  List<SaleItemEntity> get _cartItems =>
      _cart.entries.map((e) {
        final p = _all.firstWhere((x) => x.id == e.key);
        return SaleItemEntity(
          productId: p.id,
          productName: p.name,
          price: p.price,
          quantity: e.value.toDouble(),
        );
      }).toList();

  void _add(ProductEntity p) {
    if (!_allowNegativeStock && _availableStock(p) <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Stock insuficiente: ${p.name}'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    setState(() => _cart[p.id!] = (_cart[p.id] ?? 0) + 1);
    _persistReservation();
  }

  void _remove(int id) {
    setState(() {
      if ((_cart[id] ?? 0) <= 1) {
        _cart.remove(id);
      } else {
        _cart[id] = (_cart[id] ?? 1) - 1;
      }
    });
    _persistReservation();
  }

  Future<void> _persistReservation() async {
    await _reservationService.setQuickSaleReservation(_cartItems);
  }

  Future<void> _checkout() async {
    if (_cart.isEmpty) return;

    // Mostrar resumen del carrito en BottomSheet
    final shouldProceed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, ss) {
            final cartEntries = _cart.entries.toList();
            final currentTotal = cartEntries.fold<double>(0.0, (acc, e) {
              final p = _all.firstWhere((x) => x.id == e.key);
              return acc + p.price * e.value;
            });

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx2).viewInsets.bottom + 16,
                top: 16,
                left: 16,
                right: 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'RESUMEN DE VENTA',
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: cartEntries.length,
                      itemBuilder: (_, i) {
                        final entry = cartEntries[i];
                        final p = _all.firstWhere((x) => x.id == entry.key);
                        final qty = entry.value;
                        return ListTile(
                          dense: true,
                          title: Text(
                            p.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            '\$${p.price.toStringAsFixed(2)} c/u',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.remove_circle,
                                  color: Colors.white38,
                                  size: 20,
                                ),
                                onPressed: () {
                                  ss(() {
                                    if (qty <= 1) {
                                      _cart.remove(p.id);
                                    } else {
                                      _cart[p.id!] = qty - 1;
                                    }
                                  });
                                  if (mounted) setState(() {});
                                  _persistReservation();
                                },
                              ),
                              Text(
                                '$qty',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.add_circle,
                                  color: Colors.greenAccent,
                                  size: 20,
                                ),
                                onPressed:
                                    (!_allowNegativeStock && p.stock <= qty)
                                        ? null
                                        : () {
                                          ss(() => _cart[p.id!] = qty + 1);
                                          if (mounted) setState(() {});
                                          _persistReservation();
                                        },
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                  size: 20,
                                ),
                                onPressed: () {
                                  ss(() => _cart.remove(p.id));
                                  if (mounted) setState(() {});
                                  _persistReservation();
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(color: Colors.white12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'TOTAL:',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '\$${currentTotal.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed:
                          _cart.isEmpty ? null : () => Navigator.pop(ctx, true),
                      child: const Text(
                        'PROCEDER AL PAGO',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text(
                        'SEGUIR COMPRANDO',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (shouldProceed != true) return;
    if (!mounted) return;

    final result = await _showPaymentDialog();
    if (result == null) return;
    final (paid, method) = result;
    final itemsSnapshot = List<SaleItemEntity>.from(_cartItems);
    final totalSnapshot = _total;

    try {
      await _salesRepo.saveSale(
        items: itemsSnapshot,
        total: totalSnapshot,
        paid: paid,
        paymentMethod: method,
        saleType: 'Venta Rápida',
        origin: SaleOrigin.quickSale,
      );
    } on SaleScopeException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (!mounted) return;
    for (final e in _cart.entries) {
      final p = _all.firstWhere((x) => x.id == e.key);
      await _productRepo.decreaseStock(p, e.value.toDouble());
    }
    if (!mounted) return;

    setState(() => _cart.clear());
    await _load();
    if (!mounted) return;

    _ticket.showPreviewSheet(
      context: context,
      items: itemsSnapshot,
      total: totalSnapshot,
      paid: paid,
      paymentMethod: method,
      saleType: 'Venta Rápida',
    );
  }

  Future<(double, String)?> _showPaymentDialog() async {
    String method = 'Efectivo';
    double paid = _total;
    final ctrl = TextEditingController(text: _total.toStringAsFixed(2));
    return showDialog<(double, String)>(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx2, ss) => AlertDialog(
                  backgroundColor: const Color(0xFF1A1A1A),
                  title: Text(
                    'COBRAR',
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Total: \$${_total.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButton<String>(
                        value: method,
                        dropdownColor: const Color(0xFF1A1A1A),
                        style: const TextStyle(color: Colors.white),
                        onChanged: (v) => ss(() => method = v!),
                        items:
                            ['Efectivo', 'Tarjeta', 'Transferencia']
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e,
                                    child: Text(e),
                                  ),
                                )
                                .toList(),
                      ),
                      if (method == 'Efectivo') ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: ctrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: 'Monto recibido',
                            labelStyle: TextStyle(color: Colors.white38),
                          ),
                          onTap: () => ctrl.clear(),
                          onChanged:
                              (v) =>
                                  ss(() => paid = double.tryParse(v) ?? _total),
                        ),
                        const SizedBox(height: 8),
                        Builder(
                          builder: (_) {
                            final diff = paid - _total;
                            final isShort = diff < 0;
                            return Text(
                              isShort
                                  ? 'Falta: \$${diff.abs().toStringAsFixed(2)}'
                                  : 'Cambio: \$${diff.toStringAsFixed(2)}',
                              style: TextStyle(
                                color:
                                    isShort
                                        ? Colors.redAccent
                                        : Colors.greenAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            );
                          },
                        ),
                      ],
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
                      onPressed: () => Navigator.pop(ctx, (paid, method)),
                      child: const Text(
                        'CONFIRMAR',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'VENTA RÁPIDA',
          style: TextStyle(
            color: Color(0xFFE53935),
            fontWeight: FontWeight.bold,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Buscar producto...',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.07),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _isGrid ? Icons.view_list : Icons.grid_view,
              color: Colors.white70,
            ),
            onPressed: () => setState(() => _isGrid = !_isGrid),
          ),
        ],
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _filtered.isEmpty
              ? EmptyState(
                message: 'No hay productos',
                icon: Icons.inventory_2_outlined,
              )
              : _isGrid
              ? GridView.builder(
                padding: const EdgeInsets.all(10),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 190,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.95,
                ),
                itemCount: _filtered.length,
                itemBuilder: (_, i) {
                  final p = _filtered[i];
                  final q = _cart[p.id] ?? 0;
                  final stockRestante = _availableStock(p);
                  final isBlocked = !_allowNegativeStock && stockRestante <= 0;
                  return GestureDetector(
                    onTap: isBlocked ? null : () => _add(p),
                    child: Opacity(
                      opacity: isBlocked ? 0.35 : 1,
                      child: ProductSaleCard(
                        product: p.copyWith(stock: stockRestante),
                        quantity: q,
                        onAdd: isBlocked ? () {} : () => _add(p),
                        onRemove: () => _remove(p.id!),
                        showButtons: true,
                        allowOutOfStock: _allowNegativeStock,
                      ),
                    ),
                  );
                },
              )
              : ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: _filtered.length,
                itemBuilder: (_, i) {
                  final p = _filtered[i];
                  final q = _cart[p.id] ?? 0;
                  final avail = _availableStock(p);
                  final isBlocked = !_allowNegativeStock && avail <= 0;
                  final stockColor =
                      avail <= 0
                          ? Colors.red
                          : avail <= 5
                          ? Colors.orange
                          : Colors.green;
                  return Opacity(
                    opacity: isBlocked ? 0.35 : 1,
                    child: Card(
                      child: ListTile(
                        leading: SizedBox(
                          width: 44,
                          height: 44,
                          child: SmartImage(
                            imagePath: p.imagePath,
                            borderRadius: BorderRadius.circular(8),
                            placeholderIcon: Icons.inventory_2,
                          ),
                        ),
                        title: Text(
                          p.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Row(
                          children: [
                            Text(
                              '\$${p.price.toStringAsFixed(2)}  ',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: stockColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: stockColor.withValues(alpha: 0.5),
                                ),
                              ),
                              child: Text(
                                p.stock <= 0
                                    ? 'AGOTADO'
                                    : '${avail.toInt()} pz',
                                style: TextStyle(
                                  color: stockColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        trailing:
                            q > 0
                                ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(
                                        Icons.remove_circle,
                                        color: Colors.white38,
                                        size: 20,
                                      ),
                                      onPressed: () => _remove(p.id!),
                                    ),
                                    Text(
                                      '$q',
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
                                    ),
                                    IconButton(
                                      icon: Icon(
                                        Icons.add_circle,
                                        color:
                                            isBlocked
                                                ? Colors.white12
                                                : primary,
                                        size: 20,
                                      ),
                                      onPressed:
                                          isBlocked ? null : () => _add(p),
                                    ),
                                  ],
                                )
                                : IconButton(
                                  icon: Icon(
                                    Icons.add_circle,
                                    color: isBlocked ? Colors.white12 : primary,
                                  ),
                                  onPressed: isBlocked ? null : () => _add(p),
                                ),
                      ),
                    ),
                  );
                },
              ),
      bottomNavigationBar: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        height: _cartCount > 0 ? 76 : 0,
        child:
            _cartCount > 0
                ? Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: const BoxDecoration(color: Color(0xFF1A1A1A)),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: _checkout,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: Colors.white.withValues(alpha: 0.2),
                          child: Text(
                            '$_cartCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'COBRAR  \$${_total.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                : null,
      ),
    );
  }
}
