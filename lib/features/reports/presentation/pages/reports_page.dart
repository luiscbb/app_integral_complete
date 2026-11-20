import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../../inventory/data/repositories/product_repository.dart';
import '../../../inventory/domain/entities/product_entity.dart';
import '../../../purchases/data/repositories/purchases_repository.dart';
import '../../../sales/data/repositories/sales_repository.dart';
import '../../../sales/domain/entities/sale_item_entity.dart';
import '../../../sales/presentation/services/ticket_service.dart';
import '../../data/repositories/reports_repository.dart';
import '../../../../core/routes/app_routes.dart';
import '../../../../core/services/sync_service.dart';
import '../../../../core/services/business_logo_loader.dart';
import '../../../../core/theme/theme_provider.dart';
import '../services/report_receipt_service.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/widgets/admin_pin_dialog.dart';
import '../../../cash/data/repositories/shared_cash_repository.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, this.repository});

  final ReportsRepository? repository;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage>
    with SingleTickerProviderStateMixin {
  final _salesRepo = SalesRepository();
  final _purchasesRepo = PurchasesRepository();
  late final ReportsRepository _reportsRepo;
  final _productRepo = ProductRepository();

  late TabController _tabCtrl;

  DateTime _start = DateTime.now();
  DateTime _end = DateTime.now();

  bool _isLoading = true;
  Object? _loadError;
  bool _sharedCashCurrent = true;
  List<Map<String, dynamic>> _sales = [];
  List<Map<String, dynamic>> _purchases = [];
  Map<String, double> _cashFlow = {};
  List<ProductEntity> _products = [];
  int? _selectedProductId;
  List<Map<String, dynamic>> _movements = [];

  List<Map<String, String>> _profitExpenses =
      []; // pares concepto/monto ordenados
  Map<String, dynamic> _profit = {};

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 5, vsync: this);
    _reportsRepo = widget.repository ?? ReportsRepository();
    _load();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    final start = _start;
    final end = _end;
    try {
      final sharedCashCurrent =
          widget.repository != null ||
          await SharedCashRepository().syncMovements(
            DateTime(start.year, start.month, start.day),
            DateTime(end.year, end.month, end.day + 1),
          );
      final cashFlow = await _reportsRepo.getCashFlowSummary(start, end);
      final sales = await _salesRepo.getSalesByDateRange(start, end);
      final purchases = await _purchasesRepo.getHistory();
      final products = await _productRepo.getAll(includeArchived: true);
      final profit = await _reportsRepo.getProfitSummary(start, end);
      List<Map<String, String>> profitExpenses = [];
      final byConcept = profit['expensesByConcept'] as Map<String, double>;
      final entries =
          byConcept.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in entries) {
        profitExpenses.add({'concept': e.key, 'amount': e.value.toString()});
      }
      List<Map<String, dynamic>> movements = [];
      if (_selectedProductId != null) {
        movements = await _reportsRepo.getInventoryMovements(
          _selectedProductId!,
        );
      }
      if (!mounted || start != _start || end != _end) return;
      setState(() {
        _sales = sales;
        _purchases = purchases;
        _cashFlow = cashFlow;
        _sharedCashCurrent = sharedCashCurrent;
        _products = products;
        _movements = movements;
        _profit = profit;
        _profitExpenses = profitExpenses;
        _isLoading = false;
      });
      unawaited(_refreshOutflowsAfterPull(start, end));
    } catch (error, stack) {
      if (start == _start && end == _end) _reportLoadError(error, stack);
    }
  }

  void _reportLoadError(Object error, StackTrace stack) {
    debugPrint('[Reports] No se pudieron cargar los informes: $error\n$stack');
    if (mounted) {
      setState(() {
        _isLoading = false;
        _loadError = error;
      });
    }
  }

  Future<void> _refreshOutflowsAfterPull(DateTime start, DateTime end) async {
    try {
      await SyncService().pullOutflowsFromCloud();
      if (!mounted || start != _start || end != _end) return;
      final cashFlow = await _reportsRepo.getCashFlowSummary(start, end);
      final profit = await _reportsRepo.getProfitSummary(start, end);
      final byConcept = profit['expensesByConcept'] as Map<String, double>;
      final entries =
          byConcept.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
      final expenses =
          entries
              .map(
                (entry) => {
                  'concept': entry.key,
                  'amount': entry.value.toString(),
                },
              )
              .toList();
      if (!mounted || start != _start || end != _end) return;
      setState(() {
        _cashFlow = cashFlow;
        _profit = profit;
        _profitExpenses = expenses;
      });
    } catch (error, stack) {
      if (start == _start && end == _end) _reportLoadError(error, stack);
    }
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(start: _start, end: _end),
      builder:
          (context, child) => Theme(
            data: Theme.of(context).copyWith(
              colorScheme: Theme.of(context).colorScheme.copyWith(
                primary: Theme.of(context).colorScheme.primary,
              ),
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
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          Text(
                            '${d['quantity']} x \$${(d['price_at_sale'] as num).toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
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
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: const Icon(Icons.receipt_long, color: Colors.white),
                      label: const Text(
                        'REIMPRIMIR / REENVIAR TICKET',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
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
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: const Icon(
                        Icons.cancel_outlined,
                        color: Colors.white,
                      ),
                      label: const Text(
                        'ANULAR VENTA',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        _cancelSaleFromReports(sale);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  /// Anulación de venta desde la pestaña Ventas de Informes.
  /// Reutiliza la misma autorización que el Historial: Administrador sin PIN,
  /// otro usuario con PIN debe ingresarlo, sin PIN se permite con aviso.
  Future<void> _cancelSaleFromReports(Map<String, dynamic> sale) async {
    final prefs = PreferencesService();
    final isAdmin = prefs.userName.trim().toLowerCase() == 'administrador';

    if (!isAdmin) {
      if (prefs.adminPin.isNotEmpty) {
        final authorized = await AdminPinDialog.authorize(
          context,
          accion: 'ANULAR VENTA',
        );
        if (!authorized || !mounted) return;
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Anulando sin PIN. Configura un PIN en Configuración para proteger esta acción.',
            ),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text(
              'ANULAR VENTA',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            content: Text(
              'Se anulará la venta de \$${(sale['total'] as num).toStringAsFixed(2)}.\n\n'
              'El stock de los productos regresará al inventario y la venta dejará de contar en informes y caja.\n\n¿Continuar?',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text(
                  'Cancelar',
                  style: TextStyle(color: Colors.white38),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'ANULAR',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    final bool ok;
    try {
      ok = await _salesRepo.cancelSale(sale['id'] as int);
    } on StateError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message), backgroundColor: Colors.red),
        );
      }
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Venta anulada. Stock devuelto al inventario.'
              : 'No se pudo anular la venta.',
        ),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
    if (ok) {
      await _showCancelSalePdf(sale);
      await _load();
    }
  }

  /// Ticket de anulación de venta (mismo formato de tickets de caja) desde
  /// la pestaña Ventas de Informes.
  Future<void> _showCancelSalePdf(Map<String, dynamic> sale) async {
    final prefs = PreferencesService();
    final businessName =
        prefs.businessName.trim().isEmpty
            ? 'MI NEGOCIO'
            : prefs.businessName.trim();
    final primaryColor = PdfColor.fromInt(prefs.primaryColorValue);

    pw.MemoryImage? logoImage;
    final logoBytes = await _loadLogoBytes();
    if (logoBytes != null) logoImage = pw.MemoryImage(logoBytes);

    final pdf = pw.Document();
    final now = DateTime.now();
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}  ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final saleDate = DateTime.tryParse(sale['date'] ?? '') ?? now;
    final saleDateStr =
        '${saleDate.day}/${saleDate.month}/${saleDate.year}  ${saleDate.hour.toString().padLeft(2, '0')}:${saleDate.minute.toString().padLeft(2, '0')}';
    final total = (sale['total'] as num?)?.toDouble() ?? 0;
    final type = sale['type']?.toString() ?? 'Venta';

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        build:
            (pw.Context ctx) => pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.SizedBox(height: 4),
                if (logoImage != null) ...[
                  pw.Center(child: pw.Image(logoImage, width: 56, height: 56)),
                  pw.SizedBox(height: 4),
                ],
                pw.Center(
                  child: pw.Text(
                    businessName.toUpperCase(),
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Center(
                  child: pw.Text(
                    'VENTA ANULADA',
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Center(
                  child: pw.Text(
                    dateStr,
                    style: const pw.TextStyle(
                      fontSize: 8,
                      color: PdfColors.grey700,
                    ),
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Divider(color: primaryColor, thickness: 0.8),
                pw.Text(
                  'Venta: $type',
                  style: const pw.TextStyle(fontSize: 9.5),
                ),
                pw.Text(
                  'Fecha original: $saleDateStr',
                  style: const pw.TextStyle(fontSize: 9.5),
                ),
                pw.Text(
                  'Anuló: ${prefs.userName}',
                  style: const pw.TextStyle(fontSize: 9.5),
                ),
                pw.Divider(color: primaryColor, thickness: 0.8),
                pw.Text(
                  'Monto anulado: \$${total.toStringAsFixed(2)}',
                  style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  'El stock de los productos fue devuelto al inventario.',
                  style: const pw.TextStyle(
                    fontSize: 8,
                    color: PdfColors.grey700,
                  ),
                ),
                pw.SizedBox(height: 10),
                pw.Center(
                  child: pw.Text(
                    'Documento interno / control de caja',
                    style: const pw.TextStyle(fontSize: 7),
                  ),
                ),
              ],
            ),
      ),
    );

    final bytes = await pdf.save();
    if (!mounted) return;

    final fileName = 'anulacion_venta_${now.millisecondsSinceEpoch}.pdf';
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder:
          (ctx) => Dialog(
            backgroundColor: const Color(0xFF1A1A1A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: SizedBox(
              width: 420,
              height: 560,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        const Text(
                          'VENTA ANULADA',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.share, color: Colors.blue),
                          onPressed:
                              () => Printing.sharePdf(
                                bytes: bytes,
                                filename: fileName,
                              ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.print,
                            color: Theme.of(ctx).colorScheme.primary,
                          ),
                          onPressed:
                              () => Printing.layoutPdf(
                                onLayout: (_) async => bytes,
                                name: fileName,
                              ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PdfPreview(
                      padding: const EdgeInsets.all(12),
                      build: (_) => Future.value(bytes),
                      allowSharing: false,
                      allowPrinting: false,
                      initialPageFormat: const PdfPageFormat(
                        80 * PdfPageFormat.mm,
                        200 * PdfPageFormat.mm,
                      ),
                      pageFormats: const {},
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  Future<void> _showPurchaseDetail(Map<String, dynamic> purchase) async {
    final details = await _purchasesRepo.getPurchaseDetails(
      purchase['id'] as int,
    );
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
                      const Icon(
                        Icons.shopping_cart,
                        color: Colors.orangeAccent,
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'COMPRA',
                        style: TextStyle(
                          color: Colors.orangeAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          letterSpacing: 1,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '\$${(purchase['total'] as num).toStringAsFixed(2)}',
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
                    purchase['date'] ?? '',
                    style: const TextStyle(color: Colors.white24, fontSize: 11),
                  ),
                  if ((purchase['provider_name'] ?? '').toString().isNotEmpty)
                    Text(
                      'Proveedor: ${purchase['provider_name']}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
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
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          Text(
                            '${d['quantity']} x \$${(d['cost_per_unit'] as num).toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '\$${((d['quantity'] as num) * (d['cost_per_unit'] as num)).toStringAsFixed(2)}',
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
                        backgroundColor: Colors.redAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: const Icon(
                        Icons.cancel_outlined,
                        color: Colors.white,
                      ),
                      label: const Text(
                        'ANULAR COMPRA',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        _cancelPurchaseFromReports(purchase);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  /// Anulación de compra desde la pestaña Compras de Informes.
  /// Misma autorización que en el Historial de compras (PIN / Administrador).
  Future<void> _cancelPurchaseFromReports(Map<String, dynamic> purchase) async {
    final prefs = PreferencesService();
    final isAdmin = prefs.userName.trim().toLowerCase() == 'administrador';

    if (!isAdmin) {
      if (prefs.adminPin.isNotEmpty) {
        final authorized = await AdminPinDialog.authorize(
          context,
          accion: 'ANULAR COMPRA',
        );
        if (!authorized || !mounted) return;
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Anulando sin PIN. Configura un PIN en Configuración para proteger esta acción.',
            ),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: const Text(
              'ANULAR COMPRA',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            content: Text(
              'Se anulará la compra de \$${(purchase['total'] as num).toStringAsFixed(2)}.\n\n'
              'El stock que la compra sumó será descontado del inventario y la compra dejará de contar en informes y caja.\n\n¿Continuar?',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text(
                  'Cancelar',
                  style: TextStyle(color: Colors.white38),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  'ANULAR',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    final ok = await _purchasesRepo.cancelPurchase(purchase['id'] as int);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Compra anulada. Stock descontado del inventario.'
              : 'No se pudo anular la compra.',
        ),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
    if (ok) {
      await _showCancelPurchasePdf(purchase);
      await _load();
    }
  }

  /// Ticket de anulación de compra (mismo formato de tickets de caja) desde
  /// la pestaña Compras de Informes.
  Future<void> _showCancelPurchasePdf(Map<String, dynamic> purchase) async {
    final prefs = PreferencesService();
    final businessName =
        prefs.businessName.trim().isEmpty
            ? 'MI NEGOCIO'
            : prefs.businessName.trim();
    final primaryColor = PdfColor.fromInt(prefs.primaryColorValue);

    pw.MemoryImage? logoImage;
    final logoBytes = await _loadLogoBytes();
    if (logoBytes != null) logoImage = pw.MemoryImage(logoBytes);

    final pdf = pw.Document();
    final now = DateTime.now();
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}  ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final purchaseDate = DateTime.tryParse(purchase['date'] ?? '') ?? now;
    final purchaseDateStr =
        '${purchaseDate.day}/${purchaseDate.month}/${purchaseDate.year}';
    final total = (purchase['total'] as num?)?.toDouble() ?? 0;

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        build:
            (pw.Context ctx) => pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.SizedBox(height: 4),
                if (logoImage != null) ...[
                  pw.Center(child: pw.Image(logoImage, width: 56, height: 56)),
                  pw.SizedBox(height: 4),
                ],
                pw.Center(
                  child: pw.Text(
                    businessName.toUpperCase(),
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Center(
                  child: pw.Text(
                    'COMPRA ANULADA',
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Center(
                  child: pw.Text(
                    dateStr,
                    style: const pw.TextStyle(
                      fontSize: 8,
                      color: PdfColors.grey700,
                    ),
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Divider(color: primaryColor, thickness: 0.8),
                pw.Text(
                  'Proveedor: ${purchase['provider_name'] ?? 'Sin proveedor'}',
                  style: const pw.TextStyle(fontSize: 9.5),
                ),
                pw.Text(
                  'Fecha original: $purchaseDateStr',
                  style: const pw.TextStyle(fontSize: 9.5),
                ),
                pw.Text(
                  'Anuló: ${prefs.userName}',
                  style: const pw.TextStyle(fontSize: 9.5),
                ),
                pw.Divider(color: primaryColor, thickness: 0.8),
                pw.Text(
                  'Monto anulado: \$${total.toStringAsFixed(2)}',
                  style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  'El stock de los productos fue descontado del inventario.',
                  style: const pw.TextStyle(
                    fontSize: 8,
                    color: PdfColors.grey700,
                  ),
                ),
                pw.SizedBox(height: 10),
                pw.Center(
                  child: pw.Text(
                    'Documento interno / control de caja',
                    style: const pw.TextStyle(fontSize: 7),
                  ),
                ),
              ],
            ),
      ),
    );

    final bytes = await pdf.save();
    if (!mounted) return;

    final fileName = 'anulacion_compra_${now.millisecondsSinceEpoch}.pdf';
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder:
          (ctx) => Dialog(
            backgroundColor: const Color(0xFF1A1A1A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: SizedBox(
              width: 420,
              height: 560,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        const Text(
                          'COMPRA ANULADA',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.share, color: Colors.blue),
                          onPressed:
                              () => Printing.sharePdf(
                                bytes: bytes,
                                filename: fileName,
                              ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.print,
                            color: Theme.of(ctx).colorScheme.primary,
                          ),
                          onPressed:
                              () => Printing.layoutPdf(
                                onLayout: (_) async => bytes,
                                name: fileName,
                              ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PdfPreview(
                      padding: const EdgeInsets.all(12),
                      build: (_) => Future.value(bytes),
                      allowSharing: false,
                      allowPrinting: false,
                      initialPageFormat: const PdfPageFormat(
                        80 * PdfPageFormat.mm,
                        200 * PdfPageFormat.mm,
                      ),
                      pageFormats: const {},
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  Future<Uint8List?> _loadLogoBytes() => loadBusinessLogo(PreferencesService());

  // ─────────────────────────────────────────────────────────────
  // ETAPA 4 — Pestaña UTILIDAD
  // ─────────────────────────────────────────────────────────────

  Widget _buildProfitTab(Color primary) {
    final sales = _profit['sales'] ?? 0;
    final costsAvailable = _profit['costsAvailable'] == true;
    final cost = _profit['costOfGoodsSold'];
    final expenses = _profit['expenses'] ?? 0;
    final profit = _profit['profit'];
    final salesCount = (_profit['salesCount'] ?? 0).toInt();
    final profitColor =
        !costsAvailable || !_sharedCashCurrent
            ? Colors.white38
            : profit >= 0
            ? Colors.greenAccent
            : Colors.redAccent;

    return Column(
      children: [
        _buildDateFilter(),
        Expanded(
          child: RefreshIndicator(
            color: primary,
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              children: [
                _StatsCard(
                  label: 'Ventas ($salesCount)',
                  value: formatReportMoney(sales),
                  icon: Icons.arrow_upward,
                  color: Colors.greenAccent,
                ),
                const SizedBox(height: 12),
                _StatsCard(
                  label: 'Costo de lo vendido',
                  value:
                      costsAvailable
                          ? '-${formatReportMoney(cost)}'
                          : 'No disponible',
                  icon: Icons.inventory,
                  color: Colors.orangeAccent,
                ),
                const SizedBox(height: 12),
                _StatsCard(
                  label: 'Retiros/Gastos',
                  value: '-${formatReportMoney(expenses)}',
                  icon: Icons.arrow_downward,
                  color: Colors.redAccent,
                ),
                const SizedBox(height: 12),
                _StatsCard(
                  label: 'UTILIDAD NETA',
                  value:
                      costsAvailable && _sharedCashCurrent
                          ? formatReportMoney(profit)
                          : 'No disponible',
                  icon: Icons.trending_up,
                  color: profitColor,
                ),
                if (!costsAvailable)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Faltan costos de una o más ventas. Actualiza la información antes de consultar la utilidad.',
                      style: TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
                if (!_sharedCashCurrent)
                  const Text(
                    'Sin conexión: pueden faltar gastos de caja compartida. Actualiza para consultar la utilidad.',
                    style: TextStyle(color: Colors.orangeAccent),
                  ),
                const SizedBox(height: 20),
                Text(
                  'DESGLOSE DE GASTOS POR CONCEPTO',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 12,
                    letterSpacing: 1,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                if (_profitExpenses.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Sin retiros/gastos en el periodo.',
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                else
                  ..._profitExpenses.map((e) {
                    final concept = e['concept'] ?? '';
                    final amount = double.tryParse(e['amount'] ?? '0') ?? 0;
                    return Card(
                      color: const Color(0xFF1A1A1A),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        leading: Icon(Icons.receipt, color: Colors.redAccent),
                        title: Text(
                          concept,
                          style: const TextStyle(color: Colors.white),
                        ),
                        trailing: Text(
                          formatReportMoney(amount),
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    );
                  }),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: primary,
                    side: BorderSide(color: primary),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('TICKET DE UTILIDAD'),
                  onPressed:
                      costsAvailable && _sharedCashCurrent
                          ? _showProfitPdf
                          : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Ticket (vista previa en app) del informe de utilidad del periodo.
  Future<void> _showProfitPdf() async {
    if (_profit['costsAvailable'] != true || !_sharedCashCurrent) {
      throw StateError(
        'No se puede generar utilidad sin costos completos y gastos sincronizados.',
      );
    }
    final sales = _profit['sales'] ?? 0;
    final cost = _profit['costOfGoodsSold'] ?? 0;
    final expenses = _profit['expenses'] ?? 0;
    final profit = _profit['profit'] ?? 0;
    final salesCount = (_profit['salesCount'] ?? 0).toInt();

    final dateStr =
        '${_start.day.toString().padLeft(2, '0')}/${_start.month.toString().padLeft(2, '0')} - ${_end.day.toString().padLeft(2, '0')}/${_end.month.toString().padLeft(2, '0')}/${_end.year}';

    final bodyLines = <String>[
      'Periodo: $dateStr',
      '--------------------------------',
      'Ventas ($salesCount): ${formatReportMoney(sales)}',
      'Costo de lo vendido: -${formatReportMoney(cost)}',
      'Retiros/Gastos: -${formatReportMoney(expenses)}',
      '--------------------------------',
    ];
    for (final e in _profitExpenses) {
      final amount = double.tryParse(e['amount'] ?? '0') ?? 0;
      bodyLines.add('  ${e['concept']}: ${formatReportMoney(amount)}');
    }
    if (_profitExpenses.isEmpty) bodyLines.add('  (sin gastos)');

    await showReportReceipt(
      context,
      title: 'INFORME DE UTILIDAD',
      subtitle: '',
      bodyLines: bodyLines,
      boldLabel: 'UTILIDAD NETA',
      boldAmount: profit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'INFORMES',
          style: TextStyle(color: primary, fontWeight: FontWeight.bold),
        ),
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
            Tab(icon: Icon(Icons.trending_up), text: 'Utilidad'),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Historial de ventas',
            onPressed:
                () => Navigator.pushNamed(context, AppRoutes.salesHistory),
          ),
        ],
      ),
      body:
          _isLoading
              ? Center(child: CircularProgressIndicator(color: primary))
              : _loadError != null
              ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('No se pudieron cargar los informes: $_loadError'),
                    TextButton(
                      onPressed: _load,
                      child: const Text('REINTENTAR'),
                    ),
                  ],
                ),
              )
              : TabBarView(
                controller: _tabCtrl,
                children: [
                  _buildSalesTab(primary),
                  _buildPurchasesTab(),
                  _buildCashFlowTab(primary),
                  _buildKardexTab(primary),
                  _buildProfitTab(primary),
                ],
              ),
    );
  }

  Widget _buildDateFilter() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1A1A1A),
        ),
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
    final summary = _sales.fold<double>(
      0,
      (a, s) => a + (s['total'] as num).toDouble(),
    );
    return Column(
      children: [
        _buildDateFilter(),
        _StatsCard(
          label: 'Ventas',
          value: '${_sales.length}',
          icon: Icons.receipt_long,
          color: primary,
        ),
        const SizedBox(height: 12),
        _StatsCard(
          label: 'Total',
          value: '\$${summary.toStringAsFixed(2)}',
          icon: Icons.attach_money,
          color: Colors.greenAccent,
        ),
        const SizedBox(height: 12),
        Expanded(
          child:
              _sales.isEmpty
                  ? const Center(
                    child: Text(
                      'Sin ventas en el periodo',
                      style: TextStyle(color: Colors.white24),
                    ),
                  )
                  : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _sales.length,
                    itemBuilder: (_, i) {
                      final s = _sales[i];
                      final date =
                          DateTime.tryParse(s['date'] ?? '') ?? DateTime.now();
                      final isMesa = (s['type'] as String).contains('Mesa');
                      final color = isMesa ? const Color(0xFF1E88E5) : primary;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: Icon(
                            isMesa ? Icons.table_bar : Icons.sell,
                            color: color,
                          ),
                          title: Text(
                            s['type'] ?? 'Venta',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} | ${s['payment_method']}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                          trailing: Text(
                            '\$${(s['total'] as num).toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
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
    final summary = _purchases.fold<double>(
      0,
      (a, p) => a + (p['total'] as num).toDouble(),
    );
    return Column(
      children: [
        _StatsCard(
          label: 'Compras',
          value: '${_purchases.length}',
          icon: Icons.shopping_cart,
          color: Colors.orangeAccent,
        ),
        const SizedBox(height: 12),
        _StatsCard(
          label: 'Total',
          value: '\$${summary.toStringAsFixed(2)}',
          icon: Icons.attach_money,
          color: Colors.greenAccent,
        ),
        const SizedBox(height: 12),
        Expanded(
          child:
              _purchases.isEmpty
                  ? const Center(
                    child: Text(
                      'Sin compras registradas',
                      style: TextStyle(color: Colors.white24),
                    ),
                  )
                  : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _purchases.length,
                    itemBuilder: (_, i) {
                      final p = _purchases[i];
                      final date =
                          DateTime.tryParse(p['date'] ?? '') ?? DateTime.now();
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: const Icon(
                            Icons.shopping_cart,
                            color: Colors.orangeAccent,
                          ),
                          title: Text(
                            p['provider_name'] ?? 'Compra',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                          trailing: Text(
                            '\$${(p['total'] as num).toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
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
    return CashFlowReport(
      summary: _cashFlow,
      dateFilter: Column(
        children: [
          _buildDateFilter(),
          if (!_sharedCashCurrent)
            const Text(
              'Sin conexión: movimientos compartidos guardados en este teléfono; pueden faltar operaciones.',
            ),
        ],
      ),
    );
  }

  Widget _buildKardexTab(Color primary) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: DropdownButtonFormField<int?>(
            initialValue: _selectedProductId,
            dropdownColor: const Color(0xFF1A1A1A),
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Seleccionar producto',
              labelStyle: TextStyle(color: Colors.white38),
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text(
                  'Selecciona...',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
              ..._products.map(
                (p) => DropdownMenuItem(
                  value: p.id,
                  child: Text(
                    p.name,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
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
          child:
              _movements.isEmpty
                  ? const Center(
                    child: Text(
                      'Selecciona un producto para ver su kardex',
                      style: TextStyle(color: Colors.white24),
                    ),
                  )
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
                            type == 'sale'
                                ? Icons.arrow_downward
                                : Icons.arrow_upward,
                            color:
                                type == 'sale'
                                    ? Colors.redAccent
                                    : Colors.greenAccent,
                          ),
                          title: Text(
                            type.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            '${m['created_at']}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                          trailing: Text(
                            '${isNegative ? '' : '+'}${qty.toStringAsFixed(2)}',
                            style: TextStyle(
                              color:
                                  isNegative
                                      ? Colors.redAccent
                                      : Colors.greenAccent,
                              fontWeight: FontWeight.bold,
                            ),
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

class CashFlowReport extends StatelessWidget {
  const CashFlowReport({
    super.key,
    required this.summary,
    this.dateFilter = const SizedBox.shrink(),
  });

  final Map<String, double> summary;
  final Widget dateFilter;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          dateFilter,
          const Text('FLUJO DE CAJA · SOLO CONSULTA'),
          const Text('Los movimientos y turnos se operan desde Caja y turnos.'),
          for (final (label, key) in [
            ('Cobros (todos los medios)', 'totalSales'),
            ('Pagos de compras (todos los orígenes)', 'totalPurchases'),
            ('Retiros/Gastos (todos los medios)', 'totalOutflows'),
            ('Aportes manuales (no son ventas)', 'inflows'),
            ('Flujo neto total', 'netFlow'),
            ('Movimiento neto de efectivo', 'netCash'),
            ('Cobros con tarjeta', 'cardSales'),
            ('Cobros por transferencia', 'transferSales'),
            ('Compras a crédito (no son pagos)', 'creditPurchases'),
          ]) ...[
            const SizedBox(height: 12),
            _StatsCard(
              label: label,
              value: formatReportMoney(summary[key] ?? 0),
              icon: Icons.account_balance_wallet,
              color: primary,
            ),
          ],
        ],
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _StatsCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

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
        gradient:
            (solid || outlined)
                ? null
                : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    color.withValues(alpha: 0.18),
                    const Color(0xFF1A1A1A),
                  ],
                ),
        border: Border.all(
          color:
              solid
                  ? Colors.white.withValues(alpha: 0.28)
                  : color.withValues(alpha: outlined ? 1.0 : 0.35),
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
                  color:
                      solid
                          ? Colors.white.withValues(alpha: 0.75)
                          : Colors.white38,
                  fontSize: 13,
                  letterSpacing: 1,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  color: contentColor,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
