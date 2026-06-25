import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:blue_thermal_printer/blue_thermal_printer.dart';

import '../../../../core/storage/preferences_service.dart';
import '../../domain/entities/sale_item_entity.dart';

class TicketService {
  final _prefs = PreferencesService();

  double get _mmWidth => _prefs.printWidth == '58mm' ? 58 : 80;

  Future<void> printTicket({
    required List<SaleItemEntity> items,
    required double total,
    required double paid,
    required String paymentMethod,
    required String saleType,
    required BuildContext context,
  }) async {
    if (Platform.isAndroid) {
      await _printBluetooth(items, total, paid, paymentMethod, saleType, context);
    } else {
      final doc = await _buildPdf(items, total, paid, paymentMethod, saleType);
      final bytes = await doc.save();
      await Printing.layoutPdf(onLayout: (_) => bytes);
    }
  }

  Future<void> _printBluetooth(
    List<SaleItemEntity> items,
    double total,
    double paid,
    String paymentMethod,
    String saleType,
    BuildContext context,
  ) async {
    final bluetooth = BlueThermalPrinter.instance;

    List<BluetoothDevice> devices = [];
    try {
      devices = await bluetooth.getBondedDevices();
    } catch (_) {}

    if (devices.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No hay impresoras Bluetooth vinculadas. Vincula la impresora en Ajustes > Bluetooth.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    if (!context.mounted) return;

    final selected = await showModalBottomSheet<BluetoothDevice>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        final primary = Theme.of(ctx).colorScheme.primary;
        return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('SELECCIONAR IMPRESORA BLUETOOTH',
                style: TextStyle(
                    color: primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 1)),
          ),
          const Divider(color: Colors.white10),
          ...devices.map((d) => ListTile(
                leading: Icon(Icons.bluetooth, color: primary),
                title: Text(d.name ?? 'Desconocido',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: Text(d.address ?? '',
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
                onTap: () => Navigator.pop(ctx, d),
              )),
          const SizedBox(height: 16),
        ],
      );
      },
    );

    if (selected == null) return;

    try {
      try {
        await bluetooth.disconnect();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));

      await bluetooth.connect(selected);
      await Future.delayed(const Duration(milliseconds: 800));

      final isConnected = await bluetooth.isConnected ?? false;
      if (!isConnected) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo conectar a la impresora'), backgroundColor: Colors.red),
          );
        }
        return;
      }

      await bluetooth.writeBytes(Uint8List.fromList([0x1B, 0x40]));
      await Future.delayed(const Duration(milliseconds: 100));

      final now = DateTime.now();
      final dateStr =
          '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      final sep = _mmWidth == 58 ? '------------------------' : '--------------------------------';

      final logoPath = _prefs.logoPath;
      if (logoPath.isNotEmpty) {
        final logoFile = File(logoPath);
        if (await logoFile.exists()) {
          try {
            await bluetooth.printImage(logoPath);
            await bluetooth.printNewLine();
          } catch (_) {}
        }
      }

      final buf = StringBuffer();
      buf.write('${_prefs.businessName.toUpperCase()}\n');
      buf.write('$dateStr\n');
      buf.write('$saleType | $paymentMethod\n');
      buf.write('Atendio: ${_prefs.userName}\n');
      buf.write('$sep\n');

      final computedTotal = items.fold<double>(0, (acc, item) => acc + item.price * item.quantity);
      final safeTotal = total > 0 ? total : computedTotal;

      for (final item in items) {
        final name = item.productName.length > 18
            ? item.productName.substring(0, 18)
            : item.productName;
        buf.write('$name\n');
        final detail = '  \$${item.price.toStringAsFixed(2)} x${item.qtyLabel}';
        final price = '\$${(item.price * item.quantity).toStringAsFixed(2)}';
        final spaces = sep.length - detail.length - price.length;
        buf.write('$detail${' ' * (spaces > 1 ? spaces : 1)}$price\n');
      }

      buf.write('$sep\n');
      buf.write('TOTAL: \$${safeTotal.toStringAsFixed(2)}\n');

      if (paymentMethod == 'Efectivo' && paid > 0) {
        buf.write('PAGO:   \$${paid.toStringAsFixed(2)}\n');
        final change = (paid - safeTotal) < 0 ? 0.0 : (paid - safeTotal);
        buf.write('CAMBIO: \$${change.toStringAsFixed(2)}\n');
      }

      buf.write('\n');
      buf.write('*** GRACIAS POR SU COMPRA ***\n');
      buf.write('\n\n\n');

      await bluetooth.write(buf.toString());
      await Future.delayed(const Duration(milliseconds: 1500));
      await bluetooth.disconnect();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ticket enviado a la impresora'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al imprimir: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> sharePdf({
    required List<SaleItemEntity> items,
    required double total,
    required double paid,
    required String paymentMethod,
    required String saleType,
  }) async {
    final doc = await _buildPdf(items, total, paid, paymentMethod, saleType);
    final bytes = await doc.save();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/ticket_baumar.pdf');
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Ticket de Venta'));
  }

  Future<void> showPreviewSheet({
    required BuildContext context,
    required List<SaleItemEntity> items,
    required double total,
    required double paid,
    required String paymentMethod,
    required String saleType,
  }) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (_, ctrl) => TicketPreviewSheet(
          items: items,
          total: total,
          paid: paid,
          paymentMethod: paymentMethod,
          saleType: saleType,
          onPrint: () => printTicket(
            items: items, total: total, paid: paid,
            paymentMethod: paymentMethod, saleType: saleType, context: context,
          ),
          onShare: () => sharePdf(
            items: items, total: total, paid: paid,
            paymentMethod: paymentMethod, saleType: saleType,
          ),
        ),
      ),
    );
  }

  Future<pw.Document> _buildPdf(
    List<SaleItemEntity> items,
    double total,
    double paid,
    String paymentMethod,
    String saleType,
  ) async {
    final doc = pw.Document();
    final now = DateTime.now();
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}  ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    pw.MemoryImage? logoImage;
    final logoPath = _prefs.logoPath;
    if (logoPath.isNotEmpty) {
      final file = File(logoPath);
      if (await file.exists()) {
        logoImage = pw.MemoryImage(await file.readAsBytes());
      }
    }

    // Total real calculado desde los items (evita Total=0 por valores desincronizados)
    final computedTotal = items.fold<double>(0, (acc, item) => acc + item.price * item.quantity);
    final safeTotal = total > 0 ? total : computedTotal;
    final cashierName = _prefs.userName;

    final widthMm = _mmWidth;
    final is58 = widthMm == 58;
    final pageWidth = widthMm * PdfPageFormat.mm;

    // Calcular altura dinámica según contenido (58mm usa 2 líneas por item)
    final itemHeight = (is58 ? 9 : 7) * PdfPageFormat.mm;
    final headerHeight = (logoImage != null ? 54 : 38) * PdfPageFormat.mm;
    final footerHeight = (paymentMethod == 'Efectivo' && paid > 0 ? 34 : 24) * PdfPageFormat.mm;
    final pageHeight = headerHeight + (items.length + 1) * itemHeight + footerHeight + 4 * PdfPageFormat.mm;
    final format = PdfPageFormat(pageWidth, pageHeight, marginAll: (is58 ? 3 : 5) * PdfPageFormat.mm);

    const white = PdfColors.white;
    const black = PdfColors.black;
    final primaryColor = PdfColor.fromInt(_prefs.primaryColorValue);
    const grey = PdfColors.grey700;

    final titleStyle = pw.TextStyle(
      fontWeight: pw.FontWeight.bold,
      fontSize: is58 ? 11 : 14,
      color: black,
      letterSpacing: is58 ? 0.5 : 1,
    );
    final normalStyle = pw.TextStyle(fontSize: is58 ? 8 : 9.5, color: black);
    final boldStyle = pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: is58 ? 8.5 : 10, color: black);
    final smallStyle = pw.TextStyle(fontSize: is58 ? 7 : 8, color: grey);
    final colHeadStyle = pw.TextStyle(fontSize: is58 ? 6.5 : 7.5, color: grey, fontWeight: pw.FontWeight.bold);
    final totalStyle = pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: is58 ? 11 : 13, color: black);

    pw.Widget buildItemRow(SaleItemEntity item) {
      final lineTotal = '\$${(item.price * item.quantity).toStringAsFixed(2)}';
      if (is58) {
        // 58mm: nombre en una línea, detalle (cant x precio) + subtotal debajo
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text(item.productName, style: normalStyle, maxLines: 2),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('${item.qtyLabel} x \$${item.price.toStringAsFixed(2)}', style: smallStyle),
                  pw.Text(lineTotal, style: boldStyle),
                ],
              ),
            ],
          ),
        );
      }
      // 80mm: tabla de 4 columnas
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(flex: 6, child: pw.Text(item.productName, style: normalStyle)),
            pw.Expanded(flex: 3, child: pw.Text('\$${item.price.toStringAsFixed(2)}', style: normalStyle, textAlign: pw.TextAlign.right)),
            pw.Expanded(flex: 2, child: pw.Text(item.qtyLabel, style: normalStyle, textAlign: pw.TextAlign.center)),
            pw.Expanded(flex: 3, child: pw.Text(lineTotal, style: boldStyle, textAlign: pw.TextAlign.right)),
          ],
        ),
      );
    }

    pw.Widget buildColumnsHeader() {
      if (is58) {
        return pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('CANT x P.UNIT', style: colHeadStyle),
            pw.Text('IMPORTE', style: colHeadStyle),
          ],
        );
      }
      return pw.Row(
        children: [
          pw.Expanded(flex: 6, child: pw.Text('PRODUCTO', style: colHeadStyle)),
          pw.Expanded(flex: 3, child: pw.Text('P.UNIT', style: colHeadStyle, textAlign: pw.TextAlign.right)),
          pw.Expanded(flex: 2, child: pw.Text('CANT', style: colHeadStyle, textAlign: pw.TextAlign.center)),
          pw.Expanded(flex: 3, child: pw.Text('IMPORTE', style: colHeadStyle, textAlign: pw.TextAlign.right)),
        ],
      );
    }

    pw.Widget buildSummaryRow(String label, String value, {bool emphasize = false, PdfColor? valueColor}) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label, style: emphasize ? totalStyle : normalStyle),
            pw.Text(value, style: emphasize
                ? (valueColor != null ? pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: is58 ? 11 : 13, color: valueColor) : totalStyle)
                : normalStyle),
          ],
        ),
      );
    }

    final logoSize = is58 ? 44.0 : 56.0;

    doc.addPage(
      pw.Page(
        pageFormat: format,
        build: (ctx) => pw.Container(
          color: white,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.SizedBox(height: 4),
              if (logoImage != null) ...[
                pw.Image(logoImage, width: logoSize, height: logoSize),
                pw.SizedBox(height: 4),
              ],
              pw.Text(_prefs.businessName.toUpperCase(), style: titleStyle, textAlign: pw.TextAlign.center),
              pw.SizedBox(height: 3),
              pw.Text(dateStr, style: smallStyle),
              pw.Text('Tipo: $saleType', style: smallStyle),
              pw.Text('Pago: $paymentMethod', style: smallStyle),
              pw.Text('Atendió: $cashierName', style: smallStyle),
              pw.SizedBox(height: 2),
              pw.Divider(color: primaryColor, thickness: 0.8),
              buildColumnsHeader(),
              pw.SizedBox(height: 2),
              ...items.map(buildItemRow),
              pw.Divider(color: primaryColor, thickness: 0.8),
              buildSummaryRow('TOTAL', '\$${safeTotal.toStringAsFixed(2)}', emphasize: true),
              if (paymentMethod == 'Efectivo' && paid > 0) ...[
                buildSummaryRow('PAGO', '\$${paid.toStringAsFixed(2)}'),
                buildSummaryRow(
                  'CAMBIO',
                  '\$${(paid - safeTotal) < 0 ? '0.00' : (paid - safeTotal).toStringAsFixed(2)}',
                  emphasize: true,
                  valueColor: primaryColor,
                ),
              ],
              pw.SizedBox(height: 8),
              pw.Text('*** GRACIAS POR SU COMPRA ***',
                  style: pw.TextStyle(color: primaryColor, fontWeight: pw.FontWeight.bold, fontSize: is58 ? 8 : 9.5),
                  textAlign: pw.TextAlign.center),
              pw.SizedBox(height: 2),
              pw.Text(_prefs.businessName, style: smallStyle, textAlign: pw.TextAlign.center),
              pw.SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
    return doc;
  }
}

class TicketPreviewSheet extends StatelessWidget {
  final List<SaleItemEntity> items;
  final double total;
  final double paid;
  final String paymentMethod;
  final String saleType;
  final VoidCallback onPrint;
  final VoidCallback onShare;

  const TicketPreviewSheet({
    super.key,
    required this.items,
    required this.total,
    required this.paid,
    required this.paymentMethod,
    required this.saleType,
    required this.onPrint,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final prefs = PreferencesService();
    final logo = prefs.logoPath;
    final primary = Theme.of(context).colorScheme.primary;
    final computedTotal = items.fold<double>(0, (acc, item) => acc + item.price * item.quantity);
    final safeTotal = total > 0 ? total : computedTotal;
    final is58 = prefs.printWidth == '58mm';
    // El ancho del recibo en pantalla refleja el papel seleccionado
    final sheetWidth = is58 ? 240.0 : 320.0;

    return Container(
      color: Colors.grey[200],
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('VISTA PREVIA TICKET',
                  style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 15)),
              Row(
                children: [
                  IconButton(icon: const Icon(Icons.share, color: Colors.blue), onPressed: onShare),
                  IconButton(icon: Icon(Icons.print, color: primary), onPressed: onPrint),
                ],
              ),
            ],
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: sheetWidth),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 8)],
                  ),
                  child: CustomPaint(
                    painter: const _DentedEdgePainter(),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (logo.isNotEmpty && File(logo).existsSync())
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(File(logo), width: 56, height: 56, fit: BoxFit.contain),
                              ),
                            const SizedBox(height: 6),
                            Text(prefs.businessName.toUpperCase(),
                                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 15, letterSpacing: 2)),
                            const SizedBox(height: 4),
                            Text(
                              '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}  ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                              style: const TextStyle(color: Colors.black54, fontSize: 11),
                            ),
                            Text('$saleType | $paymentMethod',
                                style: const TextStyle(color: Colors.black54, fontSize: 10)),
                            Text('Atendió: ${prefs.userName}',
                                style: const TextStyle(color: Colors.black54, fontSize: 10)),
                            Divider(color: primary, thickness: 0.5),
                            if (is58)
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: const [
                                  Text('CANT x P.UNIT', style: TextStyle(color: Colors.black45, fontSize: 8, fontWeight: FontWeight.bold)),
                                  Text('IMPORTE', style: TextStyle(color: Colors.black45, fontSize: 8, fontWeight: FontWeight.bold)),
                                ],
                              )
                            else
                              Row(
                                children: const [
                                  Expanded(flex: 6, child: Text('PRODUCTO', style: TextStyle(color: Colors.black45, fontSize: 8.5, fontWeight: FontWeight.bold))),
                                  Expanded(flex: 3, child: Text('P.UNIT', textAlign: TextAlign.right, style: TextStyle(color: Colors.black45, fontSize: 8.5, fontWeight: FontWeight.bold))),
                                  Expanded(flex: 2, child: Text('CANT', textAlign: TextAlign.center, style: TextStyle(color: Colors.black45, fontSize: 8.5, fontWeight: FontWeight.bold))),
                                  Expanded(flex: 3, child: Text('IMPORTE', textAlign: TextAlign.right, style: TextStyle(color: Colors.black45, fontSize: 8.5, fontWeight: FontWeight.bold))),
                                ],
                              ),
                            const SizedBox(height: 2),
                            ...items.map((item) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: is58
                                  ? Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        Text(item.productName, style: const TextStyle(color: Colors.black87, fontSize: 11)),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text('${item.qtyLabel} x \$${item.price.toStringAsFixed(2)}', style: const TextStyle(color: Colors.black54, fontSize: 10)),
                                            Text('\$${(item.price * item.quantity).toStringAsFixed(2)}', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11)),
                                          ],
                                        ),
                                      ],
                                    )
                                  : Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Expanded(flex: 6, child: Text(item.productName, style: const TextStyle(color: Colors.black87, fontSize: 11))),
                                        Expanded(flex: 3, child: Text('\$${item.price.toStringAsFixed(2)}', textAlign: TextAlign.right, style: const TextStyle(color: Colors.black54, fontSize: 11))),
                                        Expanded(flex: 2, child: Text(item.qtyLabel, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54, fontSize: 11))),
                                        Expanded(flex: 3, child: Text('\$${(item.price * item.quantity).toStringAsFixed(2)}', textAlign: TextAlign.right, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11))),
                                      ],
                                    ),
                            )),
                            Divider(color: primary, thickness: 0.5),
                            _row('TOTAL', '\$${safeTotal.toStringAsFixed(2)}', bold: true, valueColor: Colors.green[700]),
                            if (paymentMethod == 'Efectivo' && paid > 0) ...[
                              _row('PAGO', '\$${paid.toStringAsFixed(2)}'),
                              _row('CAMBIO', '\$${(paid - safeTotal) < 0 ? '0.00' : (paid - safeTotal).toStringAsFixed(2)}', bold: true, valueColor: Colors.orange),
                            ],
                            const SizedBox(height: 10),
                            Text('*** GRACIAS POR SU COMPRA ***',
                                style: TextStyle(color: primary, fontWeight: FontWeight.bold, fontSize: 11)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.black54, fontSize: 12, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          Text(value, style: TextStyle(color: valueColor ?? Colors.black, fontSize: 12, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }
}

class _DentedEdgePainter extends CustomPainter {
  const _DentedEdgePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.grey[300]!;
    const r = 7.0;
    const count = 12;
    final spacing = size.width / count;

    for (int i = 0; i < count; i++) {
      canvas.drawCircle(Offset(spacing * i + spacing / 2, 0), r, paint);
      canvas.drawCircle(Offset(spacing * i + spacing / 2, size.height), r, paint);
    }
  }

  @override
  bool shouldRepaint(_) => false;
}
