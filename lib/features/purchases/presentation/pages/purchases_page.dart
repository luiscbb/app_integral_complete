import 'package:flutter/material.dart';

import '../../../inventory/data/repositories/product_repository.dart';
import '../../../inventory/domain/entities/product_entity.dart';
import '../../data/repositories/purchases_repository.dart';
import '../../domain/entities/provider_entity.dart';
import '../../domain/entities/purchase_entity.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/empty_state.dart';

class PurchasesPage extends StatefulWidget {
  const PurchasesPage({super.key});

  @override
  State<PurchasesPage> createState() => _PurchasesPageState();
}

class _PurchasesPageState extends State<PurchasesPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _repo = PurchasesRepository();
  final _productRepo = ProductRepository();

  List<ProviderEntity> _providers = [];
  List<ProductEntity> _products = [];
  List<Map<String, dynamic>> _history = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final p = await _repo.getProviders();
    final pr = await _productRepo.getAll();
    final h = await _repo.getHistory();
    if (mounted) {
      setState(() {
        _providers = p;
        _products = pr;
        _history = h;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'COMPRAS',
          style: TextStyle(color: Color(0xFFFB8C00), fontWeight: FontWeight.bold),
        ),
        bottom: TabBar(
          controller: _tabs,
          labelColor: const Color(0xFFFB8C00),
          unselectedLabelColor: Colors.white38,
          indicatorColor: const Color(0xFFFB8C00),
          tabs: const [Tab(text: 'NUEVA COMPRA'), Tab(text: 'PROVEEDORES'), Tab(text: 'HISTORIAL')],
        ),
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator(color: Color(0xFFFB8C00)))
              : TabBarView(
                controller: _tabs,
                children: [
                  _NewPurchaseTab(providers: _providers, products: _products, onSaved: _load),
                  _ProvidersTab(providers: _providers, repo: _repo, onChanged: _load),
                  _HistoryTab(history: _history),
                ],
              ),
    );
  }
}

class _NewPurchaseTab extends StatefulWidget {
  final List<ProviderEntity> providers;
  final List<ProductEntity> products;
  final VoidCallback onSaved;
  const _NewPurchaseTab({required this.providers, required this.products, required this.onSaved});

  @override
  State<_NewPurchaseTab> createState() => _NewPurchaseTabState();
}

class _CartItem {
  final ProductEntity product;
  double quantity;
  double cost;
  _CartItem({required this.product, required this.quantity, required this.cost});
  double get subtotal => quantity * cost;
}

class _NewPurchaseTabState extends State<_NewPurchaseTab> {
  final _repo = PurchasesRepository();
  final _refCtrl = TextEditingController();
  ProviderEntity? _provider;
  final List<_CartItem> _cart = [];
  bool _saving = false;

  final List<TextEditingController> _qtyControllers = [];
  final List<TextEditingController> _costControllers = [];

  @override
  void dispose() {
    _refCtrl.dispose();
    for (final c in _qtyControllers) { c.dispose(); }
    for (final c in _costControllers) { c.dispose(); }
    super.dispose();
  }

  double _calcTotal() => _cart.fold(0, (a, c) => a + c.subtotal);

  Future<void> _save() async {
    if (_cart.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agrega al menos un producto'), backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await _repo.savePurchase(
        purchase: PurchaseEntity(
          providerId: _provider?.id,
          reference: _refCtrl.text,
          items: _cart.map((c) => PurchaseItemEntity(
            productId: c.product.id!,
            productName: c.product.name,
            quantity: c.quantity,
            costPerUnit: c.cost,
          )).toList(),
        ),
      );
      if (!mounted) return;
      _refCtrl.clear();
      _provider = null;
      for (final c in _qtyControllers) { c.dispose(); }
      for (final c in _costControllers) { c.dispose(); }
      _qtyControllers.clear();
      _costControllers.clear();
      _cart.clear();
      widget.onSaved();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Compra registrada y stock actualizado'), backgroundColor: Colors.green),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _addToCart(ProductEntity p) {
    final existing = _cart.where((c) => c.product.id == p.id).firstOrNull;
    if (existing != null) {
      setState(() => existing.quantity++);
      final idx = _cart.indexOf(existing);
      _qtyControllers[idx].text = existing.quantity.toStringAsFixed(
        existing.quantity == existing.quantity.toInt() ? 0 : 2
      );
      return;
    }
    final item = _CartItem(product: p, quantity: 1, cost: p.cost);
    setState(() {
      _cart.add(item);
      _qtyControllers.add(TextEditingController(text: item.quantity.toStringAsFixed(0)));
      _costControllers.add(TextEditingController(text: item.cost.toStringAsFixed(2)));
    });
  }

  void _removeFromCart(int index) {
    _qtyControllers[index].dispose();
    _costControllers[index].dispose();
    setState(() {
      _qtyControllers.removeAt(index);
      _costControllers.removeAt(index);
      _cart.removeAt(index);
    });
  }

  void _updateQty(int index, double v) {
    setState(() => _cart[index].quantity = v > 0 ? v : 1);
  }

  void _updateCost(int index, double v) {
    setState(() => _cart[index].cost = v >= 0 ? v : 0);
  }

  void _selectAll(TextEditingController controller) {
    controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
  }

  Future<void> _openProductPicker() async {
    final searchCtrl = TextEditingController();
    var filtered = List<ProductEntity>.from(widget.products);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, ss) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.7,
              maxChildSize: 0.95,
              builder: (_, ctrl) => Padding(
                padding: EdgeInsets.only(bottom: MediaQuery.of(ctx2).viewInsets.bottom, left: 16, right: 16, top: 16),
                child: Column(
                  children: [
                    Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(height: 16),
                    const Text('AGREGAR PRODUCTOS', style: TextStyle(color: Color(0xFFFB8C00), fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 1)),
                    const SizedBox(height: 12),
                    TextField(
                      controller: searchCtrl,
                      onChanged: (q) {
                        ss(() {
                          final text = q.toLowerCase();
                          filtered = widget.products.where((p) => p.name.toLowerCase().contains(text)).toList();
                        });
                      },
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Buscar producto...',
                        hintStyle: const TextStyle(color: Colors.white24),
                        prefixIcon: const Icon(Icons.search, color: Colors.white38),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: filtered.isEmpty
                        ? const Center(child: Text('Sin coincidencias', style: TextStyle(color: Colors.white24)))
                        : ListView.builder(
                            controller: ctrl,
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final p = filtered[i];
                              final inCart = _cart.any((c) => c.product.id == p.id);
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: const Color(0xFFFB8C00).withValues(alpha: 0.15),
                                  child: Text(p.name.substring(0, 1).toUpperCase(), style: const TextStyle(color: Color(0xFFFB8C00), fontWeight: FontWeight.bold)),
                                ),
                                title: Text(p.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                                subtitle: Text('Stock: ${p.stock.toStringAsFixed(0)}  |  Costo: \$${p.cost.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white38, fontSize: 11)),
                                trailing: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: inCart ? Colors.green : const Color(0xFFFB8C00),
                                    padding: const EdgeInsets.symmetric(horizontal: 12),
                                  ),
                                  onPressed: () {
                                    _addToCart(p);
                                    ss(() {});
                                    if (_cart.where((c) => c.product.id == p.id).length == 1) {
                                      Navigator.of(ctx).pop();
                                    }
                                  },
                                  child: Text(inCart ? '+' : 'Agregar', style: const TextStyle(color: Colors.white, fontSize: 12)),
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
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [const Color(0xFFFB8C00).withValues(alpha: 0.12), Colors.transparent]),
            border: const Border(bottom: BorderSide(color: Colors.white10)),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<ProviderEntity>(
                      value: _provider,
                      dropdownColor: const Color(0xFF1A1A1A),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Proveedor (opcional)',
                        labelStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                        filled: true, fillColor: Colors.white.withValues(alpha: 0.05),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      items: widget.providers.map((p) => DropdownMenuItem(value: p, child: Text(p.name))).toList(),
                      onChanged: (v) => setState(() => _provider = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _refCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Referencia / Factura',
                        labelStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                        prefixIcon: const Icon(Icons.receipt, color: Colors.white38, size: 18),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                        filled: true, fillColor: Colors.white.withValues(alpha: 0.05),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Toolbar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.shopping_cart, color: const Color(0xFFFB8C00).withValues(alpha: 0.7), size: 18),
              const SizedBox(width: 8),
              Text('CARRITO (${_cart.length})', style: const TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1, fontWeight: FontWeight.bold)),
              const Spacer(),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFB8C00), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6)),
                icon: const Icon(Icons.add, size: 16, color: Colors.white),
                label: const Text('AGREGAR PRODUCTO', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                onPressed: _openProductPicker,
              ),
            ],
          ),
        ),
        const Divider(color: Colors.white10, height: 1),
        // Tabla carrito
        Expanded(
          child: _cart.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.shopping_basket_outlined, color: Colors.white.withValues(alpha: 0.08), size: 72),
                    const SizedBox(height: 16),
                    Text('CARRITO VACIO', style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 14, letterSpacing: 2, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('Presiona "Agregar Producto" para empezar', style: TextStyle(color: Colors.white.withValues(alpha: 0.15), fontSize: 12)),
                  ],
                ),
              )
            : Column(
                children: [
                  // Encabezados tabla
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    color: Colors.white.withValues(alpha: 0.02),
                    child: Row(
                      children: [
                        const Expanded(flex: 4, child: Text('PRODUCTO', style: TextStyle(color: Colors.white30, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1))),
                        const Expanded(flex: 2, child: Text('CANT', textAlign: TextAlign.center, style: TextStyle(color: Colors.white30, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1))),
                        const Expanded(flex: 2, child: Text('COSTO', textAlign: TextAlign.center, style: TextStyle(color: Colors.white30, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1))),
                        const Expanded(flex: 2, child: Text('SUBTOTAL', textAlign: TextAlign.right, style: TextStyle(color: Colors.white30, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1))),
                        const SizedBox(width: 36),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _cart.length,
                      itemBuilder: (_, i) {
                        final item = _cart[i];
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)))),
                          child: Row(
                            children: [
                              Expanded(flex: 4, child: Text(item.product.name, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600))),
                              Expanded(flex: 2, child: Center(
                                child: SizedBox(
                                  width: 56,
                                  child: TextField(
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                    decoration: InputDecoration(
                                      filled: true, fillColor: Colors.white.withValues(alpha: 0.05),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                                    ),
                                    controller: _qtyControllers[i],
                                    onTap: () => _selectAll(_qtyControllers[i]),
                                    onChanged: (v) => _updateQty(i, double.tryParse(v) ?? 1),
                                  ),
                                ),
                              )),
                              Expanded(flex: 2, child: Center(
                                child: SizedBox(
                                  width: 64,
                                  child: TextField(
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white, fontSize: 13),
                                    decoration: InputDecoration(
                                      prefixText: '\$', prefixStyle: const TextStyle(color: Colors.white38, fontSize: 10),
                                      filled: true, fillColor: Colors.white.withValues(alpha: 0.05),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                                    ),
                                    controller: _costControllers[i],
                                    onTap: () => _selectAll(_costControllers[i]),
                                    onChanged: (v) => _updateCost(i, double.tryParse(v) ?? 0),
                                  ),
                                ),
                              )),
                              Expanded(flex: 2, child: Text('\${item.subtotal.toStringAsFixed(2)}', textAlign: TextAlign.right, style: const TextStyle(color: Colors.greenAccent, fontSize: 13, fontWeight: FontWeight.bold))),
                              SizedBox(
                                width: 36,
                                child: IconButton(icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18), onPressed: () => _removeFromCart(i), padding: EdgeInsets.zero),
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
        // Footer totales
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF121212),
            border: const Border(top: BorderSide(color: Colors.white10)),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, -4))],
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('TOTAL COMPRA', style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1, fontWeight: FontWeight.bold)),
                  Text('\$${_calcTotal().toStringAsFixed(2)}', style: const TextStyle(color: Color(0xFFFB8C00), fontSize: 24, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFB8C00),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle, color: Colors.white),
                  label: Text(_saving ? 'REGISTRANDO...' : 'REGISTRAR COMPRA', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                  onPressed: _saving ? null : _save,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProvidersTab extends StatelessWidget {
  final List<ProviderEntity> providers;
  final PurchasesRepository repo;
  final VoidCallback onChanged;
  const _ProvidersTab({required this.providers, required this.repo, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFB8C00),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.add),
            label: const Text('AGREGAR PROVEEDOR'),
            onPressed: () => _addProvider(context),
          ),
        ),
        Expanded(
          child:
              providers.isEmpty
                  ? const EmptyState(message: 'No hay proveedores', icon: Icons.store_outlined)
                  : ListView.builder(
                    itemCount: providers.length,
                    itemBuilder: (_, i) {
                      final p = providers[i];
                      return ListTile(
                        leading: const Icon(Icons.store, color: Color(0xFFFB8C00)),
                        title: Text(
                          p.name,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          '${p.phone.isNotEmpty ? p.phone : ''} | ${p.category}',
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () async {
                            await repo.deleteProvider(p.id!);
                            onChanged();
                          },
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }

  Future<void> _addProvider(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    String cat = 'Lunes';
    await showDialog(
      context: context,
      builder:
          (_) => StatefulBuilder(
            builder:
                (ctx, ss) => AlertDialog(
                  backgroundColor: const Color(0xFF1A1A1A),
                  title: const Text('NUEVO PROVEEDOR', style: TextStyle(color: Color(0xFFFB8C00))),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppTextField(controller: nameCtrl, label: 'Nombre', icon: Icons.store),
                      AppTextField(controller: phoneCtrl, label: 'Teléfono', icon: Icons.phone),
                      DropdownButton<String>(
                        value: cat,
                        dropdownColor: const Color(0xFF1A1A1A),
                        style: const TextStyle(color: Colors.white),
                        onChanged: (v) => ss(() => cat = v!),
                        items:
                            [
                              'Lunes',
                              'Martes',
                              'Miércoles',
                              'Jueves',
                              'Viernes',
                              'Sábado',
                            ].map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancelar', style: TextStyle(color: Colors.white38)),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFB8C00)),
                      onPressed: () async {
                        if (nameCtrl.text.isEmpty) return;
                        await repo.insertProvider(
                          ProviderEntity(name: nameCtrl.text, phone: phoneCtrl.text, category: cat),
                        );
                        Navigator.pop(ctx);
                        onChanged();
                      },
                      child: const Text('GUARDAR', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
          ),
    );
  }
}

class _HistoryTab extends StatelessWidget {
  final List<Map<String, dynamic>> history;
  const _HistoryTab({required this.history});

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const EmptyState(message: 'Sin historial de compras', icon: Icons.history);
    }
    return ListView.builder(
      itemCount: history.length,
      itemBuilder: (_, i) {
        final h = history[i];
        final date = DateTime.tryParse(h['date'] ?? '') ?? DateTime.now();
        return ListTile(
          leading: const Icon(Icons.receipt, color: Color(0xFFFB8C00)),
          title: Text(
            h['provider_name'] ?? 'Sin proveedor',
            style: const TextStyle(color: Colors.white),
          ),
          subtitle: Text(
            '${date.day}/${date.month}/${date.year} | ${h['reference'] ?? ''}',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          trailing: Text(
            '\$${(h['total'] as num).toStringAsFixed(2)}',
            style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold),
          ),
        );
      },
    );
  }
}
