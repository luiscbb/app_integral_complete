import 'package:flutter/material.dart';

import '../../domain/entities/player_order.dart';

class PlayerOrderRow extends StatelessWidget {
  const PlayerOrderRow({
    required this.order,
    required this.onIncrement,
    required this.onDecrement,
    super.key,
  });

  final PlayerOrder order;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(child: Text(order.name)),
        Row(
          children: [
            IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: onDecrement),
            Text(order.quantity.toString()),
            IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: onIncrement),
          ],
        ),
        Text(order.subtotal.toStringAsFixed(2)),
      ],
    );
  }
}
