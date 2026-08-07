import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../inventory/data/repositories/product_repository.dart';
import '../../../inventory/domain/entities/product_entity.dart';
import '../../../purchases/data/repositories/purchases_repository.dart';
import '../../../sales/data/repositories/sales_repository.dart';
import '../../../sales/domain/entities/sale_item_entity.dart';
import '../../../sales/presentation/services/ticket_service.dart';
import '../../data/repositories/reports_repository.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../../core/theme/theme_provider.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> with SingleTickerProviderStateMixin {
  final _salesRepo = SalesRepository();
  final _purchasesRepo = PurchasesRepository();
  final _reportsRepo = ReportsRepository();
  final _productRepo = ProductRepository();

  late TabController _tabCtrl;

  DateTime _start = DateTime.now();
  DateTime _end = DateTime.now();

  bool _isLoading = true;
  List<Map<String, dynamic>> _sales = [];
  List<Map<String, dynamic>> _purchases = [];
  Map<String, double> _cashFlow = {};
  List<ProductEntity> _products = [];
  int? _selectedProductId;
  List<Map<String, dynamic>> _movements = [];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final sales = await _salesRepo.getSalesByDateRange(_start, _end);
    final purchases = await _purchasesRepo.getHistory();
    final cashFlow = await _reportsRepo.getCashFlowSummary(_start, _end);
    final products = await _productRepo.getAll();
    List<Map<String, dynamic>> movements = [];
    if (_selectedProductId != null) {
      movements = await _reportsRepo.getInventoryMovements(_selectedProductId!);
    }
    if (mounted) {
      setState(() {
        _sales = sales;
        _purchases = purchases;
        _cashFlow = cashFlow;
        _products = products;
        _movements = movements;
        _isLoading = false;
      });
    }
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(start: _start, end: _end),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(primary: Theme.of(context).colorScheme.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _start = picked.start;
        _end = picked.end;
      });
      await _load();
    }
  }

  Future<void> _showSaleDetail(Map<String, dynamic> sale, Color color) async {
    final details = await _salesRepo.getSalesDetails(sale['id'] as int);
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

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 20,
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
                  Text(type, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 15, letterSpacing: 1)),
                  const Spacer(),
                  Text('\$${total.toStringAsFixed(2)}', style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 18)),
                ],
              ),
              const SizedBox(height: 4),
              Text(sale['date'] ?? '', style: const TextStyle(color: Colors.white24, fontSize: 11)),
              const Divider(color: Colors.white10, height: 20),
              ...details.map((d) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(child: Text(d['product_name'] ?? '', style: const TextStyle(color: Colors.white70, fontSize: 13))),
                    Text('${d['quantity']} x \$${(d['price_at_sale'] as num).toStringAsFixed(2)}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                    const SizedBox(width: 12),
                    Text('\$${((d['quantity'] as num) * (d['price_at_sale'] as num)).toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
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
                  label: const Text('REIMPRIMIR / REENVIAR TICKET', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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

  Future<void> _showPurchaseDetail(Map<String, dynamic> purchase) async {
    final details = await _purchasesRepo.getPurchaseDetails(purchase['id'] as int);
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.shopping_cart, color: Colors.orangeAccent, size: 22),
                  const SizedBox(width: 8),
                  Text('COMPRA', style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold, fontSize: 15, letterSpacing: 1)),
                  const Spacer(),
                  Text('\$${(purchase['total'] as num).toStringAsFixed(2)}', style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 18)),
                ],
              ),
              const SizedBox(height: 4),
              Text(purchase['date'] ?? '', style: const TextStyle(color: Colors.white24, fontSize: 11)),
              if ((purchase['provider_name'] ?? '').toString().isNotEmpty)
                Text('Proveedor: ${purchase['provider_name']}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
              const Divider(color: Colors.white10, height: 20),
              ...details.map((d) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(child: Text(d['product_name'] ?? '', style: const TextStyle(color: Colors.white70, fontSize: 13))),
                    Text('${d['quantity']} x \$${(d['cost_per_unit'] as num).toStringAsFixed(2)}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                    const SizedBox(width: 12),
                    Text('\$${((d['quantity'] as num) * (d['cost_per_unit'] as num)).toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
              )),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addOutflow() async {
    String type = 'expense';
    final descCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('REGISTRAR RETIRO / GASTO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: type,
              dropdownColor: const Color(0xFF1A1A1A),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Tipo', labelStyle: TextStyle(color: Colors.white38)),
              items: const [
                DropdownMenuItem(value: 'withdrawal', child: Text('Retiro de efectivo')),
                DropdownMenuItem(value: 'expense', child: Text('Gasto')),
                DropdownMenuItem(value: 'refund', child: Text('Devolución')),
                DropdownMenuItem(value: 'other', child: Text('Otro')),
              ],
              onChanged: (v) => type = v!,
            ),
            TextField(
              controller: amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Monto', labelStyle: TextStyle(color: Colors.white38)),
            ),
            TextField(
              controller: descCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Descripción', labelStyle: TextStyle(color: Colors.white38)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar', style: TextStyle(color: Colors.white38))),
          ElevatedButton(
            onPressed: () async {
              final amount = double.tryParse(amountCtrl.text) ?? 0;
              if (amount > 0 && descCtrl.text.trim().isNotEmpty) {
                await _reportsRepo.addCashOutflow(
                  outflowType: type,
                  amount: amount,
                  description: descCtrl.text.trim(),
                );
                if (ctx.mounted) Navigator.pop(ctx);
                await _load();
              }
            },
            child: const Text('GUARDAR', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: Text('INFORMES', style: TextStyle(color: primary, fontWeight: FontWeight.bold)),
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: primary,
          labelColor: primary,
          unselectedLabelColor: Colors.white54,
          tabs: const [
            Tab(icon: Icon(Icons.sell), text: 'Ventas'),
            Tab(icon: Icon(Icons.shopping_cart), text: 'Compras'),
            Tab(icon: Icon(Icons.account_balance_wallet), text: 'Caja'),
            Tab(icon: Icon(Icons.inventory_2), text: 'Kardex'),
          ],
        ),
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
          : TabBarView(
              controller: _tabCtrl,
              children: [
                _buildSalesTab(primary),
                _buildPurchasesTab(),
                _buildCashFlowTab(primary),
                _buildKardexTab(primary),
              ],
            ),
    );
  }

  Widget _buildDateFilter() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A1A1A)),
        icon: const Icon(Icons.date_range, color: Colors.white70),
        label: Text(
          '${_start.day.toString().padLeft(2, '0')}/${_start.month.toString().padLeft(2, '0')} - ${_end.day.toString().padLeft(2, '0')}/${_end.month.toString().padLeft(2, '0')}',
          style: const TextStyle(color: Colors.white),
        ),
        onPressed: _pickDateRange,
      ),
    );
  }

  Widget _buildSalesTab(Color primary) {
    final summary = _sales.fold<double>(0, (a, s) => a + (s['total'] as num).toDouble());
    return Column(
      children: [
        _buildDateFilter(),
        _StatsCard(label: 'Ventas', value: '${_sales.length}', icon: Icons.receipt_long, color: primary),
        const SizedBox(height: 12),
        _StatsCard(label: 'Total', value: '\$${summary.toStringAsFixed(2)}', icon: Icons.attach_money, color: Colors.greenAccent),
        const SizedBox(height: 12),
        Expanded(
          child: _sales.isEmpty
              ? const Center(child: Text('Sin ventas en el periodo', style: TextStyle(color: Colors.white24)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _sales.length,
                  itemBuilder: (_, i) {
                    final s = _sales[i];
                    final date = DateTime.tryParse(s['date'] ?? '') ?? DateTime.now();
                    final isMesa = (s['type'] as String).contains('Mesa');
                    final color = isMesa ? const Color(0xFF1E88E5) : primary;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(isMesa ? Icons.table_bar : Icons.sell, color: color),
                        title: Text(s['type'] ?? 'Venta', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        subtitle: Text('${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} | ${s['payment_method']}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                        trailing: Text('\$${(s['total'] as num).toStringAsFixed(2)}', style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                        onTap: () => _showSaleDetail(s, color),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildPurchasesTab() {
    final summary = _purchases.fold<double>(0, (a, p) => a + (p['total'] as num).toDouble());
    return Column(
      children: [
        _StatsCard(label: 'Compras', value: '${_purchases.length}', icon: Icons.shopping_cart, color: Colors.orangeAccent),
        const SizedBox(height: 12),
        _StatsCard(label: 'Total', value: '\$${summary.toStringAsFixed(2)}', icon: Icons.attach_money, color: Colors.greenAccent),
        const SizedBox(height: 12),
        Expanded(
          child: _purchases.isEmpty
              ? const Center(child: Text('Sin compras registradas', style: TextStyle(color: Colors.white24)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _purchases.length,
                  itemBuilder: (_, i) {
                    final p = _purchases[i];
                    final date = DateTime.tryParse(p['date'] ?? '') ?? DateTime.now();
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.shopping_cart, color: Colors.orangeAccent),
                        title: Text(p['provider_name'] ?? 'Compra', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        subtitle: Text('${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                        trailing: Text('\$${(p['total'] as num).toStringAsFixed(2)}', style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                        onTap: () => _showPurchaseDetail(p),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildCashFlowTab(Color primary) {
    final sales = _cashFlow['sales'] ?? 0;
    final purchases = _cashFlow['purchases'] ?? 0;
    final outflows = _cashFlow['outflows'] ?? 0;
    final net = _cashFlow['netCash'] ?? 0;
    return Column(
      children: [
        _buildDateFilter(),
        _StatsCard(label: 'Ingresos (ventas)', value: '\$${sales.toStringAsFixed(2)}', icon: Icons.arrow_upward, color: Colors.greenAccent),
        const SizedBox(height: 12),
        _StatsCard(label: 'Compras', value: '\$${purchases.toStringAsFixed(2)}', icon: Icons.shopping_cart, color: Colors.orangeAccent),
        const SizedBox(height: 12),
        _StatsCard(label: 'Retiros/Gastos', value: '\$${outflows.toStringAsFixed(2)}', icon: Icons.arrow_downward, color: Colors.redAccent),
        const SizedBox(height: 12),
        _StatsCard(label: 'Efectivo neto', value: '\$${net.toStringAsFixed(2)}', icon: Icons.account_balance_wallet, color: primary),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              icon: const Icon(Icons.money_off, color: Colors.white),
              label: const Text('REGISTRAR RETIRO / GASTO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              onPressed: _addOutflow,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildKardexTab(Color primary) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: DropdownButtonFormField<int?>(
            value: _selectedProductId,
            dropdownColor: const Color(0xFF1A1A1A),
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Seleccionar producto',
              labelStyle: TextStyle(color: Colors.white38),
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('Selecciona...', style: TextStyle(color: Colors.white54))),
              ..._products.map((p) => DropdownMenuItem(value: p.id, child: Text(p.name, style: const TextStyle(color: Colors.white)))),
            ],
            onChanged: (v) async {
              setState(() => _selectedProductId = v);
              if (v != null) {
                final m = await _reportsRepo.getInventoryMovements(v);
                setState(() => _movements = m);
              } else {
                setState(() => _movements = []);
              }
            },
          ),
        ),
        Expanded(
          child: _movements.isEmpty
              ? const Center(child: Text('Selecciona un producto para ver su kardex', style: TextStyle(color: Colors.white24)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _movements.length,
                  itemBuilder: (_, i) {
                    final m = _movements[i];
                    final type = m['movement_type'] as String;
                    final qty = (m['quantity'] as num).toDouble();
                    final isNegative = qty < 0;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(
                          type == 'sale' ? Icons.arrow_downward : Icons.arrow_upward,
                          color: type == 'sale' ? Colors.redAccent : Colors.greenAccent,
                        ),
                        title: Text(type.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        subtitle: Text('${m['created_at']}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                        trailing: Text(
                          '${isNegative ? '' : '+'}${qty.toStringAsFixed(2)}',
                          style: TextStyle(color: isNegative ? Colors.redAccent : Colors.greenAccent, fontWeight: FontWeight.bold),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
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
    final style = context.watch<ThemeProvider>().cardStyle;
    final solid = style == CardStyle.solidWhite;
    final outlined = style == CardStyle.outlined;
    final contentColor = solid ? Colors.white.withValues(alpha: 0.92) : color;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: solid ? color : (outlined ? const Color(0xFF1A1A1A) : null),
        gradient: (solid || outlined)
            ? null
            : LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [color.withValues(alpha: 0.18), const Color(0xFF1A1A1A)],
              ),
        border: Border.all(
          color: solid ? Colors.white.withValues(alpha: 0.28) : color.withValues(alpha: outlined ? 1.0 : 0.35),
          width: outlined ? 2 : 1.5,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: contentColor, size: 48),
          const SizedBox(width: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: solid ? Colors.white.withValues(alpha: 0.75) : Colors.white38,
                  fontSize: 13,
                  letterSpacing: 1,
                ),
              ),
              Text(value, style: TextStyle(color: contentColor, fontSize: 28, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }
}
