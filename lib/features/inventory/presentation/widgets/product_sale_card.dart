import 'package:flutter/material.dart';
import '../../../../core/utils/smart_image.dart';
import '../../domain/entities/product_entity.dart';

class ProductSaleCard extends StatelessWidget {
  final ProductEntity product;
  final int quantity;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final bool showButtons;
  final bool showOutOfStock;

  const ProductSaleCard({
    super.key,
    required this.product,
    required this.quantity,
    required this.onAdd,
    required this.onRemove,
    this.showButtons = false,
    this.showOutOfStock = true,
  });

  Color _stockColor() {
    if (product.stock <= 0) return Colors.red;
    if (product.stock <= 5) return Colors.orange;
    return Colors.green;
  }

  String get _stockLabel {
    if (product.stock <= 0) return 'AGOTADO';
    final pieces = product.piecesPerUnit;
    if (pieces > 1) {
      final boxes = product.stock ~/ pieces;
      final loose = (product.stock % pieces).toInt();
      if (boxes > 0 && loose > 0) return '$boxes CJ\n$loose PZ';
      if (boxes > 0) return '$boxes CJ';
      return '$loose PZ';
    }
    return '${product.stock.toInt()} PZ';
  }

  bool get _isOutOfStock => product.stock <= 0;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    if (_isOutOfStock && !showOutOfStock) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color: _isOutOfStock ? const Color(0xFF2A1A1A) : const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: _isOutOfStock
              ? Colors.red
              : (quantity > 0 ? primary : _stockColor().withValues(alpha: 0.6)),
          width: 2,
        ),
      ),
      child: Opacity(
        opacity: _isOutOfStock ? 0.45 : 1.0,
        child: Stack(
          children: [
            SizedBox.expand(
              child: Padding(
                padding: const EdgeInsets.all(10.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: Colors.white.withValues(alpha: 0.05),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: SmartImage(
                          imagePath: product.imagePath,
                          placeholderIcon: Icons.inventory_2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      product.name.toUpperCase(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (product.presentation.isNotEmpty)
                      Text(
                        product.presentation.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    Text(
                      '\$${product.price.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: _isOutOfStock ? Colors.red[200] : Colors.greenAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    if (showButtons) ...[
                      const SizedBox(height: 5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle, color: Colors.white24, size: 20),
                            onPressed: onRemove,
                          ),
                          Text(
                            '$quantity',
                            style: const TextStyle(color: Colors.white, fontSize: 16),
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.add_circle,
                              color: _isOutOfStock ? Colors.red : primary,
                              size: 20,
                            ),
                            onPressed: _isOutOfStock ? null : onAdd,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Stock badge — superior izquierda
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: _isOutOfStock ? Colors.red : _stockColor().withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _stockLabel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

            // Distintivo PROMO — superior derecha
            if (product.isPromo == 1)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star, color: Colors.white, size: 10),
                      SizedBox(width: 2),
                      Text(
                        'PROMO',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Cantidad en carrito — superior derecha (solo si no es promo)
            if (!showButtons && quantity > 0 && product.isPromo != 1)
              Positioned(
                top: 6,
                right: 6,
                child: CircleAvatar(
                  radius: 12,
                  backgroundColor: primary,
                  child: Text(
                    '$quantity',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
