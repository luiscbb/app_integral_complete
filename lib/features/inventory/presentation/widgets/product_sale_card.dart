import 'package:flutter/material.dart';
import '../../../../core/utils/smart_image.dart';
import '../../domain/entities/product_entity.dart';

class ProductSaleCard extends StatelessWidget {
  final ProductEntity product;
  final int quantity;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final bool showButtons;

  const ProductSaleCard({
    super.key,
    required this.product,
    required this.quantity,
    required this.onAdd,
    required this.onRemove,
    this.showButtons = false,
  });

  Color get _stockColor {
    if (product.stock <= 0) return Colors.red;
    if (product.stock <= 5) return Colors.orange;
    return Colors.green;
  }

  String get _stockLabel {
    if (product.stock <= 0) return 'AGOT';
    return '${product.stock.toInt()}pz';
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: quantity > 0 ? primary : _stockColor.withValues(alpha: 0.6), width: 2),
      ),
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
                  Text(
                    '\$${product.price.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Colors.greenAccent,
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
                          icon: Icon(Icons.add_circle, color: primary, size: 20),
                          onPressed: onAdd,
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
                color: _stockColor.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _stockLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

          // Cantidad en carrito — superior derecha
          if (!showButtons && quantity > 0)
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
    );
  }
}
