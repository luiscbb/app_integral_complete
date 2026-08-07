import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/sales_repository.dart';
import '../../domain/entities/sale_item_entity.dart';
import '../../../inventory/data/repositories/product_repository.dart';
import '../../../inventory/domain/entities/product_entity.dart';
import '../../../inventory/presentation/widgets/product_sale_card.dart';
import '../services/ticket_service.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/theme/theme_provider.dart';

class BilliardTablesPage extends StatefulWidget {
  const BilliardTablesPage({super.key});

  @override
  State<BilliardTablesPage> createState() => _BilliardTablesPageState();
}

class _BilliardTablesPageState extends State<BilliardTablesPage> {
  final _repo = SalesRepository();
  final _ticket = TicketService();
  List<Map<String, dynamic>> _tables = [];
  bool _isLoading = true;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _load();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _load();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final t = await _repo.getTables();
    if (mounted) {
      setState(() {
        _tables = t;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = context.watch<ThemeProvider>().primaryColor;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'MESAS DE BILLAR',
          style: TextStyle(color: const Color(0xFF1E88E5), fontWeight: FontWeight.bold),
        ),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body:
          _isLoading
              ? Center(child: CircularProgressIndicator(color: primary))
              : _tables.isEmpty
              ? const EmptyState(
                message: 'No hay mesas configuradas.\nConfigúralas en Ajustes > Billar',
                icon: Icons.table_bar,
              )
              : GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 200,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.88,
                ),
                itemCount: _tables.length,
                itemBuilder: (_, i) {
                  final t = _tables[i];
                  final isOccupied = (t['is_occupied'] as int) == 1;
                  final orders = jsonDecode(t['orders'] ?? '[]') as List;
                  final consumo = orders.fold<double>(
                    0,
                    (acc, e) => acc + ((e['price'] as num) * (e['quantity'] as num)),
                  );
                  final startTime =
                      t['start_time'] != null ? DateTime.tryParse(t['start_time']) : null;
                  return _TableCard(
                    name: t['name'] ?? 'Mesa',
                    isOccupied: isOccupied,
                    consumo: consumo,
                    startTime: startTime,
                    primaryColor: primary,
                    style: context.read<ThemeProvider>().cardStyle,
                    onTap: () => _openTable(t),
                  );
                },
              ),
    );
  }

  Future<void> _openTable(Map<String, dynamic> tableData) async {
    final saleData = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => _TableDetailPage(tableData: tableData)),
    );
    if (mounted) {
      _load();
      // Mostrar ticket si la mesa devolvió datos de venta
      if (saleData != null) {
        final items = saleData['items'] as List<SaleItemEntity>;
        final total = saleData['total'] as double;
        final paid = saleData['paid'] as double;
        final method = saleData['method'] as String;
        final saleType = saleData['saleType'] as String;
        _ticket.showPreviewSheet(
          context: context,
          items: items,
          total: total,
          paid: paid,
          paymentMethod: method,
          saleType: saleType,
        );
      }
    }
  }
}

class _TableCard extends StatefulWidget {
  final String name;
  final bool isOccupied;
  final double consumo;
  final DateTime? startTime;
  final Color primaryColor;
  final CardStyle style;
  final VoidCallback onTap;

  const _TableCard({
    required this.name,
    required this.isOccupied,
    required this.consumo,
    required this.startTime,
    required this.primaryColor,
    this.style = CardStyle.gradient,
    required this.onTap,
  });

  @override
  State<_TableCard> createState() => _TableCardState();
}

class _TableCardState extends State<_TableCard> {
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  DateTime? _startTime;
  final _prefs = PreferencesService();

  @override
  void initState() {
    super.initState();
    _startTime = widget.startTime;
    if (widget.isOccupied && _startTime != null) {
      _elapsed = DateTime.now().difference(_startTime!);
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _startTime != null) {
          setState(() => _elapsed = DateTime.now().difference(_startTime!));
        }
      });
    }
  }

  @override
  void didUpdateWidget(_TableCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startTime != widget.startTime) {
      _startTime = widget.startTime;
      if (_startTime == null) {
        _timer?.cancel();
        _timer = null;
        _elapsed = Duration.zero;
      } else if (_timer == null || !_timer!.isActive) {
        _elapsed = DateTime.now().difference(_startTime!);
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted && _startTime != null) {
            setState(() => _elapsed = DateTime.now().difference(_startTime!));
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  double get _timeCost {
    final rate = _prefs.hourlyRate;
    if (rate <= 0) return 0;
    final raw = (_elapsed.inSeconds / 3600) * rate;
    return raw.ceilToDouble();
  }

  String get _elapsedStr {
    final h = _elapsed.inHours;
    final m = _elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.primaryColor;
    final totalCost = widget.consumo + _timeCost;

    final solidWhite = widget.style == CardStyle.solidWhite;
    final outlined = widget.style == CardStyle.outlined;
    final contentColor = solidWhite ? Colors.white.withValues(alpha: 0.92) : color;

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        decoration: solidWhite
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: color,
                border: Border.all(color: Colors.white.withValues(alpha: 0.28), width: 1.5),
              )
            : outlined
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: const Color(0xFF1A1A1A),
                    border: Border.all(color: color, width: 2),
                  )
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [color.withValues(alpha: 0.22), const Color(0xFF1A1A1A)],
                    ),
                    border: Border.all(color: color.withValues(alpha: 0.5), width: 2),
                  ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.table_bar_rounded, size: 38, color: contentColor),
            const SizedBox(height: 6),
            Text(
              widget.name,
              style: TextStyle(
                color: contentColor,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: solidWhite ? Colors.white.withValues(alpha: 0.22) : color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                widget.isOccupied ? 'OCUPADA' : 'LIBRE',
                style: TextStyle(
                  color: contentColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
            if (widget.isOccupied) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.timer, size: 13, color: Colors.white38),
                  const SizedBox(width: 4),
                  Text(
                    _elapsedStr,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              if (_timeCost > 0) ...[
                const SizedBox(height: 2),
                Text(
                  'Tiempo: \$${_timeCost.toStringAsFixed(2)}',
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 11),
                ),
              ],
              if (widget.consumo > 0) ...[
                const SizedBox(height: 2),
                Text(
                  'Consumo: \$${widget.consumo.toStringAsFixed(2)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
              const SizedBox(height: 2),
              Text(
                'Total: \$${totalCost.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── DETALLE DE MESA ──────────────────────────────────────────────────────────
class _TableDetailPage extends StatefulWidget {
  final Map<String, dynamic> tableData;
  const _TableDetailPage({required this.tableData});

  @override
  State<_TableDetailPage> createState() => _TableDetailPageState();
}

class _TableDetailPageState extends State<_TableDetailPage> {
  final _salesRepo = SalesRepository();
  final _productRepo = ProductRepository();
  final _ticket = TicketService();
  final _prefs = PreferencesService();
  List<SaleItemEntity> _orders = [];
  List<ProductEntity> _products = [];
  Map<int, double> _reservedOthers = {};
  bool _isLoading = true;
  bool _askedTimer = false;
  bool _isCheckingOut = false;
  bool _initialized = false;
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  DateTime? _startTime;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Inicializar una sola vez; evita reiniciar el cronómetro y doble cobro.
    if (!_initialized) {
      _initialized = true;
      _init();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final raw = jsonDecode(widget.tableData['orders'] ?? '[]') as List;
    _orders =
        raw
            .map(
              (e) => SaleItemEntity(
                productId: e['productId'],
                productName: e['productName'],
                price: (e['price'] as num).toDouble(),
                quantity: (e['quantity'] as num).toDouble(),
              ),
            )
            .toList();

    if (widget.tableData['start_time'] != null) {
      _startTime = DateTime.tryParse(widget.tableData['start_time']);
      if (_startTime != null) {
        _elapsed = DateTime.now().difference(_startTime!);
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted && _startTime != null) {
            setState(() => _elapsed = DateTime.now().difference(_startTime!));
          }
        });
      }
    }

    final prods = await _productRepo.getAll();
    final reservedOthers = await _salesRepo.getReservedQuantities(
      excludeTableId: widget.tableData['id'],
    );
    if (mounted) {
      setState(() {
        _products = prods;
        _reservedOthers = reservedOthers;
        _isLoading = false;
      });
      // Solo preguntar si hay tarifa, no hay timer, no hay ordenes, y no hemos preguntado antes
      if (_startTime == null && _prefs.hourlyRate > 0 && _orders.isEmpty && !_askedTimer) {
        _askedTimer = true;
        _askStartTimer();
      }
    }
  }

  Future<void> _askStartTimer() async {
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => PopScope(
            canPop: false,
            child: AlertDialog(
              backgroundColor: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Row(
                children: [
                  const Icon(Icons.timer, color: Colors.orangeAccent, size: 28),
                  const SizedBox(width: 10),
                  Text(
                    widget.tableData['name'] ?? 'Mesa',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Inicia el cronómetro para cobrar el tiempo de uso de la mesa.',
                    style: TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.attach_money, color: Colors.orangeAccent, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        'Tarifa: \$${_prefs.hourlyRate.toStringAsFixed(2)} / hora',
                        style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent),
                  icon: const Icon(Icons.timer, color: Colors.black, size: 18),
                  label: const Text(
                    'INICIAR TIEMPO',
                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                ),
              ],
            ),
          ),
    );
    if (confirmed == true && mounted) {
      await _salesRepo.occupyTable(widget.tableData['id']);
      setState(() {
        _startTime = DateTime.now();
        _elapsed = Duration.zero;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed = DateTime.now().difference(_startTime!));
      });
    }
  }

  double get _consumoTotal => _orders.fold(0, (acc, e) => acc + e.subtotal);

  double get _timeCost {
    final rate = _prefs.hourlyRate;
    if (rate <= 0 || _startTime == null) return 0;
    final raw = (_elapsed.inSeconds / 3600) * rate;
    return raw.ceilToDouble();
  }

  /// Item de tiempo para ticket/venta: cantidad fija = 1 unidad de tiempo,
  /// precio unitario = el mismo costo proporcional que se muestra y cobra en
  /// vivo (_timeCost), para que el ticket y el registro de venta coincidan
  /// exactamente con lo cobrado (proporcional a los minutos jugados, no
  /// redondeado a la hora completa). Así el PDF muestra
  /// "Tiempo de juego (00:10) P.U. $10.00 CANT 1 IMPORTE $10.00".
  SaleItemEntity _buildTimeItem() {
    return SaleItemEntity(
      productName: 'Tiempo de juego ($_elapsedStr)',
      price: _timeCost,
      quantity: 1,
    );
  }

  double get _grandTotal => _consumoTotal + _timeCost;

  String get _elapsedStr {
    final h = _elapsed.inHours;
    final m = _elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _addProduct(ProductEntity p) {
    // Validar stock considerando lo ya reservado en otras mesas abiertas.
    final currentQty = _orders.firstWhere(
      (o) => o.productId == p.id,
      orElse: () => SaleItemEntity(productName: '', price: 0, quantity: 0),
    ).quantity;
    final reservedElsewhere = _reservedOthers[p.id] ?? 0;
    final availableStock = p.stock - reservedElsewhere;
    if (availableStock <= currentQty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Stock insuficiente: ${p.name}'), backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() {
      final idx = _orders.indexWhere((e) => e.productId == p.id);
      if (idx >= 0) {
        _orders[idx].quantity += 1;
      } else {
        _orders.add(SaleItemEntity(productId: p.id, productName: p.name, price: p.price));
      }
    });
    _save();
  }

  void _removeItem(int idx) {
    setState(() {
      if (_orders[idx].quantity > 1) {
        _orders[idx].quantity -= 1;
      } else {
        _orders.removeAt(idx);
      }
    });
    _save();
  }

  Future<void> _save() async {
    await _salesRepo.saveTableOrder(
      tableId: widget.tableData['id'],
      items: _orders,
      tableName: widget.tableData['name'],
    );
    // Ya no iniciamos timer automáticamente aquí, solo guardamos ordenes
  }

  Future<void> _checkout() async {
    if (_isCheckingOut) return; // Evita doble cobro por taps rápidos.
    if (_orders.isEmpty && _timeCost == 0) return;
    debugPrint('[Checkout] Iniciando checkout para mesa: ${widget.tableData['name']}');
    String method = 'Efectivo';
    double paid = _grandTotal;
    final ctrl = TextEditingController(text: _grandTotal.toStringAsFixed(2));
    final primary = context.read<ThemeProvider>().primaryColor;

    final result = await showDialog<(double, String)>(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (_, ss) => AlertDialog(
                  backgroundColor: const Color(0xFF1A1A1A),
                  title: Text(
                    'COBRAR - ${widget.tableData['name']}',
                    style: TextStyle(color: primary, fontWeight: FontWeight.bold),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_startTime != null) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Tiempo:', style: TextStyle(color: Colors.white54)),
                            Text(
                              _elapsedStr,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        if (_timeCost > 0)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Costo tiempo:', style: TextStyle(color: Colors.white54)),
                              Text(
                                '\$${_timeCost.toStringAsFixed(2)}',
                                style: const TextStyle(color: Colors.orangeAccent),
                              ),
                            ],
                          ),
                        if (_consumoTotal > 0)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Consumo:', style: TextStyle(color: Colors.white54)),
                              Text(
                                '\$${_consumoTotal.toStringAsFixed(2)}',
                                style: const TextStyle(color: Colors.white54),
                              ),
                            ],
                          ),
                        const Divider(color: Colors.white10),
                      ],
                      Text(
                        'Total: \$${_grandTotal.toStringAsFixed(2)}',
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
                            [
                              'Efectivo',
                              'Tarjeta',
                              'Transferencia',
                            ].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                      ),
                      if (method == 'Efectivo') ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: ctrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: 'Monto recibido',
                            labelStyle: TextStyle(color: Colors.white38),
                          ),
                          onTap: () => ctrl.clear(),
                          onChanged: (v) => ss(() => paid = double.tryParse(v) ?? _grandTotal),
                        ),
                        const SizedBox(height: 8),
                        Builder(
                          builder: (_) {
                            final diff = paid - _grandTotal;
                            final isShort = diff < 0;
                            return Text(
                              isShort
                                  ? 'Falta: \$${diff.abs().toStringAsFixed(2)}'
                                  : 'Cambio: \$${diff.toStringAsFixed(2)}',
                              style: TextStyle(
                                color: isShort ? Colors.redAccent : Colors.greenAccent,
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
                      child: const Text('Cancelar', style: TextStyle(color: Colors.white38)),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: primary),
                      onPressed: () => Navigator.pop(ctx, (paid, method)),
                      child: const Text('CONFIRMAR', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
          ),
    );

    if (result == null) return;
    final (finalPaid, finalMethod) = result;

    if (_isCheckingOut) return; // Doble verificación antes de persistir la venta.
    _isCheckingOut = true;

    final allItems = List<SaleItemEntity>.from(_orders);
    if (_timeCost > 0) {
      allItems.add(_buildTimeItem());
    }
    // Total calculado desde los items finales (evita desincronización con el cronómetro)
    final finalTotal = allItems.fold<double>(0, (acc, e) => acc + e.price * e.quantity);

    await _salesRepo.saveSale(
      items: allItems,
      total: finalTotal,
      paid: finalPaid,
      paymentMethod: finalMethod,
      saleType: widget.tableData['name'] ?? 'Mesa',
    );
    if (!mounted) return;
    for (final item in _orders) {
      final p = _products.firstWhere(
        (x) => x.id == item.productId,
        orElse: () => ProductEntity(name: item.productName, price: item.price, stock: 0),
      );
      await _productRepo.decreaseStock(p, item.quantity.toDouble());
    }
    _timer?.cancel();
    _timer = null;
    _startTime = null;
    await _salesRepo.freeTable(widget.tableData['id']);
    if (!mounted) return;

    // Devolver datos al grid para que muestre el ticket
    Navigator.of(context).pop({
      'items': allItems,
      'total': finalTotal,
      'paid': finalPaid,
      'method': finalMethod,
      'saleType': widget.tableData['name'] ?? 'Mesa',
    });
  }

  @override
  Widget build(BuildContext context) {
    final primary = context.watch<ThemeProvider>().primaryColor;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.tableData['name'] ?? 'Mesa',
          style: TextStyle(color: primary, fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_startTime != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.timer, size: 14, color: Colors.orangeAccent),
                    const SizedBox(width: 4),
                    Text(
                      _elapsedStr,
                      style: const TextStyle(
                        color: Colors.orangeAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (_prefs.hourlyRate > 0)
            TextButton.icon(
              icon: const Icon(Icons.timer_outlined, color: Colors.orangeAccent),
              label: const Text('INICIAR TIEMPO', style: TextStyle(color: Colors.orangeAccent)),
              onPressed: () async {
                await _salesRepo.occupyTable(widget.tableData['id']);
                setState(() {
                  _startTime = DateTime.now();
                  _elapsed = Duration.zero;
                });
                _timer?.cancel();
                _timer = Timer.periodic(const Duration(seconds: 1), (_) {
                  if (mounted) setState(() => _elapsed = DateTime.now().difference(_startTime!));
                });
              },
            ),
          if (_orders.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.receipt_long, color: Colors.white),
              label: const Text('VER TICKET', style: TextStyle(color: Colors.white)),
              onPressed: () {
                final items = List<SaleItemEntity>.from(_orders);
                if (_timeCost > 0) {
                  items.add(_buildTimeItem());
                }
                final previewTotal = items.fold<double>(0, (acc, e) => acc + e.price * e.quantity);
                _ticket.showPreviewSheet(
                  context: context,
                  items: items,
                  total: previewTotal,
                  paid: 0,
                  paymentMethod: 'Efectivo',
                  saleType: widget.tableData['name'],
                );
              },
            ),
        ],
      ),
      body:
          _isLoading
              ? Center(child: CircularProgressIndicator(color: primary))
              : Column(
                children: [
                  if (_startTime != null && _prefs.hourlyRate > 0)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      color: Colors.orangeAccent.withValues(alpha: 0.1),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.attach_money, color: Colors.orangeAccent, size: 16),
                              const SizedBox(width: 4),
                              Text(
                                'Tarifa: \$${_prefs.hourlyRate.toStringAsFixed(2)}/hr',
                                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
                              ),
                            ],
                          ),
                          Text(
                            'Costo tiempo: \$${_timeCost.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.orangeAccent,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (_startTime == null && _prefs.hourlyRate > 0)
                    InkWell(
                      onTap: () async {
                        await _salesRepo.occupyTable(widget.tableData['id']);
                        setState(() {
                          _startTime = DateTime.now();
                          _elapsed = Duration.zero;
                        });
                        _timer?.cancel();
                        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
                          if (mounted) {
                            setState(() => _elapsed = DateTime.now().difference(_startTime!));
                          }
                        });
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        color: Colors.orangeAccent.withValues(alpha: 0.12),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.timer_outlined, color: Colors.orangeAccent, size: 16),
                            SizedBox(width: 6),
                            Text(
                              'Cronómetro no iniciado · Toca aquí para cobrar tiempo',
                              style: TextStyle(
                                color: Colors.orangeAccent,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Column(
                            children: [
                              const Padding(
                                padding: EdgeInsets.all(12),
                                child: Text(
                                  'PRODUCTOS',
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                    letterSpacing: 2,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Builder(
                                  builder: (_) {
                                    final visibleProducts =
                                        _products.where((p) {
                                          final reservedElsewhere = _reservedOthers[p.id] ?? 0;
                                          final availableStock = p.stock - reservedElsewhere;
                                          final inThisOrder =
                                              _orders
                                                  .firstWhere(
                                                    (e) => e.productId == p.id,
                                                    orElse:
                                                        () => SaleItemEntity(
                                                          productName: '',
                                                          price: 0,
                                                        ),
                                                  )
                                                  .quantity;
                                          return availableStock > inThisOrder || inThisOrder > 0;
                                        }).toList();
                                    return GridView.builder(
                                      padding: const EdgeInsets.all(10),
                                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                        maxCrossAxisExtent: 160,
                                        mainAxisSpacing: 10,
                                        crossAxisSpacing: 10,
                                        childAspectRatio: 0.7,
                                      ),
                                      itemCount: visibleProducts.length,
                                      itemBuilder: (_, i) {
                                        final p = visibleProducts[i];
                                        final q =
                                            _orders
                                                .firstWhere(
                                                  (e) => e.productId == p.id,
                                                  orElse:
                                                      () => SaleItemEntity(
                                                        productName: '',
                                                        price: 0,
                                                      ),
                                                )
                                                .quantity;
                                        final reservedElsewhere = _reservedOthers[p.id] ?? 0;
                                        final displayStock = p.stock - reservedElsewhere - q;
                                        return GestureDetector(
                                          onTap: () => _addProduct(p),
                                          child: ProductSaleCard(
                                            product: p.copyWith(
                                              stock: displayStock < 0 ? 0 : displayStock,
                                            ),
                                            quantity: q.toInt(),
                                            onAdd: () => _addProduct(p),
                                            onRemove: () {
                                              final idx = _orders.indexWhere(
                                                (e) => e.productId == p.id,
                                              );
                                              if (idx >= 0) _removeItem(idx);
                                            },
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(width: 1, color: Colors.white10),
                        SizedBox(
                          width: 260,
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(16),
                                color: const Color(0xFF1A1A1A),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text(
                                          'CONSUMO',
                                          style: TextStyle(
                                            color: Colors.white54,
                                            letterSpacing: 2,
                                            fontSize: 11,
                                          ),
                                        ),
                                        Text(
                                          '\$${_consumoTotal.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (_timeCost > 0) ...[
                                      const SizedBox(height: 4),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            'TIEMPO',
                                            style: TextStyle(
                                              color: Colors.white54,
                                              letterSpacing: 2,
                                              fontSize: 11,
                                            ),
                                          ),
                                          Text(
                                            '\$${_timeCost.toStringAsFixed(2)}',
                                            style: const TextStyle(
                                              color: Colors.orangeAccent,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                    const Divider(color: Colors.white10, height: 12),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text(
                                          'TOTAL',
                                          style: TextStyle(
                                            color: Colors.white54,
                                            letterSpacing: 2,
                                            fontSize: 11,
                                          ),
                                        ),
                                        Text(
                                          '\$${_grandTotal.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            color: Colors.greenAccent,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child:
                                    _orders.isEmpty
                                        ? const EmptyState(
                                          message: 'Sin productos',
                                          icon: Icons.receipt_long_outlined,
                                        )
                                        : ListView.builder(
                                          padding: const EdgeInsets.all(8),
                                          itemCount: _orders.length,
                                          itemBuilder:
                                              (_, i) => ListTile(
                                                dense: true,
                                                title: Text(
                                                  _orders[i].productName,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 13,
                                                  ),
                                                ),
                                                subtitle: Text(
                                                  '${_orders[i].qtyLabel} x \$${_orders[i].price.toStringAsFixed(2)}',
                                                  style: const TextStyle(
                                                    color: Colors.white38,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                                trailing: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      '\$${_orders[i].subtotal.toStringAsFixed(2)}',
                                                      style: const TextStyle(
                                                        color: Colors.greenAccent,
                                                      ),
                                                    ),
                                                    IconButton(
                                                      icon: const Icon(
                                                        Icons.remove_circle,
                                                        color: Colors.white24,
                                                        size: 18,
                                                      ),
                                                      onPressed: () => _removeItem(i),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                        ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: const Color(0xFF1A1A1A),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            minimumSize: const Size(double.infinity, 52),
          ),
          onPressed: _checkout,
          child: Text(
            'COBRAR  \$${_grandTotal.toStringAsFixed(2)}',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
      ),
    );
  }
}
