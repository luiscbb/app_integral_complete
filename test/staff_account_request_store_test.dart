import 'dart:io';

import 'package:app_integral_complete/core/database/database_helper.dart';
import 'package:app_integral_complete/features/auth/data/staff_account_request_store.dart';
import 'package:app_integral_complete/features/auth/domain/staff_access.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pending requests survive reopening and remain isolated by actor and billar',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'staff_requests_',
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
      Database? db;
      try {
        db = await DatabaseHelper.instance.database;
        final store = StaffAccountRequestStore(openDatabase: () async => db!);
        StaffAccountDraft draft({String name = 'Ana', bool reverse = false}) =>
            StaffAccountDraft(
              fullName: name,
              username: ' CAJERO.01 ',
              jobTitle: ' Caja ',
              modules:
                  reverse
                      ? {StaffModule.quickSale, StaffModule.inventory}
                      : {StaffModule.inventory, StaffModule.quickSale},
            );
        final attempts = await Future.wait([
          store.prepare(actorId: 'admin-a', billarId: 'A', draft: draft()),
          store.prepare(
            actorId: 'admin-a',
            billarId: 'A',
            draft: draft(reverse: true),
          ),
        ]);
        expect(attempts[0].requestId, attempts[1].requestId);
        expect(
          attempts[0].requestId,
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
        expect(attempts[0].draft.modules.map((m) => m.id).toList(), [
          'inventory',
          'quick_sale',
        ]);
        await expectLater(
          store.prepare(
            actorId: 'admin-a',
            billarId: 'A',
            draft: draft(name: 'Otra'),
          ),
          throwsStateError,
        );
        final otherActor = await store.prepare(
          actorId: 'admin-b',
          billarId: 'A',
          draft: draft(),
        );
        final otherBillar = await store.prepare(
          actorId: 'admin-a',
          billarId: 'B',
          draft: draft(),
        );
        expect(
          {
            attempts[0].requestId,
            otherActor.requestId,
            otherBillar.requestId,
          }.length,
          3,
        );
        await expectLater(
          store.acknowledge(
            actorId: 'admin-b',
            billarId: 'A',
            requestId: attempts[0].requestId,
          ),
          throwsStateError,
        );
        await db.close();
        db = await ffi.databaseFactoryFfi.openDatabase(dbPath);
        final restarted = StaffAccountRequestStore(
          openDatabase: () async => db!,
        );
        final pending = await restarted.pending(
          actorId: 'admin-a',
          billarId: 'A',
        );
        expect(pending.single.requestId, attempts[0].requestId);
        expect(pending.single.draft.fullName, 'Ana');
        expect(pending.single.draft.username, 'cajero.01');
        expect(pending.single.draft.modules, {
          StaffModule.inventory,
          StaffModule.quickSale,
        });
        expect(
          (await restarted.prepare(
            actorId: 'admin-a',
            billarId: 'A',
            draft: draft(),
          )).requestId,
          attempts[0].requestId,
        );
        await restarted.acknowledge(
          actorId: 'admin-a',
          billarId: 'A',
          requestId: attempts[0].requestId,
        );
        expect(
          await restarted.pending(actorId: 'admin-a', billarId: 'A'),
          isEmpty,
        );
        expect(
          await restarted.pending(actorId: 'admin-b', billarId: 'A'),
          hasLength(1),
        );
      } finally {
        if (db?.isOpen == true) await db!.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}
