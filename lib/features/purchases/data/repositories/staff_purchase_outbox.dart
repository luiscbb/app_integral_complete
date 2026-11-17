import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../../../core/services/sync_session.dart';
import '../../domain/entities/staff_purchase.dart';
import '../../domain/entities/staff_operation_rejection.dart';

class PendingStaffPurchase {
  const PendingStaffPurchase(this.draft, this.receipt, [this.rejection]);

  final StaffPurchaseDraft draft;
  final StaffPurchaseReceipt? receipt;
  final StaffOperationRejection? rejection;
}

class StaffPurchaseOutbox {
  const StaffPurchaseOutbox(this.database, this.requireSession);

  final Database database;
  final void Function(SyncSession) requireSession;

  PendingStaffPurchase _read(SyncSession session, Map<String, Object?> row) {
    if (row['actor_id'] != session.actorId ||
        row['billar_id'] != session.billarId) {
      throw StateError(
        'La compra guardada no pertenece a esta cuenta y billar.',
      );
    }
    final requestId = row['request_id'];
    final payload = row['payload'];
    final receipt = row['receipt'];
    if (requestId is! String ||
        payload is! String ||
        receipt != null && receipt is! String) {
      throw const FormatException('La compra guardada no es válida.');
    }
    final draft = StaffPurchaseDraft.restore(requestId, payload);
    final response = receipt == null ? null : jsonDecode(receipt as String);
    if (StaffOperationRejection.isResponse(response)) {
      return PendingStaffPurchase(
        draft,
        null,
        StaffOperationRejection.validate(
          response,
          kind: 'purchase',
          requestId: draft.requestId,
          actorId: session.actorId,
          billarId: session.billarId,
          parameters: draft.parameters,
        ),
      );
    }
    return PendingStaffPurchase(
      draft,
      receipt == null
          ? null
          : StaffPurchaseReceipt.validate(
            response,
            draft: draft,
            actorId: session.actorId,
            billarId: session.billarId,
          ),
    );
  }

  Future<PendingStaffPurchase?> pending(SyncSession session) async {
    requireSession(session);
    final rows = await database.query(
      'staff_purchase_operations',
      where: 'actor_id = ? AND billar_id = ? AND receipt IS NULL',
      whereArgs: [session.actorId, session.billarId],
      limit: 1,
    );
    requireSession(session);
    return rows.isEmpty ? null : _read(session, rows.single);
  }

  Future<PendingStaffPurchase> prepare(
    SyncSession session,
    StaffPurchaseDraft draft,
  ) => database.transaction((txn) async {
    requireSession(session);
    final same = await txn.query(
      'staff_purchase_operations',
      where: 'request_id = ?',
      whereArgs: [draft.requestId],
      limit: 1,
    );
    requireSession(session);
    if (same.isNotEmpty) {
      final saved = _read(session, same.single);
      if (saved.draft.encodedPayload != draft.encodedPayload) {
        throw StateError('La solicitud de compra cambió.');
      }
      return saved;
    }
    final pending = await txn.query(
      'staff_purchase_operations',
      where: 'actor_id = ? AND billar_id = ? AND receipt IS NULL',
      whereArgs: [session.actorId, session.billarId],
      limit: 1,
    );
    requireSession(session);
    if (pending.isNotEmpty) {
      final saved = _read(session, pending.single);
      if (saved.draft.encodedPayload != draft.encodedPayload) {
        throw StateError(
          'Recupera la compra pendiente antes de registrar otra.',
        );
      }
      return saved;
    }
    await txn.insert('staff_purchase_operations', {
      'request_id': draft.requestId,
      'actor_id': session.actorId,
      'billar_id': session.billarId,
      'payload': draft.encodedPayload,
    });
    requireSession(session);
    return PendingStaffPurchase(draft, null);
  });

  Future<StaffPurchaseReceipt> complete(
    SyncSession session,
    PendingStaffPurchase request,
    Object? response,
  ) async {
    final completed = await database.transaction((txn) async {
      requireSession(session);
      final rows = await txn.query(
        'staff_purchase_operations',
        where: 'request_id = ?',
        whereArgs: [request.draft.requestId],
        limit: 1,
      );
      requireSession(session);
      if (rows.length != 1) {
        throw StateError('La compra pendiente ya no está disponible.');
      }
      final saved = _read(session, rows.single);
      if (saved.draft.encodedPayload != request.draft.encodedPayload) {
        throw StateError('La compra pendiente cambió durante la operación.');
      }
      final result = _read(session, {
        ...rows.single,
        'receipt': jsonEncode(response),
      });
      final encoded = result.receipt?.encoded ?? result.rejection!.encoded;
      final previous = saved.receipt?.encoded ?? saved.rejection?.encoded;
      if (previous != null && previous != encoded) {
        throw StateError(
          'El comprobante de compra cambió durante la operación.',
        );
      }
      final updated = await txn.update(
        'staff_purchase_operations',
        {'receipt': encoded},
        where: 'request_id = ? AND actor_id = ? AND billar_id = ?',
        whereArgs: [saved.draft.requestId, session.actorId, session.billarId],
      );
      if (updated != 1) throw StateError('No se pudo confirmar la solicitud.');
      requireSession(session);
      return result;
    });
    // Throw only after the terminal response is committed locally.
    if (completed.rejection != null) throw completed.rejection!;
    return completed.receipt!;
  }
}
