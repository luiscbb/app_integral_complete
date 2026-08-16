import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../core/utils/smart_image.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_text_field.dart';
import '../../../../core/widgets/empty_state.dart';
import '../../../../core/routes/app_routes.dart';
import '../../data/repositories/product_repository.dart';
import '../../domain/entities/product_entity.dart';
import '../widgets/product_sale_card.dart';
import '../../../sales/presentation/pages/create_promo_page.dart';
import '../../../purchases/data/repositories/purchases_repository.dart';
import '../../../purchases/domain/entities/provider_entity.dart';

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final _repo = ProductRepository();
  final _searchCtrl = TextEditingController();
  List<ProductEntity> _products = [];
  List<ProductEntity> _filtered = [];
  List<String> _categories = [];
  String? _selectedCategory;
  bool _isLoading = true;
  bool _isGrid = true;

  @override
  void initState() {
    super.initState();
    _refresh();
    _searchCtrl.addListener(_filter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _filter() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filtered = _products.where((p) {
        final matchesSearch = q.isEmpty || p.name.toLowerCase().contains(q);
        final matchesCategory = _selectedCategory == null || p.category == _selectedCategory;
        return matchesSearch && matchesCategory;
      }).toList();
    });
  }

  void _selectCategory(String? category) {
    setState(() {
      _selectedCategory = category;
      _filter();
    });
  }

  Future<void> _refresh() async {
    setState(() => _isLoading = true);
    try {
      final data = await _repo.getAll();
      final cats = await _repo.getCategories();
      if (mounted) {
        setState(() {
          _products = data;
          _categories = cats;
          _filter();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatStock(double stock, int pieces) {
    if (pieces <= 1) return '${stock.toInt()} pz';
    final boxes = stock ~/ pieces;
    final loose = (stock % pieces).toInt();
    if (boxes == 0) return '$loose pz';
    if (loose == 0) return '$boxes Caj';
    return '$boxes Caj + $loose pz';
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'INVENTARIO',
          style: TextStyle(color: Color(0xFF43A047), fontWeight: FontWeight.bold),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(98),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
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
              if (_categories.isNotEmpty)
                SizedBox(
                  height: 38,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: const Text('TODOS', style: TextStyle(fontSize: 11)),
                          selected: _selectedCategory == null,
                          selectedColor: const Color(0xFF43A047).withValues(alpha: 0.3),
                          backgroundColor: Colors.white10,
                          checkmarkColor: const Color(0xFF43A047),
                          labelStyle: TextStyle(
                            color: _selectedCategory == null ? const Color(0xFF43A047) : Colors.white70,
                            fontWeight: _selectedCategory == null ? FontWeight.bold : FontWeight.normal,
                          ),
                          onSelected: (_) => _selectCategory(null),
                        ),
                      ),
                      ..._categories.map((c) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(c, style: const TextStyle(fontSize: 11)),
                          selected: _selectedCategory == c,
                          selectedColor: const Color(0xFF43A047).withValues(alpha: 0.3),
                          backgroundColor: Colors.white10,
                          checkmarkColor: const Color(0xFF43A047),
                          labelStyle: TextStyle(
                            color: _selectedCategory == c ? const Color(0xFF43A047) : Colors.white70,
                            fontWeight: _selectedCategory == c ? FontWeight.bold : FontWeight.normal,
                          ),
                          onSelected: (_) => _selectCategory(c),
                        ),
                      )),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(_isGrid ? Icons.view_list : Icons.grid_view, color: Colors.white70),
            onPressed: () => setState(() => _isGrid = !_isGrid),
          ),
          IconButton(
            icon: const Icon(Icons.star_border, color: Colors.orange),
            tooltip: 'Crear Promo',
            onPressed:
                () => Navigator.pushNamed(context, AppRoutes.createPromo).then((_) => _refresh()),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _filtered.isEmpty
              ? EmptyState(
                message: 'No hay productos',
                icon: Icons.inventory_2_outlined,
                actionLabel: 'Agregar',
                onAction: () => _showForm(null),
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
                  return GestureDetector(
                    onTap: () => _showForm(p),
                    child: ProductSaleCard(
                      product: p,
                      quantity: 0,
                      onAdd: () => _showForm(p),
                      onRemove: () {},
                    ),
                  );
                },
              )
              : ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: _filtered.length,
                itemBuilder: (context, i) {
                  final p = _filtered[i];
                  final isPromo = p.isPromo == 1;
                  final isLow = p.stock <= 5 && p.stock > 0;
                  final isEmpty = p.stock <= 0;
                  return Card(
                    child: ListTile(
                      leading: SizedBox(
                        width: 48,
                        height: 48,
                        child:
                            isPromo
                                ? const Icon(Icons.stars, color: Colors.orange, size: 36)
                                : SmartImage(
                                  imagePath: p.imagePath,
                                  size: 48,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                      ),
                      title: Text(
                        p.name,
                        style: TextStyle(
                          color: isPromo ? Colors.orange : Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color:
                                  isEmpty
                                      ? Colors.red.withValues(alpha: 0.2)
                                      : isLow
                                      ? Colors.orange.withValues(alpha: 0.2)
                                      : Colors.green.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _formatStock(p.stock, p.piecesPerUnit),
                              style: TextStyle(
                                color:
                                    isEmpty
                                        ? Colors.red
                                        : isLow
                                        ? Colors.orange
                                        : Colors.green,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '\$${p.price.toStringAsFixed(2)}',
                            style: const TextStyle(color: Colors.greenAccent, fontSize: 12),
                          ),
                        ],
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.edit, color: isPromo ? Colors.orange : primary),
                        onPressed: () => _showForm(p),
                      ),
                    ),
                  );
                },
              ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showForm(null),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  void _showForm(ProductEntity? product) {
    // Las promos se editan en su propia página (componentes, costo, foto, eliminar).
    if (product != null && product.isPromo == 1) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => CreatePromoPage(promo: product)),
      ).then((_) => _refresh());
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder:
          (_) => ProductFormSheet(
            product: product,
            onSaved: () {
              Navigator.pop(context);
              _refresh();
            },
          ),
    );
  }
}

class ProductFormSheet extends StatefulWidget {
  final ProductEntity? product;
  final VoidCallback onSaved;
  const ProductFormSheet({super.key, this.product, required this.onSaved});

  @override
  State<ProductFormSheet> createState() => ProductFormSheetState();
}

class ProductFormSheetState extends State<ProductFormSheet> {
  final _repo = ProductRepository();
  final _purchaseRepo = PurchasesRepository();
  late final TextEditingController _descCtrl;
  late final TextEditingController _presentationCtrl;
  late final TextEditingController _barcodeCtrl;
  late final TextEditingController _stockCtrl;
  late final TextEditingController _costCtrl;
  late final TextEditingController _piecesCtrl;
  late final TextEditingController _priceUnitCtrl;
  late final TextEditingController _priceCajaCtrl;
  String? _imagePath;
  String? _category;
  List<String> _categories = [];
  List<ProviderEntity> _providers = [];
  List<int> _selectedProviderIds = [];
  bool _saving = false;
  double _costCaja = 0;
  late final bool _canEditFields;

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    _canEditFields = p == null || (p.isPromo != 1 && p.parentId == null);
    _descCtrl = TextEditingController(text: p?.description ?? '');
    _presentationCtrl = TextEditingController(text: p?.presentation ?? '');
    _barcodeCtrl = TextEditingController(text: p?.barcode ?? '');
    _stockCtrl = TextEditingController(text: p?.stock.toString() ?? '0');
    _costCtrl = TextEditingController(text: p?.cost.toString() ?? '');
    _piecesCtrl = TextEditingController(text: p?.piecesPerUnit.toString() ?? '0');
    _priceUnitCtrl = TextEditingController(text: p?.price.toString() ?? '');
    _priceCajaCtrl = TextEditingController(
      text: p != null && p.piecesPerUnit > 1 ? (p.price * p.piecesPerUnit).toString() : '',
    );
    _imagePath = p?.imagePath;
    _category = (p?.category.isNotEmpty ?? false) ? p!.category : null;
    _costCaja = (p?.cost ?? 0) * (p?.piecesPerUnit ?? 0);
    _loadCategories();
    _loadProviders();
  }

  Future<void> _loadProviders() async {
    final providers = await _purchaseRepo.getProviders();
    if (widget.product?.id != null) {
      final ids = await _purchaseRepo.getProductProviderIds(widget.product!.id!);
      if (mounted) {
        setState(() {
          _providers = providers;
          _selectedProviderIds = ids;
        });
      }
    } else if (mounted) {
      setState(() => _providers = providers);
    }
  }

  Future<void> _loadCategories() async {
    final cats = await _repo.getCategories();
    if (mounted) {
      setState(() {
        final set = LinkedHashSet<String>.from(cats);
        if (_category != null && _category!.isNotEmpty) set.add(_category!);
        _categories = set.toList();
      });
    }
  }

  Future<void> _addCategoryDialog() async {
    final ctrl = TextEditingController();
    final primary = Theme.of(context).colorScheme.primary;
    final newCat = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text('NUEVA CATEGORÍA', style: TextStyle(color: primary, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Ej. BEBIDAS, COMIDA, CIGARROS',
            hintStyle: TextStyle(color: Colors.white24),
          ),
          onChanged: (v) {
            final up = v.toUpperCase();
            if (up != v) {
              ctrl.value = TextEditingValue(
                text: up,
                selection: TextSelection.collapsed(offset: up.length),
              );
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: primary),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim().toUpperCase()),
            child: const Text('CREAR', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (newCat != null && newCat.isNotEmpty) {
      await _repo.addCategory(newCat);
      await _loadCategories();
      if (mounted) setState(() => _category = newCat);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _descCtrl,
      _presentationCtrl,
      _barcodeCtrl,
      _stockCtrl,
      _costCtrl,
      _piecesCtrl,
      _priceUnitCtrl,
      _priceCajaCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _recalcCostCaja() {
    final c = double.tryParse(_costCtrl.text) ?? 0;
    final p = int.tryParse(_piecesCtrl.text) ?? 1;
    setState(() => _costCaja = c * p);
  }

  Future<void> _scanBarcode() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _BarcodeScannerPage()),
    );
    if (result != null) setState(() => _barcodeCtrl.text = result);
  }

  Future<void> _pickImage() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (ctx) {
        final primary = Theme.of(ctx).colorScheme.primary;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.camera_alt, color: primary),
              title: const Text('Cámara', style: TextStyle(color: Colors.white)),
              onTap: () => _pickFrom(ImageSource.camera),
            ),
            ListTile(
              leading: Icon(Icons.photo_library, color: primary),
              title: const Text('Galería', style: TextStyle(color: Colors.white)),
              onTap: () => _pickFrom(ImageSource.gallery),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickFrom(ImageSource source) async {
    Navigator.pop(context);
    final img = await ImagePicker().pickImage(source: source, imageQuality: 35, maxWidth: 800);
    if (img != null) setState(() => _imagePath = img.path);
  }

  Future<void> _save() async {
    if (_descCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('La descripción es obligatoria'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final costText = _costCtrl.text.trim();
    final priceUnitText = _priceUnitCtrl.text.trim();
    final stockText = _stockCtrl.text.trim();

    if (costText.isEmpty || priceUnitText.isEmpty || stockText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Completa costo, precio de venta y existencia'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final cost = double.tryParse(costText) ?? 0;
    final priceUnit = double.tryParse(priceUnitText) ?? 0;
    final piecesText = widget.product?.parentId == null ? _piecesCtrl.text.trim() : '0';
    final pieces = int.tryParse(piecesText) ?? 0;
    final costCaja = cost * pieces;
    final priceCaja = double.tryParse(_priceCajaCtrl.text.trim());

    if (widget.product?.parentId != null) {
      // Producto hijo (paquete/caja): validar contra su propio costo y precio.
      if (priceUnit < cost) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'El precio de venta (\$${priceUnit.toStringAsFixed(2)}) no puede ser menor al costo (\$${cost.toStringAsFixed(2)})',
            ),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    } else {
      // Producto padre/independiente.
      if (priceUnit < cost) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'El precio por pieza (\$${priceUnit.toStringAsFixed(2)}) no puede ser menor al costo (\$${cost.toStringAsFixed(2)})',
            ),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      if (priceCaja != null && priceCaja < costCaja) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'El precio por caja (\$${priceCaja.toStringAsFixed(2)}) no puede ser menor al costo de caja (\$${costCaja.toStringAsFixed(2)})',
            ),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    setState(() => _saving = true);
    try {
      final p = ProductEntity(
        id: widget.product?.id,
        barcode: _barcodeCtrl.text.trim().isEmpty ? null : _barcodeCtrl.text.trim(),
        name: _descCtrl.text.trim().toUpperCase(),
        description: _descCtrl.text.trim().toUpperCase(),
        price: priceUnit,
        cost: cost,
        stock: double.tryParse(stockText) ?? 0,
        imagePath: _imagePath,
        piecesPerUnit: pieces,
        isPromo: widget.product?.isPromo ?? 0,
        category: _category ?? '',
        presentation: _presentationCtrl.text.trim().toUpperCase(),
      );
      await _repo.insert(p, priceCaja: widget.product?.parentId == null ? priceCaja : null);
      if (widget.product?.id != null) {
        await _purchaseRepo.setProductProviders(widget.product!.id!, _selectedProviderIds);
      }
      widget.onSaved();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 20,
        right: 20,
        top: 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: _pickImage,
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: primary.withValues(alpha: 0.5)),
                    ),
                    child: SmartImage(imagePath: _imagePath, placeholderIcon: Icons.add_a_photo),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  widget.product == null ? 'NUEVO PRODUCTO' : 'EDITAR PRODUCTO',
                  style: TextStyle(color: primary, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const Spacer(),
                IconButton(icon: Icon(Icons.add_a_photo, color: primary), onPressed: _pickImage),
              ],
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: _barcodeCtrl,
              label: 'Código de barras / QR',
              icon: Icons.qr_code,
              textCapitalization: TextCapitalization.characters,
              suffixIcon: IconButton(
                icon: Icon(Icons.qr_code_scanner, color: primary),
                onPressed: _scanBarcode,
              ),
            ),
            AppTextField(
              controller: _descCtrl,
              label: 'Descripción *',
              icon: Icons.description,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9ñÑáéíóúÁÉÍÓÚüÜ\.\s\-/_#%&()]+')),
                TextInputFormatter.withFunction((oldValue, newValue) {
                  return TextEditingValue(
                    text: newValue.text.toUpperCase(),
                    selection: newValue.selection,
                    composing: newValue.composing,
                  );
                }),
              ],
            ),
            AppTextField(
              controller: _presentationCtrl,
              label: 'Presentación (ej. 355ml, 1lt, cajetilla)',
              icon: Icons.local_drink,
              textCapitalization: TextCapitalization.characters,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Categoría',
                      labelStyle: const TextStyle(color: Colors.white38),
                      prefixIcon: Icon(Icons.category, color: primary, size: 20),
                      border: const OutlineInputBorder(),
                    ),
                    child: DropdownButton<String>(
                      value: _categories.contains(_category) ? _category : null,
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1A1A1A),
                      style: const TextStyle(color: Colors.white),
                      underline: const SizedBox.shrink(),
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('Sin categoría', style: TextStyle(color: Colors.white38)),
                        ),
                        ..._categories.map(
                          (c) => DropdownMenuItem<String>(value: c, child: Text(c)),
                        ),
                      ],
                      onChanged: (v) => setState(() => _category = v),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.add_circle, color: primary),
                  tooltip: 'Nueva categoría',
                  onPressed: _addCategoryDialog,
                ),
              ],
            ),
            const Divider(color: Colors.red, thickness: 0.5),
            Row(
              children: [
                Expanded(
                  child: AppTextField(
                    controller: _costCtrl,
                    label: 'Costo p/Pz',
                    icon: Icons.monetization_on,
                    isNumber: true,
                    selectAllOnTap: true,
                    onChanged: (_) => _recalcCostCaja(),
                  ),
                ),
                if (widget.product?.parentId == null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: AppTextField(
                      controller: _piecesCtrl,
                      label: 'Pz x Caja',
                      icon: Icons.grid_view,
                      isNumber: true,
                      selectAllOnTap: true,
                      onChanged: (_) => _recalcCostCaja(),
                    ),
                  ),
                ],
              ],
            ),
            if (widget.product?.parentId == null)
              Text(
                'Costo Total Caja: \$${_costCaja.toStringAsFixed(2)}',
                style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
              ),
            const Divider(color: Colors.red, thickness: 0.5),
            Row(
              children: [
                Expanded(
                  child: AppTextField(
                    controller: _priceUnitCtrl,
                    label: 'Venta p/Pz',
                    icon: Icons.sell,
                    isNumber: true,
                    selectAllOnTap: true,
                  ),
                ),
                if (widget.product?.parentId == null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: AppTextField(
                      controller: _priceCajaCtrl,
                      label: 'Venta p/Caja',
                      icon: Icons.inventory_2,
                      isNumber: true,
                      selectAllOnTap: true,
                    ),
                  ),
                ],
              ],
            ),
            AppTextField(
              controller: _stockCtrl,
              label:
                  widget.product != null && !_canEditFields
                      ? 'Existencia (automática)'
                      : 'Existencia Actual (Pzs)',
              icon: Icons.storage,
              isNumber: true,
              selectAllOnTap: true,
              enabled: widget.product == null || _canEditFields,
            ),
            if (_providers.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('PROVEEDORES QUE SURTEN ESTE PRODUCTO', style: TextStyle(color: Colors.white38, fontSize: 11)),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children:
                    _providers
                        .map(
                          (pr) => FilterChip(
                            label: Text(pr.name, style: const TextStyle(fontSize: 11)),
                            selected: _selectedProviderIds.contains(pr.id),
                            selectedColor: const Color(0xFFFB8C00).withValues(alpha: 0.3),
                            backgroundColor: Colors.white10,
                            checkmarkColor: const Color(0xFFFB8C00),
                            onSelected: (sel) {
                              setState(() {
                                if (sel) {
                                  _selectedProviderIds.add(pr.id!);
                                } else {
                                  _selectedProviderIds.remove(pr.id);
                                }
                              });
                            },
                          ),
                        )
                        .toList(),
              ),
            ],
            const SizedBox(height: 8),
            AppButton(
              label: widget.product == null ? 'REGISTRAR' : 'ACTUALIZAR',
              isLoading: _saving,
              onPressed: _save,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _BarcodeScannerPage extends StatefulWidget {
  const _BarcodeScannerPage();
  @override
  State<_BarcodeScannerPage> createState() => _BarcodeScannerPageState();
}

class _BarcodeScannerPageState extends State<_BarcodeScannerPage> {
  late final MobileScannerController _ctrl;
  bool _scanned = false;
  bool _torchOn = false;

  @override
  void initState() {
    super.initState();
    _ctrl = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    final code = capture.barcodes.firstOrNull?.rawValue;
    if (code != null && code.isNotEmpty) {
      _scanned = true;
      Navigator.pop(context, code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          'ESCANEAR CÓDIGO',
          style: TextStyle(color: primary, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _torchOn ? Icons.flash_on : Icons.flash_off,
              color: _torchOn ? Colors.yellow : Colors.white38,
            ),
            onPressed: () {
              _ctrl.toggleTorch();
              setState(() => _torchOn = !_torchOn);
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(controller: _ctrl, onDetect: _onDetect),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: primary, width: 2.5),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Text(
              'Apunta al código de barras o QR',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
