import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/staff_access.dart';
import 'staff_account_request_store.dart';
import 'staff_role_template_repository.dart';

class StaffAccountCreationResult {
  const StaffAccountCreationResult._({
    required this.requestId,
    required this.username,
    required this.temporaryPassword,
    required ({String actorId, String billarId, String token}) session,
  }) : _session = session;

  final String requestId;
  final String username;
  final String? temporaryPassword;
  final ({String actorId, String billarId, String token}) _session;
}

class StaffAccountCreationRepository {
  StaffAccountCreationRepository({
    required SupabaseClient client,
    required StaffAccountRequestStore requests,
    required String Function() currentBillarId,
  }) : _client = client,
       _requests = requests,
       _currentBillarId = currentBillarId;

  final SupabaseClient _client;
  final StaffAccountRequestStore _requests;
  final String Function() _currentBillarId;

  Stream<AuthState> get authChanges => _client.auth.onAuthStateChange;

  ({String actorId, String billarId, String token}) _session() {
    final session = _client.auth.currentSession;
    final billarId = _currentBillarId();
    if (session == null ||
        session.user.id.isEmpty ||
        session.accessToken.isEmpty ||
        billarId.trim().isEmpty) {
      throw StateError('Se requiere una sesión activa y un billar válido.');
    }
    return (
      actorId: session.user.id,
      billarId: billarId,
      token: session.accessToken,
    );
  }

  void _requireSameSession(
    ({String actorId, String billarId, String token}) expected,
  ) {
    if (!_sameSession(expected)) {
      throw StateError(
        'La sesión o el billar cambió. Vuelve a iniciar la solicitud.',
      );
    }
  }

  bool _sameSession(
    ({String actorId, String billarId, String token}) expected,
  ) {
    final session = _client.auth.currentSession;
    return session != null &&
        session.user.id == expected.actorId &&
        session.accessToken == expected.token &&
        _currentBillarId() == expected.billarId;
  }

  bool isResultSessionCurrent(StaffAccountCreationResult result) =>
      _sameSession(result._session);

  bool Function() guardCurrentSession() {
    final session = _session();
    return () => _sameSession(session);
  }

  StaffRoleTemplateStore roleTemplatesForCurrentSession() {
    final session = _session();
    return StaffRoleTemplateRepository(
      client: _client,
      billarId: session.billarId,
      token: session.token,
      sessionUnchanged: () => _sameSession(session),
    );
  }

  Future<List<StaffAccount>> listStaff() async {
    final session = _session();
    final data = await _invoke(session, {'action': 'list_staff'});
    if (data is! Map || data['staff'] is! List) {
      throw StateError('La respuesta de personal no es válida.');
    }
    final accounts = <StaffAccount>[];
    final ids = <String>{};
    for (final row in data['staff'] as List) {
      if (row is! Map) {
        throw StateError('La respuesta de personal no es válida.');
      }
      final account = StaffAccount.fromMap(row);
      if (account.billarId != session.billarId || !ids.add(account.userId)) {
        throw StateError('La respuesta de personal no corresponde al billar.');
      }
      accounts.add(account);
    }
    return accounts;
  }

  Future<StaffAccount> updateStaff({
    required StaffAccount account,
    required StaffAccountDraft draft,
    required bool isActive,
  }) async {
    final session = _session();
    if (account.billarId != session.billarId ||
        account.draft.username != draft.username) {
      throw StateError('La cuenta no corresponde a esta solicitud.');
    }
    final data = await _invoke(session, {
      'action': 'update_staff',
      'user_id': account.userId,
      'full_name': draft.fullName.trim(),
      'job_title': draft.jobTitle.trim(),
      'modules': draft.modules.map((module) => module.id).toList()..sort(),
      'is_active': isActive,
      'staff_revision': account.revision,
    });
    if (data is! Map || data['staff'] is! Map) {
      throw StateError('La respuesta de actualización no es válida.');
    }
    final updated = StaffAccount.fromMap(data['staff'] as Map);
    if (updated.userId != account.userId ||
        updated.billarId != session.billarId ||
        updated.draft.username != account.draft.username ||
        updated.draft.fullName != draft.fullName.trim() ||
        updated.draft.jobTitle != draft.jobTitle.trim() ||
        !setEquals(updated.draft.modules, draft.modules) ||
        updated.isActive != isActive) {
      throw StateError('La respuesta no coincide con los cambios solicitados.');
    }
    return updated;
  }

  Future<StaffAccountCreationResult> create(StaffAccountDraft draft) async {
    final session = _session();
    final request = await _requests.prepare(
      actorId: session.actorId,
      billarId: session.billarId,
      draft: draft,
    );
    _requireSameSession(session);
    return _submit(session, request);
  }

  Future<List<PendingStaffAccountRequest>> pending() async {
    final session = _session();
    final requests = await _requests.pending(
      actorId: session.actorId,
      billarId: session.billarId,
    );
    _requireSameSession(session);
    return requests;
  }

  Future<StaffAccountCreationResult> retry(String requestId) async {
    final session = _session();
    final requests = await _requests.pending(
      actorId: session.actorId,
      billarId: session.billarId,
    );
    _requireSameSession(session);
    final matches = requests.where((request) => request.requestId == requestId);
    if (matches.length != 1) {
      throw StateError('La solicitud pendiente no pertenece a esta sesión.');
    }
    return _submit(session, matches.single);
  }

  Future<void> acknowledge(StaffAccountCreationResult result) async {
    final session = result._session;
    _requireSameSession(session);
    await _requests.acknowledge(
      actorId: session.actorId,
      billarId: session.billarId,
      requestId: result.requestId,
    );
  }

  Future<StaffAccountCreationResult> _submit(
    ({String actorId, String billarId, String token}) session,
    PendingStaffAccountRequest request,
  ) async {
    final data = await _invoke(session, {
      'action': 'create_staff',
      'request_id': request.requestId,
      'username': request.draft.username,
      'full_name': request.draft.fullName,
      'job_title': request.draft.jobTitle,
      'modules': request.draft.modules.map((module) => module.id).toList(),
    });
    if (data is! Map ||
        data['staff'] is! Map ||
        data['password_available'] is! bool) {
      throw StateError(
        'La respuesta del servidor no es válida. Reintenta la misma solicitud.',
      );
    }
    final staff = data['staff'] as Map;
    final available = data['password_available'] as bool;
    final password = data['temporary_password'];
    if (staff['username'] != request.draft.username ||
        staff['billar_id'] != session.billarId ||
        staff['user_id'] is! String ||
        (staff['user_id'] as String).isEmpty ||
        (available && (password is! String || password.isEmpty)) ||
        (!available && data.containsKey('temporary_password'))) {
      throw StateError(
        'La respuesta del servidor no coincide con la solicitud.',
      );
    }
    return StaffAccountCreationResult._(
      requestId: request.requestId,
      username: request.draft.username,
      temporaryPassword: available ? password as String : null,
      session: session,
    );
  }

  Future<Object?> _invoke(
    ({String actorId, String billarId, String token}) session,
    Map<String, Object> body,
  ) async {
    _requireSameSession(session);
    final FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        'player-admin',
        headers: {'Authorization': 'Bearer ${session.token}'},
        body: {...body, 'billar_id': session.billarId},
      );
    } on FunctionException catch (error) {
      _requireSameSession(session);
      final details = error.details;
      final message =
          details is Map && details['error'] is String
              ? details['error'] as String
              : 'No se pudo completar la operación. Inténtalo nuevamente.';
      throw StateError(message);
    } on Exception catch (error) {
      debugPrint(
        '[StaffAccountManagement] Solicitud no confirmada: ${error.runtimeType}',
      );
      _requireSameSession(session);
      throw StateError(
        'No se pudo confirmar la operación. Reintenta la misma solicitud.',
      );
    }
    _requireSameSession(session);
    if (response.status < 200 || response.status >= 300) {
      throw StateError(
        'La respuesta del servidor no es válida. Reintenta la misma solicitud.',
      );
    }
    return response.data;
  }
}
