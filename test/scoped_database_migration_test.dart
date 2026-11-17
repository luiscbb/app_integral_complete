import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/database/scoped_database.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'migration requires the bound owner and preserves the original',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'scope_migration_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      final helper = DatabaseHelper.instance;
      final opened = <ScopedDatabase>[];
      var currentActor = 'A';

      Future<ScopedDatabase> migrate(String actor) =>
          helper.migrateConfirmedLegacyDatabase(
            actorId: actor,
            billarId: 'X',
            isCurrentScope: () => currentActor == actor,
          );

      try {
        var legacy = await helper.database;
        final legacyPath = legacy.path;
        await legacy.insert('sales_history', {
          'billar_id': 'X',
          'total': 10,
          'paid': 10,
          'date': '2026-01-01',
          'type': 'Venta Rápida',
          'payment_method': 'Efectivo',
          'synced': 0,
        });
        await legacy.insert('purchases', {
          'total': 7,
          'date': '2026-01-01',
          'reference': 'ANTERIOR',
          'synced': 0,
        });
        await expectLater(migrate('A'), throwsStateError);
        expect(await File(legacyPath).exists(), isTrue);

        legacy = await helper.database;
        await legacy.execute('''
        CREATE TABLE legacy_local_owner (
          singleton INTEGER PRIMARY KEY,
          actor_id TEXT NOT NULL,
          billar_id TEXT NOT NULL
        )
      ''');
        await legacy.insert('legacy_local_owner', {
          'singleton': 1,
          'actor_id': 'A',
          'billar_id': 'X',
        });
        currentActor = 'B';
        await expectLater(migrate('B'), throwsStateError);
        currentActor = 'A';

        final otherConnection = await ffi.databaseFactoryFfi.openDatabase(
          legacyPath,
          options: ffi.OpenDatabaseOptions(singleInstance: false),
        );
        await otherConnection.execute('BEGIN IMMEDIATE');
        try {
          await expectLater(
            migrate('A'),
            throwsA(isA<ffi.DatabaseException>()),
          );
          expect(await File(legacyPath).exists(), isTrue);
        } finally {
          await otherConnection.execute('ROLLBACK');
          await otherConnection.close();
        }

        final conflicting = await helper.openScopedDatabase(
          actorId: 'A',
          billarId: 'X',
          isCurrentScope: () => currentActor == 'A',
        );
        final targetPath = conflicting.path;
        await conflicting.execute('CREATE TABLE other_data (value TEXT)');
        await conflicting.insert('other_data', {'value': 'KEEP'});
        await conflicting.close();
        await expectLater(migrate('A'), throwsStateError);
        final untouched = await helper.openScopedDatabase(
          actorId: 'A',
          billarId: 'X',
          isCurrentScope: () => currentActor == 'A',
        );
        expect((await untouched.query('other_data')).single['value'], 'KEEP');
        await untouched.close();
        await File(targetPath).delete();

        final migrated = await migrate('A');
        opened.add(migrated);
        expect((await migrated.query('sales_history')).single['synced'], 0);
        final purchase = (await migrated.query('purchases')).single;
        expect(purchase['reference'], 'ANTERIOR');
        expect(purchase['billar_id'], isNull);
        expect(await File(legacyPath).exists(), isTrue);
        await expectLater(helper.database, throwsStateError);

        await migrated.insert('sales_history', {
          'billar_id': 'X',
          'total': 20,
          'paid': 20,
          'date': '2026-01-02',
          'type': 'Venta Rápida',
          'payment_method': 'Efectivo',
          'synced': 0,
        });
        final retried = await migrate('A');
        opened.add(retried);
        expect(await retried.query('sales_history'), hasLength(2));
        final original = await ffi.databaseFactoryFfi.openDatabase(
          legacyPath,
          options: ffi.OpenDatabaseOptions(readOnly: true),
        );
        try {
          expect(await original.query('sales_history'), hasLength(1));
        } finally {
          await original.close();
        }
      } finally {
        for (final db in opened) {
          await db.close();
        }
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
