import 'package:flutter/material.dart';
import '../../../../core/widgets/empty_state.dart';

class DineInPage extends StatelessWidget {
  const DineInPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('COMENSALES', style: TextStyle(color: Color(0xFFE91E63), fontWeight: FontWeight.bold)),
      ),
      body: const EmptyState(message: 'Módulo en desarrollo', icon: Icons.restaurant_outlined),
    );
  }
}
