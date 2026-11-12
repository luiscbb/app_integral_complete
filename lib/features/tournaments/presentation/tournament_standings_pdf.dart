import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/storage/preferences_service.dart';
import '../domain/tournament.dart';

class TournamentStandingsPdfPage extends StatelessWidget {
  final TournamentEntity tournament;

  const TournamentStandingsPdfPage({super.key, required this.tournament});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('VISTA PREVIA · POSICIONES')),
    body: PdfPreview(
      build: (_) => TournamentStandingsPdf.generate(tournament),
      canChangeOrientation: false,
      canChangePageFormat: false,
      pdfFileName:
          'posiciones_${TournamentStandingsPdf.fileName(tournament.name)}.pdf',
    ),
  );
}

class TournamentStandingsPdf {
  static Future<Uint8List> generate(TournamentEntity tournament) async {
    final prefs = PreferencesService();
    final logo = pw.MemoryImage(await _loadLogo(prefs));
    final regularFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Lato-Regular.ttf'),
    );
    final boldFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Lato-Bold.ttf'),
    );
    final document = pw.Document(
      theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont),
    );
    final standings = TournamentStandings.calculate(
      tournament.entries,
      tournament.matches,
      stage: 'league',
      entryIds: tournament.entries.map((entry) => entry.id),
    );
    final entriesById = {
      for (final entry in tournament.entries) entry.id: entry,
    };
    final results =
        tournament.matches.where((match) => match.stage == 'league').toList()
          ..sort((left, right) {
            final roundOrder = left.round.compareTo(right.round);
            return roundOrder != 0
                ? roundOrder
                : left.matchNumber.compareTo(right.matchNumber);
          });

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(28),
        build:
            (_) => [
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Image(logo, width: 52, height: 52, fit: pw.BoxFit.contain),
                  pw.SizedBox(width: 14),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          prefs.businessName.trim().isEmpty
                              ? 'MI BILLAR'
                              : prefs.businessName.toUpperCase(),
                          style: pw.TextStyle(
                            fontSize: 12,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          tournament.name,
                          style: pw.TextStyle(
                            fontSize: 22,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          'ROUND ROBIN · ${tournament.gameType.toUpperCase()} · TABLA DE POSICIONES',
                          style: const pw.TextStyle(
                            fontSize: 10,
                            color: PdfColors.blueGrey700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  pw.Text(
                    'Generado: ${_formatDate(DateTime.now())}',
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                ],
              ),
              pw.SizedBox(height: 18),
              _table(
                headers: const [
                  'POS.',
                  'JUGADOR',
                  'PJ',
                  'PTS',
                  'V',
                  'D',
                  'JUEGOS G-E',
                  'DIF.',
                  'SETS G-E',
                ],
                rows: [
                  for (var index = 0; index < standings.length; index++)
                    [
                      '${index + 1}',
                      standings[index].entry.displayName,
                      '${standings[index].matchesPlayed}',
                      '${standings[index].points}',
                      '${standings[index].matchesWon}',
                      '${standings[index].matchesLost}',
                      '${standings[index].gamesWon}-${standings[index].gamesLost}',
                      '${standings[index].gameDifference >= 0 ? '+' : ''}${standings[index].gameDifference}',
                      '${standings[index].setsWon}-${standings[index].setsLost}',
                    ],
                ],
              ),
              pw.SizedBox(height: 22),
              pw.Text(
                'MARCADORES POR JORNADA',
                style: pw.TextStyle(
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 8),
              _table(
                headers: const [
                  'JORNADA',
                  'JUGADOR 1',
                  'MARCADOR',
                  'JUGADOR 2',
                  'JUEGOS POR SET',
                ],
                rows: [
                  for (final match in results)
                    [
                      '${match.round}',
                      entriesById[match.player1Id]?.displayName ?? '—',
                      '${match.sets1}-${match.sets2}',
                      entriesById[match.player2Id]?.displayName ?? '—',
                      _gamesBySet(match),
                    ],
                ],
              ),
              pw.SizedBox(height: 10),
              pw.Text(
                'Puntuación: 3 puntos por victoria. Desempates: diferencia de juegos, enfrentamiento directo y diferencia de sets.',
                style: const pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.blueGrey700,
                ),
              ),
            ],
      ),
    );
    return document.save();
  }

  static pw.Widget _table({
    required List<String> headers,
    required List<List<String>> rows,
  }) => pw.Table(
    border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
    children: [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
        children: [
          for (final header in headers)
            _cell(
              header,
              bold: true,
              color: PdfColors.white,
              background: PdfColors.blueGrey800,
            ),
        ],
      ),
      for (final row in rows)
        pw.TableRow(children: [for (final value in row) _cell(value)]),
    ],
  );

  static pw.Widget _cell(
    String value, {
    bool bold = false,
    PdfColor color = PdfColors.black,
    PdfColor? background,
  }) => pw.Container(
    color: background,
    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
    child: pw.Text(
      value,
      style: pw.TextStyle(
        fontSize: 8,
        color: color,
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    ),
  );

  static String _gamesBySet(TournamentMatch match) {
    final setNumbers =
        match.points.map((point) => point.setNumber).toSet().toList()..sort();
    return setNumbers
        .map((setNumber) {
          final firstScore =
              match.points
                  .where(
                    (point) =>
                        point.setNumber == setNumber &&
                        point.entryId == match.player1Id,
                  )
                  .length;
          final secondScore =
              match.points
                  .where(
                    (point) =>
                        point.setNumber == setNumber &&
                        point.entryId == match.player2Id,
                  )
                  .length;
          return '$firstScore-$secondScore';
        })
        .join(', ');
  }

  static Future<Uint8List> _loadLogo(PreferencesService prefs) async {
    if (prefs.logoUrl.isNotEmpty) {
      final client = HttpClient();
      try {
        final request = await client
            .getUrl(Uri.parse(prefs.logoUrl))
            .timeout(const Duration(seconds: 15));
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException(
            'No se pudo cargar el logo del billar (HTTP ${response.statusCode}).',
          );
        }
        final bytes = await response.fold<List<int>>(
          <int>[],
          (buffer, chunk) => buffer..addAll(chunk),
        );
        return Uint8List.fromList(bytes);
      } finally {
        client.close(force: true);
      }
    }

    if (prefs.logoPath.isNotEmpty) {
      final file = File(prefs.logoPath);
      if (await file.exists()) return file.readAsBytes();
    }
    final asset = await rootBundle.load('assets/app_logo.png');
    final bytes = asset.buffer.asUint8List();
    if (bytes.isEmpty) {
      debugPrint('[TournamentStandingsPdf] No se encontró un logo disponible.');
    }
    return Uint8List.fromList(bytes);
  }

  static String _formatDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';

  static String fileName(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
}
