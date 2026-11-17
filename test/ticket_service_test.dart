import 'dart:convert';

import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/features/sales/domain/entities/sale_item_entity.dart';
import 'package:app_integral_complete/features/sales/presentation/services/ticket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final width in ['58mm', '80mm']) {
    test(
      'ticket $width reserves space for the farewell and social networks',
      () async {
        SharedPreferences.setMockInitialValues({
          'print_width': width,
          'ticket_farewell': 'Gracias por su visita',
          'business_socials': jsonEncode({
            'facebook': '@FACEBOOK',
            'instagram': '@INSTAGRAM',
            'tiktok': '#TIKTOK',
          }),
        });
        final prefs = PreferencesService();
        await prefs.init();
        final service = TicketService();
        final items = [
          SaleItemEntity(
            productName:
                'Producto con nombre largo para probar el ajuste del ticket',
            price: 87,
          ),
        ];

        final withSocials = await service.buildPdf(
          items,
          87,
          100,
          'Efectivo',
          'Cuenta personal',
          ticketNumber: 1,
        );
        final bytes = await withSocials.save();
        final withSocialsFormat = withSocials.document.page(0)!.pageFormat;

        await prefs.setSocialNetworks({});
        final withoutSocials = await service.buildPdf(
          items,
          87,
          100,
          'Efectivo',
          'Cuenta personal',
          ticketNumber: 1,
        );
        await withoutSocials.save();
        final withoutSocialsFormat = withoutSocials.document.page(0)!.pageFormat;

        expect(String.fromCharCodes(bytes.take(4)), '%PDF');
        expect(
          withSocialsFormat.width,
          closeTo((width == '58mm' ? 58 : 80) * PdfPageFormat.mm, 0.01),
        );
        expect(
          withSocialsFormat.height,
          greaterThan(withoutSocialsFormat.height),
        );
      },
    );
  }
}
