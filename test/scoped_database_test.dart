import 'dart:async';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/core/database/scoped_database.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('databases are separated and stale transactions roll back', () async {
    final directory = await Directory.systemTemp.createTemp('scoped_db_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    final opened = <ScopedDatabase>[];
    var actor = 'A';
    var billar = 'X';
    var generation = 0;

    Future<ScopedDatabase> open(String owner, String business) async {
      final scopeGeneration = generation;
      final db = await DatabaseHelper.instance.openScopedDatabase(
        actorId: owner,
        billarId: business,
        isCurrentScope:
            () =>
                actor == owner &&
                billar == business &&
                generation == scopeGeneration,
      );
      opened.add(db);
      return db;
    }

    try {
      final ax = await open('A', 'X');
      await ax.execute('CREATE TABLE scope_test (value TEXT NOT NULL)');
      await ax.insert('scope_test', {'value': 'A-X'});
      expect((await ax.query('scope_test')).single['value'], 'A-X');
      final failedBatch =
          ax.batch()
            ..insert('scope_test', {'value': 'MUST ROLLBACK'})
            ..insert('scope_test', {'value': null});
      await expectLater(
        failedBatch.commit(),
        throwsA(isA<DatabaseException>()),
      );
      expect((await ax.query('scope_test')).single['value'], 'A-X');
      final appliedBatch =
          ax.batch()
            ..insert('scope_test', {'value': 'temporary'})
            ..delete(
              'scope_test',
              where: 'value = ?',
              whereArgs: ['temporary'],
            );
      expect(await appliedBatch.apply(), hasLength(2));
      expect((await ax.query('scope_test')).single['value'], 'A-X');
      final staleBatch =
          ax.batch()..insert('scope_test', {'value': 'WRONG SESSION'});

      final started = Completer<void>();
      final resume = Completer<void>();
      final stale = ax.transaction((txn) async {
        await txn.insert('scope_test', {'value': 'MUST ROLLBACK'});
        started.complete();
        await resume.future;
      });
      final rejected = expectLater(stale, throwsStateError);
      await started.future;
      actor = 'B';
      generation++;
      resume.complete();
      await rejected;
      await expectLater(ax.transaction((_) async {}), throwsStateError);
      await expectLater(staleBatch.commit(), throwsStateError);

      final bx = await open('B', 'X');
      await bx.transaction((txn) async {
        await txn.execute('CREATE TABLE scope_test (value TEXT NOT NULL)');
        expect(await txn.query('scope_test'), isEmpty);
        await txn.insert('scope_test', {'value': 'B-X'});
      });
      actor = 'A';
      billar = 'Y';
      generation++;
      final ay = await open('A', 'Y');
      await ay.transaction((txn) async {
        await txn.execute('CREATE TABLE scope_test (value TEXT NOT NULL)');
        expect(await txn.query('scope_test'), isEmpty);
        await txn.insert('scope_test', {'value': 'A-Y'});
      });
      billar = 'X';
      generation++;
      await expectLater(ax.transaction((_) async {}), throwsStateError);
      await ax.close();
      opened.remove(ax);
      final reopened = await open('A', 'X');
      final rows = await reopened.transaction((txn) => txn.query('scope_test'));
      expect(rows.map((row) => row['value']), ['A-X']);
      actor = 'B';
      generation++;
      final reopenedB = await open('B', 'X');
      expect((await reopenedB.query('scope_test')).single['value'], 'B-X');
    } finally {
      for (final db in opened) {
        await db.close();
      }
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    }
  });

  test('a colliding or unverified database is never opened for another scope', () async {
    final directory = await Directory.systemTemp.createTemp('scope_identity_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
    final helper = DatabaseHelper.instance;

    Future<ScopedDatabase> open(String business) => helper.openScopedDatabase(
      actorId: 'owner',
      billarId: business,
      isCurrentScope: () => true,
    );

    try {
      final original = await open('AAE');
      final path = original.path;
      await original.execute('CREATE TABLE saved_data (value TEXT NOT NULL)');
      await original.insert('saved_data', {'value': 'KEEP'});
      await original.close();

      if (Platform.isWindows) {
        await expectLater(open('AA_'), throwsStateError);
      }

      final reopened = await open('AAE');
      expect((await reopened.query('saved_data')).single['value'], 'KEEP');
      await reopened.execute('DROP TABLE local_scope_identity');
      await reopened.close();

      await expectLater(open('AAE'), throwsStateError);
      final inspection = await ffi.databaseFactoryFfi.openDatabase(
        path,
        options: ffi.OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      try {
        expect((await inspection.query('saved_data')).single['value'], 'KEEP');
      } finally {
        await inspection.close();
      }
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    }
  });
}
