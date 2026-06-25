import 'package:flutter/material.dart';
import '../../../../core/widgets/empty_state.dart';

class SpecialClientPage extends StatelessWidget {
  const SpecialClientPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CLIENTES ESPECIALES', style: TextStyle(color: Color(0xFFFFD600), fontWeight: FontWeight.bold)),
      ),
      body: const EmptyState(message: 'Módulo en desarrollo', icon: Icons.person_search_outlined),
    );
  }
}
