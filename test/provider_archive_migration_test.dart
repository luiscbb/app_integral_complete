import 'dart:convert';
import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'version 40 preserves providers and assigns IDs to legacy deletes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'provider_migration_',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      final dbPath = path.join(
        directory.path,
        'BaumarSolutions',
        'database',
        'integral_pos_v1.db',
      );
      await Directory(path.dirname(dbPath)).create(recursive: true);
      ffi.sqfliteFfiInit();
      Database? upgraded;
      try {
        final old = await ffi.databaseFactoryFfi.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: 40,
            onCreate: (db, _) async {
              await db.execute('create table sale_details (id integer primary key)');
              await db.execute('create table pending_sales (id integer primary key)');
              await db.execute('create table purchases (id integer primary key)');
              await db.execute(
                'create table providers (id integer primary key, name text not null)',
              );
              await db.insert('providers', {'id': 1, 'name': 'Anterior'});
              await db.execute('''
              create table pending_provider_operations (
                id integer primary key, actor_id text not null, billar_id text not null,
                provider_id integer not null, operation text not null, payload text not null
              )
            ''');
              await db.insert('pending_provider_operations', {
                'id': 1,
                'actor_id': 'actor',
                'billar_id': 'A',
                'provider_id': 2,
                'operation': 'delete',
                'payload': 'null',
              });
              await db.insert('pending_provider_operations', {
                'id': 2,
                'actor_id': 'actor',
                'billar_id': 'A',
                'provider_id': 3,
                'operation': 'delete',
                'payload':
                    '{"request_id":"10000000-0000-4000-8000-000000000001"}',
              });
            },
          ),
        );
        await old.close();
        upgraded = await DatabaseHelper.instance.database;
        expect((await upgraded.query('providers')).single['is_active'], 1);
        final pending = await upgraded.query(
          'pending_provider_operations',
          orderBy: 'id',
        );
        expect(
          (jsonDecode(pending[0]['payload'] as String) as Map)['request_id'],
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
        expect(
          (jsonDecode(pending[1]['payload'] as String) as Map)['request_id'],
          '10000000-0000-4000-8000-000000000001',
        );
      } finally {
        await upgraded?.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
