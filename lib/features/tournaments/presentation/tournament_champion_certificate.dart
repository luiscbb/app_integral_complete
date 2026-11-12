import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../domain/tournament.dart';

class TournamentChampionCertificate {
  static const _trophySvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 140">
  <path fill="#f4bd45" d="M25 14h70v15c0 31-12 49-27 56v17h21v13H31v-13h21V85C37 78 25 60 25 29V14zm13 13v3c0 22 7 36 18 42V27H38zm44 0v45c11-6 18-20 18-42v-3H82zM25 25H8v10c0 21 12 32 29 34l-4-13c-8-4-12-10-12-21h4V25zm70 0v10h4c0 11-4 17-12 21l-4 13c17-2 29-13 29-34V25H95z"/>
  <path fill="#ffe59a" d="M45 19h8v45c-5-5-8-13-8-25V19zm27 0h8v20h-8z"/>
</svg>
''';

  static Future<void> share(TournamentEntity tournament, TournamentEntry? champion) async {
    if (champion == null) {
      throw StateError('El torneo todavía no tiene campeón.');
    }

    final safeName = tournament.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    await Printing.sharePdf(
      bytes: await generatePdf(tournament, champion),
      filename: 'campeon_${safeName.isEmpty ? 'torneo' : safeName}.pdf',
    );
  }

  static Future<Uint8List> generatePdf(
    TournamentEntity tournament,
    TournamentEntry champion,
  ) async {
    final regularFont = pw.Font.ttf(await rootBundle.load('assets/fonts/Lato-Regular.ttf'));
    final boldFont = pw.Font.ttf(await rootBundle.load('assets/fonts/Lato-Bold.ttf'));
    final document = pw.Document(theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont));
    final date = DateTime.tryParse(tournament.updatedAt)?.toLocal();
    final dateText =
        date == null
            ? ''
            : '${date.day.toString().padLeft(2, '0')}/'
                '${date.month.toString().padLeft(2, '0')}/${date.year}';

    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(18),
        build:
            (_) => pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: PdfColors.blueGrey900,
                border: pw.Border.all(color: PdfColors.amber, width: 3),
              ),
              child: pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 34, vertical: 24),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.amber300, width: 1),
                ),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  children: [
                    pw.SizedBox(
                      width: 150,
                      child: pw.Column(
                        mainAxisAlignment: pw.MainAxisAlignment.center,
                        children: [
                          pw.SvgImage(svg: _trophySvg, width: 94, height: 110),
                          pw.SizedBox(height: 10),
                          pw.Container(width: 76, height: 2, color: PdfColors.amber),
                          pw.SizedBox(height: 8),
                          pw.Text(
                            'PRIMER LUGAR',
                            textAlign: pw.TextAlign.center,
                            style: pw.TextStyle(
                              color: PdfColors.amber,
                              fontSize: 10,
                              letterSpacing: 1.5,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    pw.SizedBox(width: 28),
                    pw.Expanded(
                      child: pw.Column(
                        mainAxisAlignment: pw.MainAxisAlignment.center,
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(
                            'RECONOCIMIENTO AL CAMPEÓN',
                            style: pw.TextStyle(
                              color: PdfColors.amber,
                              fontSize: 13,
                              letterSpacing: 2,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                          pw.SizedBox(height: 12),
                          pw.Text(
                            champion.displayName,
                            maxLines: 2,
                            style: pw.TextStyle(
                              color: PdfColors.white,
                              fontSize: 36,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                          pw.SizedBox(height: 10),
                          pw.Container(width: 150, height: 2, color: PdfColors.amber),
                          pw.SizedBox(height: 12),
                          pw.Text(
                            tournament.name,
                            maxLines: 2,
                            style: const pw.TextStyle(color: PdfColors.grey200, fontSize: 21),
                          ),
                          pw.SizedBox(height: 20),
                          pw.Text(
                            '${_formatName(tournament.format)}  ·  '
                            'A ${tournament.raceTo} PARTIDAS  ·  '
                            '${tournament.setsToPlay == 1 ? '1 SET' : 'MEJOR DE ${tournament.setsToPlay} SETS'}',
                            style: const pw.TextStyle(color: PdfColors.grey400, fontSize: 11),
                          ),
                          if (dateText.isNotEmpty) ...[
                            pw.SizedBox(height: 18),
                            pw.Text(
                              dateText,
                              style: const pw.TextStyle(color: PdfColors.grey400, fontSize: 11),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ),
    );

    return document.save();
  }

  static String _formatName(String format) => switch (format) {
    'single' => 'ELIMINACIÓN SIMPLE',
    'double' => 'DOBLE ELIMINACIÓN',
    'round_robin' || 'liga' => 'ROUND ROBIN',
    _ => format.toUpperCase(),
  };
}
