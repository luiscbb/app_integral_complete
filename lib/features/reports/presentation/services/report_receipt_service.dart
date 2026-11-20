import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../../../core/storage/preferences_service.dart';
import '../../../../core/services/business_logo_loader.dart';

String formatReportMoney(double v) {
  final fixed = v.toStringAsFixed(2);
  final neg = fixed.startsWith('-');
  final body = neg ? fixed.substring(1) : fixed;
  final parts = body.split('.');
  final intPart = parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  return '${neg ? '-' : ''}\$${buf.toString()}.${parts[1]}';
}

Future<void> showReportPdfPreview(
  BuildContext context,
  Uint8List bytes,
  String title,
  String fileName,
) async {
  if (!context.mounted) return;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder:
        (ctx) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.9,
          maxChildSize: 0.95,
          builder:
              (_, ctrl) => Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: const BoxDecoration(
                      color: Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(24),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.share, color: Colors.blue),
                          visualDensity: VisualDensity.compact,
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
                          visualDensity: VisualDensity.compact,
                          onPressed:
                              () => Printing.layoutPdf(
                                onLayout: (_) async => bytes,
                                name: fileName,
                              ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white54),
                          visualDensity: VisualDensity.compact,
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
  );
}

Future<void> showReportReceipt(
  BuildContext context, {
  required String title,
  required String subtitle,
  required List<String> bodyLines,
  required String boldLabel,
  required double boldAmount,
}) async {
  final prefs = PreferencesService();
  final businessName =
      prefs.businessName.trim().isEmpty
          ? 'MI NEGOCIO'
          : prefs.businessName.trim();
  final primaryColor = PdfColor.fromInt(prefs.primaryColorValue);

  pw.MemoryImage? logoImage;
  final logoBytes = await loadBusinessLogo(PreferencesService());
  if (logoBytes != null) {
    logoImage = pw.MemoryImage(logoBytes);
  }

  final pdf = pw.Document();
  final now = DateTime.now();
  final dateStr =
      '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}  ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

  final titleStyle = pw.TextStyle(
    fontWeight: pw.FontWeight.bold,
    fontSize: 12,
    color: PdfColors.black,
    letterSpacing: 1,
  );
  final normalStyle = pw.TextStyle(fontSize: 9.5, color: PdfColors.black);
  final boldStyle = pw.TextStyle(
    fontWeight: pw.FontWeight.bold,
    fontSize: 10,
    color: PdfColors.black,
  );
  final smallStyle = pw.TextStyle(fontSize: 8, color: PdfColors.grey700);

  pdf.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.roll80,
      build: (pw.Context ctx) {
        return pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.SizedBox(height: 4),
            if (logoImage != null) ...[
              pw.Center(child: pw.Image(logoImage, width: 56, height: 56)),
              pw.SizedBox(height: 4),
            ],
            pw.Center(
              child: pw.Text(businessName.toUpperCase(), style: titleStyle),
            ),
            pw.SizedBox(height: 2),
            pw.Center(child: pw.Text(title, style: boldStyle)),
            pw.SizedBox(height: 2),
            pw.Center(child: pw.Text(dateStr, style: smallStyle)),
            pw.SizedBox(height: 2),
            pw.Divider(color: primaryColor, thickness: 0.8),
            if (subtitle.isNotEmpty) pw.Text(subtitle, style: normalStyle),
            pw.Divider(color: primaryColor, thickness: 0.8),
            ...bodyLines.map((l) => pw.Text(l, style: normalStyle)),
            pw.Divider(color: primaryColor, thickness: 0.8),
            pw.Text(
              '$boldLabel: ${formatReportMoney(boldAmount)}',
              style: boldStyle,
            ),
            pw.SizedBox(height: 10),
            pw.Center(
              child: pw.Text(
                'Documento interno / control de caja',
                style: const pw.TextStyle(fontSize: 7),
              ),
            ),
          ],
        );
      },
    ),
  );

  final bytes = await pdf.save();
  if (!context.mounted) return;
  await showReportPdfPreview(
    context,
    bytes,
    title,
    'caja_${now.millisecondsSinceEpoch}.pdf',
  );
}
