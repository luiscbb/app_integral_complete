class PlayerOrder {
  PlayerOrder({required this.name, required this.price});

  final String name;
  final double price;
  int quantity = 0;

  double get subtotal => price * quantity;

  void increment() => quantity++;

  void decrement() {
    if (quantity > 0) quantity--;
  }
}
