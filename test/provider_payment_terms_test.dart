import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/provider_entity.dart';
import 'package:app_integral_complete/features/purchases/domain/entities/purchase_entity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'provider terms preserve unknown values and round-trip explicit choices',
    () {
      final legacy = ProviderEntity.fromMap({'id': 1, 'name': 'Anterior'});
      expect(legacy.creditDays, isNull);
      expect(legacy.preferredPaymentMethod, isNull);
      for (final option in PurchasePaymentOption.values) {
        final provider = ProviderEntity(
          name: 'Proveedor',
          creditDays: 30,
          preferredPaymentMethod: option,
        );
        final restored = ProviderEntity.fromMap(provider.toMap());
        expect(restored.creditDays, 30);
        expect(restored.preferredPaymentMethod, option);
      }
      expect(
        ProviderEntity.fromMap({
          'name': 'Proveedor',
          'credit_days': 0,
        }).creditDays,
        0,
      );
      for (final invalid in [-1, 1.5, '30', 2147483648, true]) {
        expect(
          () => ProviderEntity.fromMap({
            'name': 'Proveedor',
            'credit_days': invalid,
          }),
          throwsFormatException,
        );
      }
      for (final invalid in ['', 'otro', 1, false]) {
        expect(
          () => ProviderEntity.fromMap({
            'name': 'Proveedor',
            'preferred_payment_method': invalid,
          }),
          throwsFormatException,
        );
      }
      expect(
        () => const ProviderEntity(name: 'Inválido', creditDays: -1).toMap(),
        throwsArgumentError,
      );
      expect(
        () =>
            const ProviderEntity(
              name: 'Inválido',
              preferredPaymentMethod: 'otro',
            ).toMap(),
        throwsArgumentError,
      );
    },
  );

  test(
    'migration 51 preserves archived providers, purchases and immutable pending payloads',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'provider_terms_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      final file = path.join(
        directory.path,
        'BaumarSolutions',
        'database',
        'integral_pos_v1.db',
      );
      await Directory(path.dirname(file)).create(recursive: true);
      ffi.sqfliteFfiInit();
      final old = await ffi.databaseFactoryFfi.openDatabase(
        file,
        options: ffi.OpenDatabaseOptions(
          version: 51,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE providers (id INTEGER PRIMARY KEY, name TEXT, is_active INTEGER)',
            );
            await db.insert('providers', {
              'id': 1,
              'name': 'Archivado',
              'is_active': 0,
            });
            await db.execute(
              'CREATE TABLE purchases (id INTEGER PRIMARY KEY, total REAL, cash_source TEXT)',
            );
            await db.insert('purchases', {
              'id': 7,
              'total': 123,
              'cash_source': 'caja',
            });
            await db.execute(
              'CREATE TABLE pending_provider_operations (id INTEGER PRIMARY KEY, payload TEXT)',
            );
            await db.insert('pending_provider_operations', {
              'id': 1,
              'payload': '{"name":"Pendiente"}',
            });
            await db.execute(
              'CREATE TABLE staff_purchase_operations (request_id TEXT PRIMARY KEY, payload TEXT, receipt TEXT)',
            );
            await db.insert('staff_purchase_operations', {
              'request_id': 'same-id',
              'payload': '{"p_cash_source":"caja"}',
            });
          },
        ),
      );
      await old.close();
      final db = await DatabaseHelper.instance.database;
      try {
        expect(await db.getVersion(), 61);
        final provider = (await db.query('providers')).single;
        expect(provider['name'], 'Archivado');
        expect(provider['is_active'], 0);
        expect(provider['credit_days'], isNull);
        expect(provider['preferred_payment_method'], isNull);
        expect((await db.query('purchases')).single, {
          'id': 7,
          'total': 123.0,
          'cash_source': 'caja',
          'payment_condition': null,
          'payment_method': null,
          'credit_days': null,
          'due_date': null,
          'paid_amount': null,
          'balance_due': null,
        });
        expect(
          (await db.query('pending_provider_operations')).single['payload'],
          '{"name":"Pendiente"}',
        );
        expect((await db.query('staff_purchase_operations')).single, {
          'request_id': 'same-id',
          'payload': '{"p_cash_source":"caja"}',
          'receipt': null,
        });
        await db.update('providers', {
          'credit_days': 30,
          'preferred_payment_method': 'credito',
        });
        for (final invalid in [-1, 1.5, 2147483648]) {
          await expectLater(
            db.update('providers', {'credit_days': invalid}),
            throwsA(isA<ffi.DatabaseException>()),
          );
        }
        await expectLater(
          db.update('providers', {'preferred_payment_method': 'otro'}),
          throwsA(isA<ffi.DatabaseException>()),
        );
      } finally {
        await db.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
