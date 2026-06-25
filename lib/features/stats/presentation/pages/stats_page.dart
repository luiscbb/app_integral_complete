import 'package:flutter/material.dart';
import '../../../sales/data/repositories/sales_repository.dart';
import '../../../sales/domain/entities/sale_item_entity.dart';
import '../../../sales/presentation/services/ticket_service.dart';
import '../../../../core/routes/app_routes.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  final _repo = SalesRepository();
  List<Map<String, dynamic>> _sales = [];
  double _totalDay = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final sales = await _repo.getTodaySales();
    final stats = await _repo.getTodayStats();
    if (mounted) setState(() { _sales = sales; _totalDay = stats['total'] ?? 0; _isLoading = false; });
  }

  Future<void> _showDetail(Map<String, dynamic> sale, Color color) async {
    final details = await _repo.getSalesDetails(sale['id'] as int);
    if (!mounted) return;
    final items = details.map((d) => SaleItemEntity(
      productId: d['product_id'] as int?,
      productName: d['product_name'] as String,
      price: (d['price_at_sale'] as num).toDouble(),
      quantity: (d['quantity'] as num).toDouble(),
    )).toList();

    final total = (sale['total'] as num).toDouble();
    final paid = ((sale['paid'] as num?) ?? total).toDouble();
    final method = sale['payment_method'] ?? 'Efectivo';
    final type = sale['type'] ?? '';

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.receipt_long, color: color, size: 22),
                  const SizedBox(width: 8),
                  Text(type,
                      style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          letterSpacing: 1)),
                  const Spacer(),
                  Text('\$${total.toStringAsFixed(2)}',
                      style: const TextStyle(
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 18)),
                ],
              ),
              const SizedBox(height: 4),
              Text(sale['date'] ?? '',
                  style: const TextStyle(color: Colors.white24, fontSize: 11)),
              const Divider(color: Colors.white10, height: 20),
              ...details.map((d) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(d['product_name'] ?? '',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13)),
                        ),
                        Text(
                            '${d['quantity']} x \$${(d['price_at_sale'] as num).toStringAsFixed(2)}',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12)),
                        const SizedBox(width: 12),
                        Text(
                            '\$${((d['quantity'] as num) * (d['price_at_sale'] as num)).toStringAsFixed(2)}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                      ],
                    ),
                  )),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: color,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.receipt_long, color: Colors.white),
                  label: const Text('REIMPRIMIR / REENVIAR TICKET',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  onPressed: () {
                    Navigator.pop(context);
                    TicketService().showPreviewSheet(
                      context: context,
                      items: items,
                      total: total,
                      paid: paid,
                      paymentMethod: method,
                      saleType: type,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: Text('ESTADISTICAS', style: TextStyle(color: primary, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Historial de ventas',
            onPressed: () => Navigator.pushNamed(context, AppRoutes.salesHistory),
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _StatsCard(label: 'Ventas Hoy', value: '${_sales.length}', icon: Icons.receipt_long, color: primary),
                  const SizedBox(height: 12),
                  _StatsCard(label: 'Total del Dia', value: '\$${_totalDay.toStringAsFixed(2)}', icon: Icons.attach_money, color: Colors.greenAccent),
                  const SizedBox(height: 24),
                  if (_sales.isNotEmpty) ...[
                    const Text('DETALLE DE VENTAS HOY', style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 2)),
                    const SizedBox(height: 12),
                    ..._sales.map((s) {
                      final date = DateTime.tryParse(s['date'] ?? '') ?? DateTime.now();
                      final isMesa = (s['type'] as String).contains('Mesa');
                      final color = isMesa ? const Color(0xFF1E88E5) : primary;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _showDetail(s, color),
                          child: ListTile(
                            leading: Icon(isMesa ? Icons.table_bar : Icons.sell, color: color),
                            title: Text(s['type'] ?? 'Venta', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            subtitle: Text('${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} | ${s['payment_method']}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                            trailing: Text('\$${(s['total'] as num).toStringAsFixed(2)}', style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      );
                    }),
                  ] else
                    const Padding(
                      padding: EdgeInsets.only(top: 40),
                      child: Text('Sin ventas hoy', style: TextStyle(color: Colors.white24)),
                    ),
                ],
              ),
            ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _StatsCard({required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [color.withValues(alpha: 0.18), const Color(0xFF1A1A1A)],
        ),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1.5),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 48),
          const SizedBox(width: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: Colors.white38, fontSize: 13, letterSpacing: 1)),
              Text(value, style: TextStyle(color: color, fontSize: 28, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }
}
