import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/services/sync_service.dart';
import 'package:app_integral_complete/core/storage/preferences_service.dart';
import 'package:app_integral_complete/features/sales/data/repositories/sales_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sales persist their module independently of the displayed sale type', () async {
    final directory = await Directory.systemTemp.createTemp('sale_origin_test_');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const connectivityChannel = MethodChannel('dev.fluttercommunity.plus/connectivity_status');
    messenger.setMockMethodCallHandler(pathChannel, (call) async => directory.path);
    messenger.setMockMethodCallHandler(connectivityChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({'billar_id': 'TEST'});
    await PreferencesService().init();

    Database? db;
    try {
      db = await DatabaseHelper.instance.database;
      final repository = SalesRepository(currentActorId: () => 'admin');
      for (final origin in SaleOrigin.values) {
        await repository.saveSale(
          items: [],
          total: 0,
          paid: 0,
          paymentMethod: 'Efectivo',
          saleType: 'Nombre de mesa editable',
          origin: origin,
        );
      }

      final rows = await db.query(
        'sales_history',
        columns: ['type', 'source_module'],
        orderBy: 'id',
      );
      expect(rows.map((row) => row['type']).toSet(), {'Nombre de mesa editable'});
      expect(rows.map((row) => row['source_module']), [
        'quick_sale',
        'billiard_tables',
        'dine_in',
        'personal_account',
      ]);
    } finally {
      SyncService().dispose();
      await db?.close();
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(connectivityChannel, null);
      await directory.delete(recursive: true);
    }
  });
}
