import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/utils/uuid_v4.dart';
import '../domain/staff_access.dart';

class PendingStaffAccountRequest {
  const PendingStaffAccountRequest({
    required this.requestId,
    required this.draft,
  });

  final String requestId;
  final StaffAccountDraft draft;
}

class StaffAccountRequestStore {
  StaffAccountRequestStore({Future<Database> Function()? openDatabase})
    : _openDatabase = openDatabase ?? (() => DatabaseHelper.instance.database);

  final Future<Database> Function() _openDatabase;

  Future<PendingStaffAccountRequest> prepare({
    required String actorId,
    required String billarId,
    required StaffAccountDraft draft,
  }) async {
    if (actorId.trim().isEmpty || billarId.trim().isEmpty) {
      throw ArgumentError('Se requiere una sesión y un billar válidos.');
    }
    final username = normalizeStaffUsername(draft.username);
    final fullName = draft.fullName.trim();
    final jobTitle = draft.jobTitle.trim();
    if (!isValidStaffUsername(username) ||
        fullName.isEmpty ||
        fullName.length > 120 ||
        jobTitle.isEmpty ||
        jobTitle.length > 80 ||
        draft.modules.isEmpty) {
      throw ArgumentError('Los datos del personal no son válidos.');
    }
    final modules = draft.modules.map((module) => module.id).toList()..sort();
    final modulesJson = jsonEncode(modules);
    final canonicalModules =
        modules
            .map(
              (id) =>
                  StaffModule.values.singleWhere((module) => module.id == id),
            )
            .toSet();
    final db = await _openDatabase();
    return db.transaction((txn) async {
      final rows = await txn.query(
        'pending_staff_account_requests',
        where: 'actor_id = ? AND billar_id = ? AND username = ?',
        whereArgs: [actorId, billarId, username],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final row = rows.single;
        if (row['full_name'] != fullName ||
            row['job_title'] != jobTitle ||
            row['modules_json'] != modulesJson) {
          throw StateError(
            'Hay una solicitud pendiente con otros datos. Debe recuperarse antes de modificarlos.',
          );
        }
        return PendingStaffAccountRequest(
          requestId: row['request_id'] as String,
          draft: StaffAccountDraft(
            username: username,
            fullName: fullName,
            jobTitle: jobTitle,
            modules: canonicalModules,
          ),
        );
      }
      final requestId = newUuidV4();
      await txn.insert('pending_staff_account_requests', {
        'request_id': requestId,
        'actor_id': actorId,
        'billar_id': billarId,
        'username': username,
        'full_name': fullName,
        'job_title': jobTitle,
        'modules_json': modulesJson,
      });
      return PendingStaffAccountRequest(
        requestId: requestId,
        draft: StaffAccountDraft(
          username: username,
          fullName: fullName,
          jobTitle: jobTitle,
          modules: canonicalModules,
        ),
      );
    });
  }

  Future<List<PendingStaffAccountRequest>> pending({
    required String actorId,
    required String billarId,
  }) async {
    if (actorId.trim().isEmpty || billarId.trim().isEmpty) {
      throw ArgumentError('Se requiere una sesión y un billar válidos.');
    }
    final db = await _openDatabase();
    final rows = await db.query(
      'pending_staff_account_requests',
      where: 'actor_id = ? AND billar_id = ?',
      whereArgs: [actorId, billarId],
      orderBy: 'username',
    );
    return rows.map((row) {
      final ids =
          (jsonDecode(row['modules_json'] as String) as List).cast<String>();
      return PendingStaffAccountRequest(
        requestId: row['request_id'] as String,
        draft: StaffAccountDraft(
          username: row['username'] as String,
          fullName: row['full_name'] as String,
          jobTitle: row['job_title'] as String,
          modules:
              ids
                  .map(
                    (id) => StaffModule.values.singleWhere(
                      (module) => module.id == id,
                    ),
                  )
                  .toSet(),
        ),
      );
    }).toList();
  }

  Future<void> acknowledge({
    required String actorId,
    required String billarId,
    required String requestId,
  }) async {
    final db = await _openDatabase();
    final deleted = await db.delete(
      'pending_staff_account_requests',
      where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
      whereArgs: [requestId, actorId, billarId],
    );
    if (deleted != 1) {
      throw StateError('La solicitud pendiente no pertenece a esta sesión.');
    }
  }

}
