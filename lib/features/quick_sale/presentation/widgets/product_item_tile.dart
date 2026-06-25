import 'package:flutter/material.dart';

import '../../domain/entities/product_item.dart';

class ProductItemTile extends StatelessWidget {
  const ProductItemTile({
    required this.item,
    required this.onIncrement,
    required this.onDecrement,
    super.key,
  });

  final ProductItem item;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('Precio: ${item.price.toStringAsFixed(2)} MXN'),
                ],
              ),
            ),
            Row(
              children: [
                IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: onDecrement),
                Text(item.quantity.toString(), style: const TextStyle(fontSize: 16)),
                IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: onIncrement),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
