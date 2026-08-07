import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../sales/data/repositories/sales_repository.dart';
import '../../../sales/presentation/services/ticket_service.dart';
import '../../../sales/domain/entities/sale_item_entity.dart';
import '../../../../core/theme/theme_provider.dart';

enum _DateFilter { day, range, month }

class SalesHistoryPage extends StatefulWidget {
  const SalesHistoryPage({super.key});

  @override
  State<SalesHistoryPage> createState() => _SalesHistoryPageState();
}

class _SalesHistoryPageState extends State<SalesHistoryPage> {
  final _repo = SalesRepository();
  List<Map<String, dynamic>> _sales = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _isLoading = true;
  String _filterType = 'Todos';

  _DateFilter _dateFilter = _DateFilter.day;
  DateTime _selectedDate = DateTime.now();
  DateTime? _rangeStart;
  DateTime? _rangeEnd;
  DateTime _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);

  static const _types = ['Todos', 'Venta Rápida', 'Mesa'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    List<Map<String, dynamic>> sales;
    switch (_dateFilter) {
      case _DateFilter.day:
        sales = await _repo.getSalesByDate(_selectedDate);
        break;
      case _DateFilter.range:
        if (_rangeStart != null && _rangeEnd != null) {
          sales = await _repo.getSalesByDateRange(_rangeStart!, _rangeEnd!);
        } else {
          sales = [];
        }
        break;
      case _DateFilter.month:
        sales = await _repo.getSalesByMonth(_selectedMonth.year, _selectedMonth.month);
        break;
    }
    if (mounted) {
      setState(() {
        _sales = sales;
        _isLoading = false;
        _applyFilter();
      });
    }
  }

  void _applyFilter() {
    if (_filterType == 'Todos') {
      _filtered = _sales;
    } else if (_filterType == 'Mesa') {
      _filtered = _sales.where((s) => (s['type'] as String).contains('Mesa')).toList();
    } else {
      _filtered = _sales.where((s) => s['type'] == _filterType).toList();
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      builder:
          (ctx, child) => Theme(
            data: Theme.of(ctx).copyWith(
              colorScheme: ColorScheme.dark(primary: context.read<ThemeProvider>().primaryColor),
            ),
            child: child!,
          ),
    );
    if (picked != null) {
      setState(() {
        _dateFilter = _DateFilter.day;
        _selectedDate = picked;
      });
      _load();
    }
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final start = await showDatePicker(
      context: context,
      initialDate: _rangeStart ?? now,
      firstDate: DateTime(2024),
      lastDate: now,
      helpText: 'FECHA INICIO',
      builder:
          (ctx, child) => Theme(
            data: Theme.of(ctx).copyWith(
              colorScheme: ColorScheme.dark(primary: context.read<ThemeProvider>().primaryColor),
            ),
            child: child!,
          ),
    );
    if (start == null) return;

    final end = await showDatePicker(
      context: context,
      initialDate: _rangeEnd ?? start,
      firstDate: start,
      lastDate: now,
      helpText: 'FECHA FIN',
      builder:
          (ctx, child) => Theme(
            data: Theme.of(ctx).copyWith(
              colorScheme: ColorScheme.dark(primary: context.read<ThemeProvider>().primaryColor),
            ),
            child: child!,
          ),
    );
    if (end == null) return;

    setState(() {
      _dateFilter = _DateFilter.range;
      _rangeStart = start;
      _rangeEnd = end;
    });
    _load();
  }

  Future<void> _pickMonth() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedMonth,
      firstDate: DateTime(2024),
      lastDate: now,
      initialDatePickerMode: DatePickerMode.year,
      helpText: 'SELECCIONAR MES',
      builder:
          (ctx, child) => Theme(
            data: Theme.of(ctx).copyWith(
              colorScheme: ColorScheme.dark(primary: context.read<ThemeProvider>().primaryColor),
            ),
            child: child!,
          ),
    );
    if (picked != null) {
      setState(() {
        _dateFilter = _DateFilter.month;
        _selectedMonth = DateTime(picked.year, picked.month);
      });
      _load();
    }
  }

  String get _dateLabel {
    switch (_dateFilter) {
      case _DateFilter.day:
        final now = DateTime.now();
        if (_selectedDate.year == now.year &&
            _selectedDate.month == now.month &&
            _selectedDate.day == now.day) {
          return 'HOY';
        }
        return '${_selectedDate.day.toString().padLeft(2, '0')}/${_selectedDate.month.toString().padLeft(2, '0')}/${_selectedDate.year}';
      case _DateFilter.range:
        if (_rangeStart == null || _rangeEnd == null) return 'RANGO';
        final s =
            '${_rangeStart!.day.toString().padLeft(2, '0')}/${_rangeStart!.month.toString().padLeft(2, '0')}';
        final e =
            '${_rangeEnd!.day.toString().padLeft(2, '0')}/${_rangeEnd!.month.toString().padLeft(2, '0')}/${_rangeEnd!.year}';
        return '$s - $e';
      case _DateFilter.month:
        final months = [
          'ENE',
          'FEB',
          'MAR',
          'ABR',
          'MAY',
          'JUN',
          'JUL',
          'AGO',
          'SEP',
          'OCT',
          'NOV',
          'DIC',
        ];
        return '${months[_selectedMonth.month - 1]} ${_selectedMonth.year}';
    }
  }

  double get _totalFiltrado => _filtered.fold(0, (acc, s) => acc + (s['total'] as num).toDouble());

  @override
  Widget build(BuildContext context) {
    final primary = context.watch<ThemeProvider>().primaryColor;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'REGISTRO DE VENTAS',
          style: TextStyle(color: primary, fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_alt),
            tooltip: 'Filtrar fecha',
            color: const Color(0xFF1A1A1A),
            onSelected: (value) {
              switch (value) {
                case 'day':
                  _pickDate();
                  break;
                case 'range':
                  _pickRange();
                  break;
                case 'month':
                  _pickMonth();
                  break;
              }
            },
            itemBuilder:
                (_) => [
                  const PopupMenuItem(
                    value: 'day',
                    child: Text('Por día', style: TextStyle(color: Colors.white)),
                  ),
                  const PopupMenuItem(
                    value: 'range',
                    child: Text('Por rango', style: TextStyle(color: Colors.white)),
                  ),
                  const PopupMenuItem(
                    value: 'month',
                    child: Text('Por mes', style: TextStyle(color: Colors.white)),
                  ),
                ],
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFF111111),
            child: Row(
              children: [
                Icon(Icons.calendar_month, color: primary, size: 18),
                const SizedBox(width: 6),
                Text(
                  _dateLabel,
                  style: TextStyle(color: primary, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const Spacer(),
                Text(
                  '${_filtered.length} ventas',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(width: 12),
                Text(
                  '\$${_totalFiltrado.toStringAsFixed(2)}',
                  style: TextStyle(
                    color: Colors.greenAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          Container(
            color: const Color(0xFF0D0D0D),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children:
                  _types.map((t) {
                    final sel = _filterType == t;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap:
                            () => setState(() {
                              _filterType = t;
                              _applyFilter();
                            }),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            color: sel ? primary.withValues(alpha: 0.18) : Colors.transparent,
                            border: Border.all(
                              color: sel ? primary : Colors.white12,
                              width: sel ? 1.5 : 1,
                            ),
                          ),
                          child: Text(
                            t,
                            style: TextStyle(
                              color: sel ? primary : Colors.white38,
                              fontSize: 12,
                              fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
            ),
          ),
          Expanded(
            child:
                _isLoading
                    ? Center(child: CircularProgressIndicator(color: primary))
                    : _filtered.isEmpty
                    ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.receipt_long_outlined, color: Colors.white12, size: 64),
                          const SizedBox(height: 16),
                          const Text(
                            'Sin ventas en este período',
                            style: TextStyle(color: Colors.white24, fontSize: 15),
                          ),
                        ],
                      ),
                    )
                    : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _filtered.length,
                      itemBuilder: (_, i) {
                        final s = _filtered[i];
                        final date = DateTime.tryParse(s['date'] ?? '') ?? DateTime.now();
                        final type = s['type'] as String;
                        final isMesa = type.contains('Mesa');
                        final color = isMesa ? const Color(0xFF1E88E5) : primary;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => _showDetail(s, color),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: color.withValues(alpha: 0.15),
                                      border: Border.all(color: color.withValues(alpha: 0.4)),
                                    ),
                                    child: Icon(
                                      isMesa ? Icons.table_bar : Icons.point_of_sale,
                                      color: color,
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          type,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Row(
                                          children: [
                                            Text(
                                              '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
                                              style: const TextStyle(
                                                color: Colors.white38,
                                                fontSize: 11,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            _PayBadge(method: s['payment_method'] ?? 'Efectivo'),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    '\$${(s['total'] as num).toStringAsFixed(2)}',
                                    style: TextStyle(
                                      color: Colors.greenAccent,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.chevron_right, color: Colors.white12, size: 18),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }

  Future<void> _showDetail(Map<String, dynamic> sale, Color color) async {
    final details = await _repo.getSalesDetails(sale['id'] as int);
    if (!mounted) return;
    final items =
        details
            .map(
              (d) => SaleItemEntity(
                productId: d['product_id'] as int?,
                productName: d['product_name'] as String,
                price: (d['price_at_sale'] as num).toDouble(),
                quantity: (d['quantity'] as num).toDouble(),
              ),
            )
            .toList();

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
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder:
          (_) => Padding(
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
                      Text(
                        type,
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          letterSpacing: 1,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '\$${total.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sale['date'] ?? '',
                    style: const TextStyle(color: Colors.white24, fontSize: 11),
                  ),
                  const Divider(color: Colors.white10, height: 20),
                  ...details.map(
                    (d) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              d['product_name'] ?? '',
                              style: const TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                          ),
                          Text(
                            '${d['quantity']} x \$${(d['price_at_sale'] as num).toStringAsFixed(2)}',
                            style: const TextStyle(color: Colors.white38, fontSize: 12),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '\$${((d['quantity'] as num) * (d['price_at_sale'] as num)).toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
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
                      label: const Text(
                        'REIMPRIMI|R / REENVIAR TICKET',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
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
}

class _PayBadge extends StatelessWidget {
  final String method;
  const _PayBadge({required this.method});

  @override
  Widget build(BuildContext context) {
    final color =
        method == 'Efectivo'
            ? Colors.greenAccent
            : method == 'Tarjeta'
            ? Colors.blueAccent
            : Colors.orangeAccent;
    final icon =
        method == 'Efectivo'
            ? Icons.payments_outlined
            : method == 'Tarjeta'
            ? Icons.credit_card
            : Icons.swap_horiz;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 12),
        const SizedBox(width: 3),
        Text(method, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500)),
      ],
    );
  }
}
