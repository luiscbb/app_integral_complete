import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../inventory/data/repositories/product_repository.dart';
import '../../../inventory/domain/entities/product_entity.dart';
import '../../../../core/widgets/app_button.dart';
import '../../../../core/widgets/app_text_field.dart';

class CreatePromoPage extends StatefulWidget {
  /// Si [promo] es null se crea una nueva; si no, se edita la existente.
  final ProductEntity? promo;
  const CreatePromoPage({super.key, this.promo});

  @override
  State<CreatePromoPage> createState() => _CreatePromoPageState();
}

class _CreatePromoPageState extends State<CreatePromoPage> {
  final _repo = ProductRepository();
  final _nameCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _nameFocus = FocusNode();
  String? _imagePath;
  List<ProductEntity> _products = [];
  final Map<int, int> _selected = {};
  bool _isLoading = true;
  bool _saving = false;
  bool _priceTouched = false;

  bool get _isEditing => widget.promo != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(_uppercaseName);
    final p = widget.promo;
    if (p != null) {
      _nameCtrl.text = p.name;
      _priceCtrl.text = p.price.toString();
      _imagePath = p.imagePath;
      _priceTouched = true; // No sobrescribir un precio ya guardado.
    }
    _priceCtrl.addListener(() => _priceTouched = true);
    _load();
    if (!_isEditing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _nameFocus.requestFocus());
    }
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_uppercaseName);
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _uppercaseName() {
    final text = _nameCtrl.text;
    final upper = text.toUpperCase();
    if (upper != text) {
      _nameCtrl.value = TextEditingValue(
        text: upper,
        selection: TextSelection.collapsed(offset: upper.length),
      );
    }
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

  Future<void> _load() async {
    final data = await _repo.getAll();
    Map<int, int> existing = {};
    if (_isEditing) {
      existing = await _repo.getPromoComponents(widget.promo!.id!);
    }
    if (mounted) {
      setState(() {
        _products = data.where((p) => p.isPromo == 0 && p.parentId == null).toList();
        _selected
          ..clear()
          ..addAll(existing);
        _isLoading = false;
      });
    }
  }

  /// Costo total de la promo = suma de (costo de cada pieza × cantidad).
  double get _componentsCost {
    double total = 0;
    for (final entry in _selected.entries) {
      final prod = _products.firstWhere(
        (p) => p.id == entry.key,
        orElse: () => const ProductEntity(name: '', price: 0, stock: 0),
      );
      total += prod.cost * entry.value;
    }
    return total;
  }

  /// Suma de los precios de venta individuales (referencia de ahorro).
  double get _componentsSalePrice {
    double total = 0;
    for (final entry in _selected.entries) {
      final prod = _products.firstWhere(
        (p) => p.id == entry.key,
        orElse: () => const ProductEntity(name: '', price: 0, stock: 0),
      );
      total += prod.price * entry.value;
    }
    return total;
  }

  void _changeQty(ProductEntity p, int delta) {
    setState(() {
      final current = _selected[p.id] ?? 0;
      final next = current + delta;
      if (next <= 0) {
        _selected.remove(p.id);
      } else {
        _selected[p.id!] = next;
      }
      // Si el usuario no editó el precio manualmente, sugerir el costo total.
      if (!_priceTouched) {
        _priceCtrl.text = _componentsCost.toStringAsFixed(2);
        _priceTouched = false; // El listener lo puso en true; revertir.
      }
    });
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty || _selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nombre y al menos un producto requeridos'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final promo = ProductEntity(
        id: widget.promo?.id,
        name: _nameCtrl.text.trim().toUpperCase(),
        price: double.tryParse(_priceCtrl.text) ?? _componentsCost,
        cost: _componentsCost,
        stock: 0,
        isPromo: 1,
        imagePath: _imagePath,
      );
      if (_isEditing) {
        await _repo.updatePromo(promo, _selected);
      } else {
        await _repo.insertPromo(promo, _selected);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isEditing ? 'Promo actualizada' : 'Promo creada'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('ELIMINAR PROMO', style: TextStyle(color: Colors.redAccent)),
        content: Text(
          '¿Eliminar "${widget.promo!.name}"? Esta acción no se puede deshacer.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ELIMINAR', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _repo.delete(widget.promo!.id!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Promo eliminada'), backgroundColor: Colors.green),
        );
        Navigator.pop(context, true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ahorro = _componentsSalePrice - (double.tryParse(_priceCtrl.text) ?? 0);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isEditing ? 'EDITAR PROMO' : 'CREAR PROMO',
          style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_isEditing)
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.redAccent),
              tooltip: 'Eliminar promo',
              onPressed: _delete,
            ),
        ],
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.orange))
              : Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: _pickImage,
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
                        ),
                        child: _imagePath != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: _imagePath!.startsWith('http')
                                    ? CachedNetworkImage(imageUrl: _imagePath!, fit: BoxFit.cover)
                                    : Image.file(File(_imagePath!), fit: BoxFit.cover),
                              )
                            : const Icon(Icons.add_a_photo, color: Colors.white38, size: 28),
                      ),
                    ),
                    const SizedBox(height: 12),
                    AppTextField(
                      controller: _nameCtrl,
                      label: 'Nombre de la promo',
                      icon: Icons.stars,
                      focusNode: _nameFocus,
                    ),
                    AppTextField(
                      controller: _priceCtrl,
                      label: 'Precio de la promo',
                      icon: Icons.sell,
                      isNumber: true,
                      selectAllOnTap: true,
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Costo (suma de piezas):',
                                style: TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                              Text(
                                '\$${_componentsCost.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  color: Colors.orangeAccent,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Precio normal (sin promo):',
                                style: TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                              Text(
                                '\$${_componentsSalePrice.toStringAsFixed(2)}',
                                style: const TextStyle(color: Colors.white70, fontSize: 12),
                              ),
                            ],
                          ),
                          if (ahorro > 0) ...[
                            const SizedBox(height: 2),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Ahorro al cliente:',
                                  style: TextStyle(color: Colors.white54, fontSize: 12),
                                ),
                                Text(
                                  '\$${ahorro.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    color: Colors.greenAccent,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Selecciona los productos que incluye:',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _products.length,
                        itemBuilder: (_, i) {
                          final p = _products[i];
                          final qty = _selected[p.id] ?? 0;
                          return ListTile(
                            title: Text(p.name, style: const TextStyle(color: Colors.white)),
                            subtitle: Text(
                              'Costo \$${p.cost.toStringAsFixed(2)}  •  Venta \$${p.price.toStringAsFixed(2)}',
                              style: const TextStyle(color: Colors.white54, fontSize: 11),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.remove_circle,
                                    color: Colors.white24,
                                    size: 20,
                                  ),
                                  onPressed: qty > 0 ? () => _changeQty(p, -1) : null,
                                ),
                                Text(
                                  '$qty',
                                  style: TextStyle(
                                    color: qty > 0 ? Colors.orange : Colors.white38,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.add_circle,
                                    color: Colors.orange,
                                    size: 20,
                                  ),
                                  onPressed: () => _changeQty(p, 1),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    AppButton(
                      label: _isEditing ? 'ACTUALIZAR PROMO' : 'GUARDAR PROMO',
                      color: Colors.orange,
                      icon: Icons.save,
                      isLoading: _saving,
                      onPressed: _save,
                    ),
                  ],
                ),
              ),
    );
  }
}
