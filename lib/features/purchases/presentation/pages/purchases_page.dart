import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io';

import '../../../../core/storage/preferences_service.dart';
import '../../../inventory/data/repositories/product_repository.dart';
import '../../../inventory/domain/entities/product_entity.dart';
import '../../../inventory/presentation/pages/inventory_page.dart';
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
  final _prefs = PreferencesService();

  List<ProviderEntity> _providers = [];
  List<ProductEntity> _products = [];
  List<Map<String, dynamic>> _history = [];
  bool _isLoading = true;
  RealtimeChannel? _providersChannel;
  RealtimeChannel? _purchasesChannel;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _load();
    _subscribeToChanges();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _providersChannel?.unsubscribe();
    _purchasesChannel?.unsubscribe();
    super.dispose();
  }

  /// Escucha cambios en `providers` y `purchases` para reflejar en tiempo real
  /// lo que pasa en otro dispositivo (celular <-> exe). Filtra por `billar_id`.
  void _subscribeToChanges() {
    final billarId = _prefs.billarId;
    if (billarId.isEmpty) return;

    _providersChannel = Supabase.instance.client
        .channel('public:providers')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'providers',
          callback: (payload) async {
            final newRecord = payload.newRecord;
            if (newRecord.isEmpty) return;
            if (newRecord['billar_id']?.toString() != billarId) return;
            debugPrint('[PurchasesPage] Realtime cambio en providers: $newRecord');
            await _load();
          },
        )
        .subscribe((status, [error]) {
          debugPrint('[PurchasesPage] Realtime providers status: $status error: $error');
        });

    _purchasesChannel = Supabase.instance.client
        .channel('public:purchases')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'purchases',
          callback: (payload) async {
            final newRecord = payload.newRecord;
            if (newRecord.isEmpty) return;
            if (newRecord['billar_id']?.toString() != billarId) return;
            debugPrint('[PurchasesPage] Realtime cambio en purchases: $newRecord');
            await _load();
          },
        )
        .subscribe((status, [error]) {
          debugPrint('[PurchasesPage] Realtime purchases status: $status error: $error');
        });
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

  static const Color _headerColor = Color(0xFFFB8C00);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'COMPRAS',
          style: TextStyle(color: _headerColor, fontWeight: FontWeight.bold),
        ),
        bottom: TabBar(
          controller: _tabs,
          labelColor: _headerColor,
          unselectedLabelColor: Colors.white38,
          indicatorColor: _headerColor,
          tabs: const [Tab(text: 'NUEVA COMPRA'), Tab(text: 'PROVEEDORES'), Tab(text: 'HISTORIAL')],
        ),
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator(color: _headerColor))
              : TabBarView(
                controller: _tabs,
                children: [
                  _NewPurchaseTab(providers: _providers, products: _products, onSaved: _load),
                  _ProvidersTab(providers: _providers, products: _products, repo: _repo, onChanged: _load),
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

class _NewPurchaseTabState extends State<_NewPurchaseTab>
    with AutomaticKeepAliveClientMixin {
  final _repo = PurchasesRepository();
  final _refCtrl = TextEditingController();
  ProviderEntity? _provider;
  final List<_CartItem> _cart = [];
  bool _saving = false;

  // Mantiene vivo el carrito mientras se permanezca dentro del apartado de
  // compras (al cambiar de pestana NUEVA COMPRA/PROVEEDORES/HISTORIAL).
  @override
  bool get wantKeepAlive => true;

  final List<TextEditingController> _qtyControllers = [];
  final List<TextEditingController> _costControllers = [];

  // En compras SÍ se permite comprar por caja/cajetilla (para eso existe la
  // conversión automática caja->piezas en PurchasesRepository.savePurchase),
  // solo se excluyen las promociones (no tiene sentido comprar una promo).
  List<ProductEntity> get _purchaseProducts =>
      widget.products.where((p) => p.isPromo != 1).toList();

  @override
  void dispose() {
    _refCtrl.dispose();
    for (final c in _qtyControllers) {
      c.dispose();
    }
    for (final c in _costControllers) {
      c.dispose();
    }
    super.dispose();
  }

  double _calcTotal() => _cart.fold(0, (a, c) => a + c.subtotal);

  Future<void> _save() async {
    if (_cart.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Agrega al menos un producto'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final purchase = PurchaseEntity(
        providerId: _provider?.id,
        reference: _refCtrl.text.toUpperCase(),
        items:
            _cart
                .map(
                  (c) => PurchaseItemEntity(
                    productId: c.product.id!,
                    productName: c.product.name,
                    quantity: c.quantity,
                    costPerUnit: c.cost,
                  ),
                )
                .toList(),
      );
      final purchaseId = await _repo.savePurchase(purchase: purchase);
      if (!mounted) return;

      final itemsForPdf = _cart
          .map(
            (c) => _PurchasePdfItem(
              name: c.product.name,
              quantity: c.quantity,
              cost: c.cost,
              subtotal: c.subtotal,
            ),
          )
          .toList();
      final total = _calcTotal();
      final providerName = _provider?.name ?? 'SIN PROVEEDOR';
      final reference = _refCtrl.text.toUpperCase();

      await _showPurchasePdf(
        context: context,
        purchaseId: purchaseId,
        providerName: providerName,
        reference: reference,
        items: itemsForPdf,
        total: total,
      );

      _refCtrl.clear();
      _provider = null;
      for (final c in _qtyControllers) {
        c.dispose();
      }
      for (final c in _costControllers) {
        c.dispose();
      }
      _qtyControllers.clear();
      _costControllers.clear();
      _cart.clear();
      widget.onSaved();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Compra registrada y stock actualizado'),
          backgroundColor: Colors.green,
        ),
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
        existing.quantity == existing.quantity.toInt() ? 0 : 2,
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
    var filtered = List<ProductEntity>.from(_purchaseProducts);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final primary = Theme.of(ctx).colorScheme.primary;
        return StatefulBuilder(
          builder: (ctx2, ss) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.7,
              maxChildSize: 0.95,
              builder:
                  (_, ctrl) => Padding(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.of(ctx2).viewInsets.bottom,
                      left: 16,
                      right: 16,
                      top: 16,
                    ),
                    child: Column(
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
                        Text(
                          'AGREGAR PRODUCTOS',
                          style: TextStyle(
                            color: primary,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: primary,
                              side: BorderSide(color: primary.withValues(alpha: 0.5)),
                            ),
                            icon: const Icon(Icons.add_box_outlined),
                            label: const Text(
                              'NUEVO PRODUCTO',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            onPressed: () async {
                              // Cerrar el picker y abrir el formulario de crear producto.
                              Navigator.of(ctx).pop();
                              await showModalBottomSheet(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor: const Color(0xFF1A1A1A),
                                shape: const RoundedRectangleBorder(
                                  borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
                                ),
                                builder: (_) => ProductFormSheet(
                                  product: null,
                                  onSaved: () {
                                    Navigator.of(context).pop();
                                    widget.onSaved();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Producto creado'),
                                        backgroundColor: Colors.green,
                                      ),
                                    );
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: searchCtrl,
                          onChanged: (q) {
                            ss(() {
                              final text = q.toLowerCase();
                              filtered =
                                  _purchaseProducts
                                      .where((p) => p.name.toLowerCase().contains(text))
                                      .toList();
                            });
                          },
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Buscar producto...',
                            hintStyle: const TextStyle(color: Colors.white24),
                            prefixIcon: const Icon(Icons.search, color: Colors.white38),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.05),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child:
                              filtered.isEmpty
                                  ? const Center(
                                    child: Text(
                                      'Sin coincidencias',
                                      style: TextStyle(color: Colors.white24),
                                    ),
                                  )
                                  : ListView.builder(
                                    controller: ctrl,
                                    itemCount: filtered.length,
                                    itemBuilder: (_, i) {
                                      final p = filtered[i];
                                      final inCart = _cart.any((c) => c.product.id == p.id);
                                      return ListTile(
                                        leading: CircleAvatar(
                                          backgroundColor: primary.withValues(alpha: 0.15),
                                          child: Text(
                                            p.name.substring(0, 1).toUpperCase(),
                                            style: TextStyle(
                                              color: primary,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        title: Text(
                                          p.name,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                        subtitle: Text(
                                          'Stock: ${p.stock.toStringAsFixed(0)}  |  Costo: \$${p.cost.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                            color: Colors.white38,
                                            fontSize: 11,
                                          ),
                                        ),
                                        trailing: ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor:
                                                inCart ? Colors.green : primary,
                                            padding: const EdgeInsets.symmetric(horizontal: 12),
                                          ),
                                          onPressed: () {
                                            _addToCart(p);
                                            ss(() {});
                                            if (_cart.where((c) => c.product.id == p.id).length ==
                                                1) {
                                              Navigator.of(ctx).pop();
                                            }
                                          },
                                          child: Text(
                                            inCart ? '+' : 'Agregar',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                            ),
                                          ),
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
    super.build(context);
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primary.withValues(alpha: 0.12), Colors.transparent],
            ),
            border: const Border(bottom: BorderSide(color: Colors.white10)),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<ProviderEntity>(
                      initialValue: _provider,
                      dropdownColor: const Color(0xFF1A1A1A),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Proveedor (opcional)',
                        labelStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      items:
                          widget.providers
                              .map((p) => DropdownMenuItem(value: p, child: Text(p.name)))
                              .toList(),
                      onChanged: (v) => setState(() => _provider = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _refCtrl,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [_UpperCaseFormatter()],
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Referencia / Factura',
                        labelStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                        prefixIcon: const Icon(Icons.receipt, color: Colors.white38, size: 18),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.05),
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
              Icon(
                Icons.shopping_cart,
                color: primary.withValues(alpha: 0.7),
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'CARRITO (${_cart.length})',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                  letterSpacing: 1,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primary,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                ),
                icon: const Icon(Icons.add, size: 16, color: Colors.white),
                label: const Text(
                  'AGREGAR PRODUCTO',
                  style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                ),
                onPressed: _openProductPicker,
              ),
            ],
          ),
        ),
        const Divider(color: Colors.white10, height: 1),
        // Tabla carrito
        Expanded(
          child:
              _cart.isEmpty
                  ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.shopping_basket_outlined,
                          color: Colors.white.withValues(alpha: 0.08),
                          size: 72,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'CARRITO VACIO',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.2),
                            fontSize: 14,
                            letterSpacing: 2,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Presiona "Agregar Producto" para empezar',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.15),
                            fontSize: 12,
                          ),
                        ),
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
                            const Expanded(
                              flex: 4,
                              child: Text(
                                'PRODUCTO',
                                style: TextStyle(
                                  color: Colors.white30,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                            const Expanded(
                              flex: 2,
                              child: Text(
                                'CANT',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white30,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                            const Expanded(
                              flex: 2,
                              child: Text(
                                'COSTO',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white30,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                            const Expanded(
                              flex: 2,
                              child: Text(
                                'SUBTOTAL',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  color: Colors.white30,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
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
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 4,
                                    child: Text(
                                      item.product.name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: Center(
                                      child: SizedBox(
                                        width: 56,
                                        child: TextField(
                                          keyboardType: const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          decoration: InputDecoration(
                                            filled: true,
                                            fillColor: Colors.white.withValues(alpha: 0.05),
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(6),
                                              borderSide: BorderSide.none,
                                            ),
                                            contentPadding: const EdgeInsets.symmetric(vertical: 4),
                                          ),
                                          controller: _qtyControllers[i],
                                          onTap: () => _selectAll(_qtyControllers[i]),
                                          onChanged: (v) => _updateQty(i, double.tryParse(v) ?? 1),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: Center(
                                      child: SizedBox(
                                        width: 64,
                                        child: TextField(
                                          keyboardType: const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(color: Colors.white, fontSize: 13),
                                          decoration: InputDecoration(
                                            prefixText: '\$',
                                            prefixStyle: const TextStyle(
                                              color: Colors.white38,
                                              fontSize: 10,
                                            ),
                                            filled: true,
                                            fillColor: Colors.white.withValues(alpha: 0.05),
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(6),
                                              borderSide: BorderSide.none,
                                            ),
                                            contentPadding: const EdgeInsets.symmetric(vertical: 4),
                                          ),
                                          controller: _costControllers[i],
                                          onTap: () => _selectAll(_costControllers[i]),
                                          onChanged: (v) => _updateCost(i, double.tryParse(v) ?? 0),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      '\${item.subtotal.toStringAsFixed(2)}',
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                        color: Colors.greenAccent,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 36,
                                    child: IconButton(
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: Colors.redAccent,
                                        size: 18,
                                      ),
                                      onPressed: () => _removeFromCart(i),
                                      padding: EdgeInsets.zero,
                                    ),
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
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'TOTAL COMPRA',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                      letterSpacing: 1,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '\$${_calcTotal().toStringAsFixed(2)}',
                    style: TextStyle(
                      color: primary,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
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
                  icon:
                      _saving
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                          : const Icon(Icons.check_circle, color: Colors.white),
                  label: Text(
                    _saving ? 'REGISTRANDO...' : 'REGISTRAR COMPRA',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
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

class _ProvidersTab extends StatefulWidget {
  final List<ProviderEntity> providers;
  final List<ProductEntity> products;
  final PurchasesRepository repo;
  final VoidCallback onChanged;
  const _ProvidersTab({required this.providers, required this.products, required this.repo, required this.onChanged});

  @override
  State<_ProvidersTab> createState() => _ProvidersTabState();
}

class _ProvidersTabState extends State<_ProvidersTab> {
  List<ProductEntity> get _parentProducts =>
      widget.products.where((p) => p.parentId == null && p.isPromo != 1).toList();

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.add),
            label: const Text('AGREGAR PROVEEDOR'),
            onPressed: () => _editProvider(context, null),
          ),
        ),
        Expanded(
          child:
              widget.providers.isEmpty
                  ? const EmptyState(message: 'No hay proveedores', icon: Icons.store_outlined)
                  : ListView.builder(
                    itemCount: widget.providers.length,
                    itemBuilder: (_, i) {
                      final p = widget.providers[i];
                      return ListTile(
                        leading: Icon(Icons.store, color: primary),
                        title: Text(
                          p.name,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          '${p.phone.isNotEmpty ? p.phone : ''}${p.category.isNotEmpty ? ' | ${p.category}' : ''}${p.visitDays.isNotEmpty ? ' | ${p.visitDays.join(', ')}' : ''}',
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, color: Colors.white38),
                              onPressed: () => _editProvider(context, p),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () async {
                                await widget.repo.deleteProvider(p.id!);
                                widget.onChanged();
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }

  Future<void> _editProvider(BuildContext context, ProviderEntity? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final phoneCtrl = TextEditingController(text: existing?.phone ?? '');
    final emailCtrl = TextEditingController(text: existing?.email ?? '');
    final addressCtrl = TextEditingController(text: existing?.address ?? '');
    final contactCtrl = TextEditingController(text: existing?.contactName ?? '');
    final notesCtrl = TextEditingController(text: existing?.notes ?? '');
    final categoryCtrl = TextEditingController(text: existing?.category ?? 'General');
    final List<String> days = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];
    final selectedDays = List<String>.from(existing?.visitDays ?? []);
    final selectedProductIds = List<int>.from(await widget.repo.getProviderProductIds(existing?.id ?? -1));

    if (!context.mounted) return;
    await showDialog(
      context: context,
      builder:
          (_) => StatefulBuilder(
            builder:
                (ctx, ss) => AlertDialog(
                  backgroundColor: const Color(0xFF1A1A1A),
                  title: Text(
                    existing == null ? 'NUEVO PROVEEDOR' : 'EDITAR PROVEEDOR',
                    style: const TextStyle(color: Color(0xFFFB8C00)),
                  ),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppTextField(
                          controller: nameCtrl,
                          label: 'Nombre',
                          icon: Icons.store,
                          textCapitalization: TextCapitalization.characters,
                          inputFormatters: [_UpperCaseFormatter()],
                        ),
                        _PhoneField(controller: phoneCtrl, label: 'Teléfono'),
                        AppTextField(
                          controller: emailCtrl,
                          label: 'Correo',
                          icon: Icons.email,
                          keyboardType: TextInputType.emailAddress,
                          textCapitalization: TextCapitalization.none,
                          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9@.\-_]+'))],
                        ),
                        AppTextField(
                          controller: addressCtrl,
                          label: 'Dirección',
                          icon: Icons.location_on,
                          textCapitalization: TextCapitalization.characters,
                          inputFormatters: [_UpperCaseFormatter()],
                        ),
                        AppTextField(
                          controller: contactCtrl,
                          label: 'Nombre de contacto',
                          icon: Icons.person,
                          textCapitalization: TextCapitalization.characters,
                          inputFormatters: [_UpperCaseFormatter()],
                        ),
                        AppTextField(
                          controller: notesCtrl,
                          label: 'Notas',
                          icon: Icons.notes,
                          maxLines: 2,
                          textCapitalization: TextCapitalization.characters,
                          inputFormatters: [_UpperCaseFormatter()],
                        ),
                        const SizedBox(height: 12),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('DÍAS DE VISITA', style: TextStyle(color: Colors.white38, fontSize: 11)),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children:
                              days
                                  .map(
                                    (d) => FilterChip(
                                      label: Text(d, style: const TextStyle(fontSize: 11)),
                                      selected: selectedDays.contains(d),
                                      selectedColor: const Color(0xFFFB8C00).withValues(alpha: 0.3),
                                      backgroundColor: Colors.white10,
                                      checkmarkColor: const Color(0xFFFB8C00),
                                      onSelected: (sel) {
                                        ss(() {
                                          if (sel) {
                                            selectedDays.add(d);
                                          } else {
                                            selectedDays.remove(d);
                                          }
                                        });
                                      },
                                    ),
                                  )
                                  .toList(),
                        ),
                        const SizedBox(height: 16),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('PRODUCTOS QUE SURTE', style: TextStyle(color: Colors.white38, fontSize: 11)),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children:
                              _parentProducts
                                  .map(
                                    (pr) => FilterChip(
                                      label: Text(pr.name, style: const TextStyle(fontSize: 11)),
                                      selected: selectedProductIds.contains(pr.id),
                                      selectedColor: const Color(0xFFFB8C00).withValues(alpha: 0.3),
                                      backgroundColor: Colors.white10,
                                      checkmarkColor: const Color(0xFFFB8C00),
                                      onSelected: (sel) {
                                        ss(() {
                                          if (sel) {
                                            selectedProductIds.add(pr.id!);
                                          } else {
                                            selectedProductIds.remove(pr.id);
                                          }
                                        });
                                      },
                                    ),
                                  )
                                  .toList(),
                        ),
                      ],
                    ),
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
                        final provider = ProviderEntity(
                          id: existing?.id,
                          name: nameCtrl.text.trim(),
                          phone: phoneCtrl.text.trim(),
                          email: emailCtrl.text.trim(),
                          address: addressCtrl.text.trim(),
                          contactName: contactCtrl.text.trim(),
                          notes: notesCtrl.text.trim(),
                          category: categoryCtrl.text.trim().isEmpty ? 'General' : categoryCtrl.text.trim(),
                          visitDays: selectedDays,
                        );
                        int providerId;
                        if (existing == null) {
                          providerId = await widget.repo.insertProvider(provider);
                        } else {
                          providerId = existing.id!;
                          await widget.repo.updateProvider(provider);
                        }
                        await widget.repo.setProviderProducts(providerId, selectedProductIds);
                        if (ctx.mounted) Navigator.pop(ctx);
                        widget.onChanged();
                      },
                      child: const Text('GUARDAR', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
          ),
    );
  }
}

class _PhoneField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  const _PhoneField({required this.controller, required this.label});

  @override
  State<_PhoneField> createState() => _PhoneFieldState();
}

class _PhoneFieldState extends State<_PhoneField> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: widget.controller,
        keyboardType: TextInputType.phone,
        maxLength: 12,
        buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          _PhoneMaskFormatter(),
        ],
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: '000-000-0000',
          labelStyle: const TextStyle(color: Colors.white38, fontSize: 14),
          hintStyle: const TextStyle(color: Colors.white24),
          prefixIcon: const Icon(Icons.phone, color: Colors.white60),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.05),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        ),
      ),
    );
  }
}

class _PhoneMaskFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length > 10) return oldValue;
    String masked;
    if (digits.length >= 7) {
      masked = '${digits.substring(0, 3)}-${digits.substring(3, 6)}-${digits.substring(6)}';
    } else if (digits.length >= 4) {
      masked = '${digits.substring(0, 3)}-${digits.substring(3)}';
    } else {
      masked = digits;
    }
    final selectionIndex = masked.length;
    return TextEditingValue(
      text: masked,
      selection: TextSelection.collapsed(offset: selectionIndex),
    );
  }
}

class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
      composing: newValue.composing,
    );
  }
}

class _PurchasePdfItem {
  final String name;
  final double quantity;
  final double cost;
  final double subtotal;
  _PurchasePdfItem({required this.name, required this.quantity, required this.cost, required this.subtotal});
}

Future<void> _showPurchasePdf({
  required BuildContext context,
  required int purchaseId,
  required String providerName,
  required String reference,
  required List<_PurchasePdfItem> items,
  required double total,
  String createdBy = '',
}) async {
  final prefs = PreferencesService();
  final businessName = prefs.businessName.trim().isEmpty ? 'MI NEGOCIO' : prefs.businessName.trim();
  final atendio = createdBy.trim().isNotEmpty ? createdBy.trim() : prefs.userName;

  pw.MemoryImage? logoImage;
  final logoBytes = await _loadLogoBytes();
  if (logoBytes != null) {
    logoImage = pw.MemoryImage(logoBytes);
  }

  final pdf = pw.Document();
  final now = DateTime.now();
  final dateStr =
      '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}  ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

  const black = PdfColors.black;
  final primaryColor = PdfColor.fromInt(prefs.primaryColorValue);
  const grey = PdfColors.grey700;

  final titleStyle = pw.TextStyle(
    fontWeight: pw.FontWeight.bold,
    fontSize: 12,
    color: black,
    letterSpacing: 1,
  );
  final normalStyle = pw.TextStyle(fontSize: 9.5, color: black);
  final boldStyle = pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: black);
  final italicStyle = pw.TextStyle(fontStyle: pw.FontStyle.italic, fontSize: 8.5, color: grey);
  final smallStyle = pw.TextStyle(fontSize: 8, color: grey);
  final tinyStyle = pw.TextStyle(fontSize: 7.5, color: grey);

  // Dirección formateada en líneas (igual que el encabezado de ventas).
  final headerLines = <String>[];
  final addressPart1 = [
    prefs.businessStreet,
    if (prefs.businessExtNumber.isNotEmpty)
      'No. ${prefs.businessExtNumber}${prefs.businessIntNumber.isNotEmpty ? ' Int. ${prefs.businessIntNumber}' : ''}',
  ].where((s) => s.isNotEmpty).toList();
  final addressPart2 = [
    prefs.businessColony,
    if (prefs.businessCity.isNotEmpty) prefs.businessCity,
  ].where((s) => s.isNotEmpty).toList();
  final addressPart3 = [
    if (prefs.businessState.isNotEmpty) prefs.businessState,
    if (prefs.businessZipCode.isNotEmpty) 'CP ${prefs.businessZipCode}',
  ].where((s) => s.isNotEmpty).toList();
  if (addressPart1.isNotEmpty) headerLines.add(addressPart1.join(' | '));
  if (addressPart2.isNotEmpty) headerLines.add(addressPart2.join(' | '));
  if (addressPart3.isNotEmpty) headerLines.add(addressPart3.join(' | '));

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
            pw.Center(child: pw.Text(businessName.toUpperCase(), style: titleStyle)),
            pw.SizedBox(height: 1),
            if (prefs.businessSlogan.isNotEmpty)
              pw.Center(
                child: pw.Text('"${prefs.businessSlogan}"', style: italicStyle),
              ),
            pw.SizedBox(height: 2),
            ...headerLines.map(
              (line) => pw.Center(child: pw.Text(line, style: tinyStyle)),
            ),
            if (prefs.businessWhatsapp.isNotEmpty)
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.center,
                children: [
                  pw.Text('Whats: ', style: tinyStyle),
                  pw.Text(prefs.businessWhatsapp, style: smallStyle),
                ],
              ),
            pw.SizedBox(height: 2),
            pw.Divider(color: primaryColor, thickness: 0.8),
            pw.Center(
              child: pw.Text(
                'COMPROBANTE DE COMPRA',
                style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: black),
              ),
            ),
            pw.SizedBox(height: 2),
            pw.Center(child: pw.Text('Folio: C-$purchaseId  |  $dateStr', style: smallStyle)),
            if (atendio.isNotEmpty)
              pw.Center(child: pw.Text('Atendio: $atendio', style: smallStyle)),
            pw.SizedBox(height: 2),
            pw.Divider(color: primaryColor, thickness: 0.8),
            pw.Text('Proveedor:', style: boldStyle),
            pw.Text(providerName, style: normalStyle),
            if (reference.isNotEmpty) ...[
              pw.SizedBox(height: 2),
              pw.Text('Referencia: $reference', style: normalStyle),
            ],
            pw.SizedBox(height: 2),
            pw.Divider(color: primaryColor, thickness: 0.8),
            pw.Row(
              children: [
                pw.Expanded(flex: 4, child: pw.Text('PRODUCTO', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
                pw.Expanded(flex: 2, child: pw.Text('CANT', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
                pw.Expanded(flex: 2, child: pw.Text('P.UNIT', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
                pw.Expanded(flex: 2, child: pw.Text('TOTAL', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
              ],
            ),
            pw.Divider(thickness: 0.5),
            ...items.map((i) {
              return pw.Row(
                children: [
                  pw.Expanded(flex: 4, child: pw.Text(i.name, style: const pw.TextStyle(fontSize: 9))),
                  pw.Expanded(flex: 2, child: pw.Text(i.quantity.toStringAsFixed(0), style: const pw.TextStyle(fontSize: 9))),
                  pw.Expanded(flex: 2, child: pw.Text('\$${i.cost.toStringAsFixed(2)}', style: const pw.TextStyle(fontSize: 9))),
                  pw.Expanded(flex: 2, child: pw.Text('\$${i.subtotal.toStringAsFixed(2)}', style: const pw.TextStyle(fontSize: 9))),
                ],
              );
            }),
            pw.Divider(),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('TOTAL', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
                pw.Text('\$${total.toStringAsFixed(2)}', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Center(
              child: pw.Text('Documento interno / control de inventario', style: const pw.TextStyle(fontSize: 7)),
            ),
          ],
        );
      },
    ),
  );


  await Printing.layoutPdf(
    onLayout: (PdfPageFormat format) async => pdf.save(),
    name: 'compra_$purchaseId.pdf',
  );
}

Future<Uint8List?> _loadLogoBytes() async {
  final prefs = PreferencesService();
  if (prefs.logoPath.isNotEmpty) {
    final file = File(prefs.logoPath);
    if (await file.exists()) return file.readAsBytes();
  }
  if (prefs.logoUrl.isNotEmpty) {
    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(prefs.logoUrl));
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final bytes = <int>[];
        await for (final chunk in res) {
          bytes.addAll(chunk);
        }
        client.close();
        return Uint8List.fromList(bytes);
      }
      client.close();
    } catch (_) {}
  }
  return null;
}

class _HistoryTab extends StatelessWidget {
  final List<Map<String, dynamic>> history;
  const _HistoryTab({required this.history});

  Future<void> _showDetail(BuildContext context, Map<String, dynamic> h) async {
    final repo = PurchasesRepository();
    final details = await repo.getPurchaseDetails(h['id'] as int);
    if (!context.mounted) return;
    final date = DateTime.tryParse(h['date'] ?? '') ?? DateTime.now();
    await showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text('DETALLE DE COMPRA', style: TextStyle(color: Color(0xFFFB8C00))),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      h['provider_name'] ?? 'Sin proveedor',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${date.day}/${date.month}/${date.year}${(h['reference'] ?? '').toString().isNotEmpty ? ' | ${h['reference']}' : ''}',
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                    if ((h['created_by'] ?? '').toString().trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Usuario: ${h['created_by']}',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ),
                    const Divider(color: Colors.white24, height: 24),
                    if (details.isEmpty)
                      const Text('Sin detalle disponible', style: TextStyle(color: Colors.white38))
                    else
                      ...details.map((d) {
                        final qty = (d['quantity'] as num).toDouble();
                        final cost = (d['cost_per_unit'] as num).toDouble();
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 4,
                                child: Text(
                                  d['product_name']?.toString() ?? 'Producto eliminado',
                                  style: const TextStyle(color: Colors.white, fontSize: 13),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  '${qty.toStringAsFixed(0)} x \$${cost.toStringAsFixed(2)}',
                                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  '\$${(qty * cost).toStringAsFixed(2)}',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(color: Colors.greenAccent, fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    const Divider(color: Colors.white24, height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'TOTAL',
                          style: TextStyle(color: Colors.white38, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '\$${(h['total'] as num).toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Color(0xFFFB8C00),
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton.icon(
                onPressed: () {
                  final pdfItems = details.map((d) {
                    final qty = (d['quantity'] as num).toDouble();
                    final cost = (d['cost_per_unit'] as num).toDouble();
                    return _PurchasePdfItem(
                      name: d['product_name']?.toString() ?? 'Producto',
                      quantity: qty,
                      cost: cost,
                      subtotal: qty * cost,
                    );
                  }).toList();
                  final total = (h['total'] as num).toDouble();
                  Navigator.pop(ctx);
                  _showPurchasePdf(
                    context: context,
                    purchaseId: h['id'] as int,
                    providerName: h['provider_name']?.toString() ?? 'Sin proveedor',
                    reference: (h['reference'] ?? '').toString(),
                    items: pdfItems,
                    total: total,
                    createdBy: (h['created_by'] ?? '').toString(),
                  );
                },
                style: TextButton.styleFrom(foregroundColor: const Color(0xFFFB8C00)),
                icon: const Icon(Icons.print, size: 18),
                label: const Text('REIMPRIMIR PDF'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('CERRAR', style: TextStyle(color: Colors.white38)),
              ),
            ],
          ),
    );
  }

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
          onTap: () => _showDetail(context, h),
        );
      },
    );
  }
}
