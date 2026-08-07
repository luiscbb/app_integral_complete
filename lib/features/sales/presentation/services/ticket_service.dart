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

  Future<int> _nextTicketNumber(int? provided) async {
    if (provided != null && provided > 0) return provided;
    final next = _prefs.ticketCounter + 1;
    await _prefs.setTicketCounter(next);
    return next;
  }

  Future<Uint8List?> _loadLogoBytes() async {
    // Preferir archivo local si existe.
    final logoPath = _prefs.logoPath;
    if (logoPath.isNotEmpty) {
      final file = File(logoPath);
      if (await file.exists()) {
        return file.readAsBytes();
      }
    }
    // Fallback a URL remota (logo sincronizado entre dispositivos).
    final logoUrl = _prefs.logoUrl;
    if (logoUrl.isNotEmpty) {
      try {
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse(logoUrl));
        final res = await req.close().timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final bytes = <int>[];
          await for (final chunk in res) {
            bytes.addAll(chunk);
          }
          client.close();
          return Uint8List.fromList(bytes);
        }
        client.close();
      } catch (_) {}
    }
    return null;
  }

  Future<void> printTicket({
    required List<SaleItemEntity> items,
    required double total,
    required double paid,
    required String paymentMethod,
    required String saleType,
    required BuildContext context,
    int? ticketNumber,
  }) async {
    final resolvedTicketNumber = await _nextTicketNumber(ticketNumber);
    if (!context.mounted) return;
    if (Platform.isAndroid) {
      await _printBluetooth(
        items,
        total,
        paid,
        paymentMethod,
        saleType,
        context,
        ticketNumber: resolvedTicketNumber,
      );
    } else {
      final doc = await _buildPdf(
        items,
        total,
        paid,
        paymentMethod,
        saleType,
        ticketNumber: resolvedTicketNumber,
      );
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
    BuildContext context, {
    required int ticketNumber,
  }) async {
    final bluetooth = BlueThermalPrinter.instance;

    List<BluetoothDevice> devices = [];
    try {
      devices = await bluetooth.getBondedDevices();
    } catch (_) {}

    if (devices.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No hay impresoras Bluetooth vinculadas. Vincula la impresora en Ajustes > Bluetooth.',
            ),
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final primary = Theme.of(ctx).colorScheme.primary;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'SELECCIONAR IMPRESORA BLUETOOTH',
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 1,
                ),
              ),
            ),
            const Divider(color: Colors.white10),
            ...devices.map(
              (d) => ListTile(
                leading: Icon(Icons.bluetooth, color: primary),
                title: Text(
                  d.name ?? 'Desconocido',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  d.address ?? '',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                onTap: () => Navigator.pop(ctx, d),
              ),
            ),
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
            const SnackBar(
              content: Text('No se pudo conectar a la impresora'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      await bluetooth.writeBytes(Uint8List.fromList([0x1B, 0x40]));
      await Future.delayed(const Duration(milliseconds: 100));

      // Centrar texto
      await bluetooth.writeBytes(Uint8List.fromList([0x1B, 0x61, 0x01]));

      final layout = _TicketLayout(
        prefs: _prefs,
        items: items,
        total: total,
        paid: paid,
        paymentMethod: paymentMethod,
        saleType: saleType,
        ticketNumber: ticketNumber,
      );

      final logoBytes = await _loadLogoBytes();
      if (logoBytes != null) {
        try {
          await bluetooth.printImageBytes(logoBytes);
          await bluetooth.printNewLine();
        } catch (_) {}
      }

      for (final line in layout.bluetoothHeaderLines()) {
        for (final sub in line.split('\n')) {
          await bluetooth.write(sub);
          await bluetooth.printNewLine();
        }
      }

      await bluetooth.write(layout.bluetoothSeparator);
      await bluetooth.printNewLine();

      for (final line in layout.bluetoothMetaLines()) {
        await bluetooth.write(line);
        await bluetooth.printNewLine();
      }
      await bluetooth.write('Tipo: $saleType | Pago: $paymentMethod');
      await bluetooth.printNewLine();
      await bluetooth.write('Atendio: ${_prefs.userName}');
      await bluetooth.printNewLine();

      await bluetooth.write(layout.bluetoothSeparator);
      await bluetooth.printNewLine();
      for (final item in layout.itemLines) {
        for (final line in item) {
          await bluetooth.write(line);
          await bluetooth.printNewLine();
        }
      }

      await bluetooth.write(layout.bluetoothSeparator);
      await bluetooth.printNewLine();

      for (final line in layout.totalLines) {
        await bluetooth.write(line);
        await bluetooth.printNewLine();
      }

      if (paymentMethod == 'Efectivo' && paid > 0) {
        await bluetooth.write('PAGO:   \$${paid.toStringAsFixed(2)}');
        await bluetooth.printNewLine();
        final diff = paid - layout.safeTotal;
        final label = diff < 0 ? 'FALTA' : 'CAMBIO';
        await bluetooth.write('$label: \$${diff.abs().toStringAsFixed(2)}');
        await bluetooth.printNewLine();
      }

      await bluetooth.printNewLine();
      for (final line in layout.bluetoothFooterLines()) {
        await bluetooth.write(line);
        await bluetooth.printNewLine();
      }

      await Future.delayed(const Duration(milliseconds: 1500));
      await bluetooth.disconnect();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ticket enviado a la impresora'),
            backgroundColor: Colors.green,
          ),
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
    int? ticketNumber,
  }) async {
    final resolvedTicketNumber = await _nextTicketNumber(ticketNumber);
    final doc = await _buildPdf(
      items,
      total,
      paid,
      paymentMethod,
      saleType,
      ticketNumber: resolvedTicketNumber,
    );
    final bytes = await doc.save();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/ticket_baumar.pdf');
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], subject: 'Ticket de Venta'),
    );
  }

  Future<void> showPreviewSheet({
    required BuildContext context,
    required List<SaleItemEntity> items,
    required double total,
    required double paid,
    required String paymentMethod,
    required String saleType,
    int? ticketNumber,
  }) async {
    final resolvedTicketNumber = ticketNumber ?? (_prefs.ticketCounter + 1);
    final doc = await _buildPdf(
      items,
      total,
      paid,
      paymentMethod,
      saleType,
      ticketNumber: resolvedTicketNumber,
    );
    final bytes = await doc.save();
    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        maxChildSize: 0.95,
        builder: (_, ctrl) => Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1A1A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Row(
                children: [
                  const Text(
                    'VISTA PREVIA DEL TICKET',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.share, color: Colors.blue),
                    onPressed: () => sharePdf(
                      items: items,
                      total: total,
                      paid: paid,
                      paymentMethod: paymentMethod,
                      saleType: saleType,
                      ticketNumber: resolvedTicketNumber,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.print, color: Theme.of(ctx).colorScheme.primary),
                    onPressed: () => printTicket(
                      items: items,
                      total: total,
                      paid: paid,
                      paymentMethod: paymentMethod,
                      saleType: saleType,
                      context: ctx,
                      ticketNumber: resolvedTicketNumber,
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
                initialPageFormat: const PdfPageFormat(80 * PdfPageFormat.mm, 200 * PdfPageFormat.mm),
                pageFormats: const {},
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<pw.Document> _buildPdf(
    List<SaleItemEntity> items,
    double total,
    double paid,
    String paymentMethod,
    String saleType, {
    required int ticketNumber,
  }) async {
    final layout = _TicketLayout(
      prefs: _prefs,
      items: items,
      total: total,
      paid: paid,
      paymentMethod: paymentMethod,
      saleType: saleType,
      ticketNumber: ticketNumber,
    );

    final doc = pw.Document();
    final now = DateTime.now();
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}  ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    pw.MemoryImage? logoImage;
    final logoBytes = await _loadLogoBytes();
    if (logoBytes != null) {
      logoImage = pw.MemoryImage(logoBytes);
    }

    final widthMm = _mmWidth;
    final is58 = widthMm == 58;
    final pageWidth = widthMm * PdfPageFormat.mm;

    final itemHeight = (is58 ? 9 : 7) * PdfPageFormat.mm;
    final headerHeight = (logoImage != null ? 54 : 40) * PdfPageFormat.mm;
    final footerHeight = (paymentMethod == 'Efectivo' && paid > 0 ? 34 : 24) * PdfPageFormat.mm;
    final headerLineCount = layout.pdfHeaderLines(dateStr).length;
    final pageHeight = headerHeight + (headerLineCount * 3 * PdfPageFormat.mm) + (items.length + 1) * itemHeight + footerHeight + 4 * PdfPageFormat.mm;
    final format = PdfPageFormat(pageWidth, pageHeight, marginAll: (is58 ? 2 : 4) * PdfPageFormat.mm);

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
    final boldStyle = pw.TextStyle(
      fontWeight: pw.FontWeight.bold,
      fontSize: is58 ? 8.5 : 10,
      color: black,
    );
    final italicStyle = pw.TextStyle(
      fontStyle: pw.FontStyle.italic,
      fontSize: is58 ? 7.5 : 8.5,
      color: grey,
    );
    final smallStyle = pw.TextStyle(fontSize: is58 ? 7 : 8, color: grey);
    final colHeadStyle = pw.TextStyle(
      fontSize: is58 ? 6.5 : 7.5,
      color: grey,
      fontWeight: pw.FontWeight.bold,
    );
    final totalStyle = pw.TextStyle(
      fontWeight: pw.FontWeight.bold,
      fontSize: is58 ? 11 : 13,
      color: black,
    );
    final tinyStyle = pw.TextStyle(fontSize: is58 ? 6.5 : 7.5, color: grey);
    final farewellStyle = pw.TextStyle(
      color: primaryColor,
      fontWeight: pw.FontWeight.bold,
      fontSize: is58 ? 8 : 9.5,
    );

    pw.Widget buildItemRow(SaleItemEntity item) {
      final lineTotal = '\$${(item.price * item.quantity).toStringAsFixed(2)}';
      if (is58) {
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text(item.productName, style: normalStyle, maxLines: 2),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    '${item.qtyLabel} x \$${item.price.toStringAsFixed(2)}',
                    style: smallStyle,
                  ),
                  pw.Text(lineTotal, style: boldStyle),
                ],
              ),
            ],
          ),
        );
      }
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(flex: 6, child: pw.Text(item.productName, style: normalStyle)),
            pw.Expanded(
              flex: 3,
              child: pw.Text(
                '\$${item.price.toStringAsFixed(2)}',
                style: normalStyle,
                textAlign: pw.TextAlign.right,
              ),
            ),
            pw.Expanded(
              flex: 2,
              child: pw.Text(item.qtyLabel, style: normalStyle, textAlign: pw.TextAlign.center),
            ),
            pw.Expanded(
              flex: 3,
              child: pw.Text(lineTotal, style: boldStyle, textAlign: pw.TextAlign.right),
            ),
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
          pw.Expanded(
            flex: 3,
            child: pw.Text('P.UNIT', style: colHeadStyle, textAlign: pw.TextAlign.right),
          ),
          pw.Expanded(
            flex: 2,
            child: pw.Text('CANT', style: colHeadStyle, textAlign: pw.TextAlign.center),
          ),
          pw.Expanded(
            flex: 3,
            child: pw.Text('IMPORTE', style: colHeadStyle, textAlign: pw.TextAlign.right),
          ),
        ],
      );
    }

    pw.Widget buildSummaryRow(
      String label,
      String value, {
      bool emphasize = false,
      PdfColor? valueColor,
    }) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label, style: emphasize ? totalStyle : normalStyle),
            pw.Text(
              value,
              style: emphasize
                  ? (valueColor != null
                      ? pw.TextStyle(
                          fontWeight: pw.FontWeight.bold,
                          fontSize: is58 ? 11 : 13,
                          color: valueColor,
                        )
                      : totalStyle)
                  : normalStyle,
            ),
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
              pw.Text(
                _prefs.businessName.toUpperCase(),
                style: titleStyle,
                textAlign: pw.TextAlign.center,
              ),
              pw.SizedBox(height: 1),
              if (_prefs.businessSlogan.isNotEmpty)
                pw.Text(
                  '"${_prefs.businessSlogan}"',
                  style: italicStyle,
                  textAlign: pw.TextAlign.center,
                ),
              pw.SizedBox(height: 2),
              ...layout.pdfHeaderLines(dateStr).map(
                    (line) => pw.Text(line, style: tinyStyle, textAlign: pw.TextAlign.center),
                  ),
              if (_prefs.businessWhatsapp.isNotEmpty)
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.center,
                  children: [
                    pw.Text('Whats: ', style: tinyStyle),
                    pw.Text(_prefs.businessWhatsapp, style: smallStyle),
                  ],
                ),
              pw.SizedBox(height: 2),
              pw.Divider(color: primaryColor, thickness: 0.8),
              ...layout.pdfMetaLines(dateStr).map(
                    (line) => pw.Text(line, style: smallStyle, textAlign: pw.TextAlign.center),
                  ),
              pw.Text(
                'Tipo: $saleType | Pago: $paymentMethod',
                style: smallStyle,
                textAlign: pw.TextAlign.center,
              ),
              pw.Text(
                'Atendio: ${_prefs.userName}',
                style: smallStyle,
                textAlign: pw.TextAlign.center,
              ),
              pw.SizedBox(height: 2),
              pw.Divider(color: primaryColor, thickness: 0.8),
              buildColumnsHeader(),
              pw.SizedBox(height: 2),
              ...items.map(buildItemRow),
              pw.Divider(color: primaryColor, thickness: 0.8),
              buildSummaryRow(
                'TOTAL',
                '\$${layout.safeTotal.toStringAsFixed(2)}',
                emphasize: true,
              ),
              if (paymentMethod == 'Efectivo' && paid > 0) ...[
                buildSummaryRow('PAGO', '\$${paid.toStringAsFixed(2)}'),
                buildSummaryRow(
                  (paid - layout.safeTotal) < 0 ? 'FALTA' : 'CAMBIO',
                  '\$${(paid - layout.safeTotal).abs().toStringAsFixed(2)}',
                  emphasize: true,
                  valueColor: primaryColor,
                ),
              ],
              pw.SizedBox(height: 8),
              pw.Text(
                '*** ${_prefs.ticketFarewell.toUpperCase()} ***',
                style: farewellStyle,
                textAlign: pw.TextAlign.center,
              ),
              pw.SizedBox(height: 2),
              if (_prefs.businessWebsite.isNotEmpty)
                pw.Text(
                  _prefs.businessWebsite,
                  style: smallStyle,
                  textAlign: pw.TextAlign.center,
                ),
              if (layout.socialFooter.isNotEmpty)
                pw.Text(
                  layout.socialFooter,
                  style: tinyStyle,
                  textAlign: pw.TextAlign.center,
                ),
              pw.SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
    return doc;
  }
}

/// Layout compartido que calcula las líneas de texto para Bluetooth y PDF.
class _TicketLayout {
  final PreferencesService prefs;
  final List<SaleItemEntity> items;
  final double total;
  final double paid;
  final String paymentMethod;
  final String saleType;
  final int ticketNumber;

  late final double safeTotal;
  late final List<List<String>> itemLines;
  late final List<String> totalLines;
  late final String socialFooter;

  _TicketLayout({
    required this.prefs,
    required this.items,
    required this.total,
    required this.paid,
    required this.paymentMethod,
    required this.saleType,
    required this.ticketNumber,
  }) {
    safeTotal = total > 0 ? total : items.fold<double>(0, (acc, item) => acc + item.price * item.quantity);
    _buildItemLines();
    _buildTotalLines();
    socialFooter = _buildSocialFooter();
  }

  String get bluetoothSeparator {
    return prefs.printWidth == '58mm' ? '------------------------' : '--------------------------------';
  }

  void _buildItemLines() {
    final is58 = prefs.printWidth == '58mm';
    final sep = bluetoothSeparator;
    itemLines = items.map((item) {
      final name = item.productName.length > (is58 ? 18 : 26) ? item.productName.substring(0, is58 ? 18 : 26) : item.productName;
      final detail = '  \$${item.price.toStringAsFixed(2)} x${item.qtyLabel}';
      final price = '\$${(item.price * item.quantity).toStringAsFixed(2)}';
      final spaces = sep.length - detail.length - price.length;
      return [
        name,
        '$detail${' ' * (spaces > 1 ? spaces : 1)}$price',
      ];
    }).toList();
  }

  void _buildTotalLines() {
    totalLines = [
      'TOTAL: \$${safeTotal.toStringAsFixed(2)}',
    ];
  }

  String _buildSocialFooter() {
    if (prefs.socialNetworks.isEmpty) return '';
    return prefs.socialNetworks.entries.map((e) => '@${e.value}').join('  ');
  }

  List<String> pdfHeaderLines(String dateStr) {
    final lines = <String>[];

    final addressPart1 = [
      prefs.businessStreet,
      if (prefs.businessExtNumber.isNotEmpty)
        'No. ${prefs.businessExtNumber}${prefs.businessIntNumber.isNotEmpty ? ' Int. ${prefs.businessIntNumber}' : ''}',
    ].where((s) => s.isNotEmpty).toList();

    final addressPart2 = [
      prefs.businessColony,
      if (prefs.businessCity.isNotEmpty) prefs.businessCity,
    ].where((s) => s.isNotEmpty).toList();

    final addressPart3 = [
      if (prefs.businessState.isNotEmpty) prefs.businessState,
      if (prefs.businessZipCode.isNotEmpty) 'CP ${prefs.businessZipCode}',
    ].where((s) => s.isNotEmpty).toList();

    if (addressPart1.isNotEmpty) lines.add(addressPart1.join(' | '));
    if (addressPart2.isNotEmpty) lines.add(addressPart2.join(' | '));
    if (addressPart3.isNotEmpty) lines.add(addressPart3.join(' | '));

    return lines;
  }

  List<String> pdfMetaLines(String dateStr) {
    return [
      'Folio: #$ticketNumber  |  $dateStr',
    ];
  }

  List<String> bluetoothHeaderLines() {
    final lines = pdfHeaderLines(
      '${DateTime.now().day.toString().padLeft(2, '0')}/${DateTime.now().month.toString().padLeft(2, '0')}/${DateTime.now().year} ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}',
    );
    if (prefs.businessWhatsapp.isNotEmpty) {
      lines.add('Whats: ${prefs.businessWhatsapp}');
    }
    return lines;
  }

  List<String> bluetoothMetaLines() {
    return pdfMetaLines(
      '${DateTime.now().day.toString().padLeft(2, '0')}/${DateTime.now().month.toString().padLeft(2, '0')}/${DateTime.now().year} ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}',
    );
  }

  List<String> bluetoothFooterLines() {
    final lines = <String>[
      '*** ${prefs.ticketFarewell.toUpperCase()} ***',
    ];
    if (prefs.businessWebsite.isNotEmpty) lines.add(prefs.businessWebsite);
    if (socialFooter.isNotEmpty) lines.add(socialFooter);
    return lines;
  }
}
