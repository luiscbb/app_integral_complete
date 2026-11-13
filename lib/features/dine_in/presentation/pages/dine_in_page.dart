import 'package:flutter/material.dart';
import '../../../sales/presentation/pages/billiard_tables_page.dart';

class DineInPage extends StatelessWidget {
  const DineInPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const BilliardTablesPage(tableType: 'Comanda');
  }
}
