import 'package:supabase_flutter/supabase_flutter.dart';

import '../../players/domain/entities/player_stats.dart';
import '../domain/staff_access.dart';

enum AccountKind { owner, manager, player, staff, unavailable, blocked }

bool requiresManagedAccountAccess(User user) => const {
  'player',
  'manager',
  'staff',
}.contains(user.appMetadata['account_type']);

class AccountAccess {
  final AccountKind kind;
  final String billarId;
  final bool mustChangePassword;
  final PlayerEntity? player;
  final Set<StaffModule> allowedModules;
  final String username;

  const AccountAccess({
    required this.kind,
    this.billarId = '',
    this.mustChangePassword = false,
    this.player,
    this.allowedModules = const {},
    this.username = '',
  });
}

class AuthAccessRepository {
  AuthAccessRepository({
    SupabaseClient? client,
    bool enableStaffForIntegration = false,
  }) : _providedClient = client,
       _enableStaffForIntegration = enableStaffForIntegration;

  final SupabaseClient? _providedClient;
  final bool _enableStaffForIntegration;
  SupabaseClient get _client => _providedClient ?? Supabase.instance.client;

  Future<AccountAccess> resolveCurrentAccount() async {
    final session = _client.auth.currentSession;
    if (session == null) {
      return const AccountAccess(kind: AccountKind.unavailable);
    }
    final user = session.user;
    void requireSameSession() {
      final current = _client.auth.currentSession;
      if (!identical(current, session) ||
          current?.user.id != user.id ||
          current?.accessToken != session.accessToken) {
        throw StateError('La sesión cambió durante la verificación de acceso.');
      }
    }

    if (user.appMetadata['account_type'] == 'staff') {
      if (!_enableStaffForIntegration) {
        return const AccountAccess(kind: AccountKind.unavailable);
      }
      final billarId = user.appMetadata['billar_id'];
      if (billarId is! String || billarId.trim().isEmpty) {
        return const AccountAccess(kind: AccountKind.blocked);
      }
      final membership =
          await _client
              .from('business_memberships')
              .setHeader('Authorization', 'Bearer ${session.accessToken}')
              .select(
                'billar_id, role, is_active, must_change_password, username, allowed_modules',
              )
              .eq('user_id', user.id)
              .eq('billar_id', billarId)
              .maybeSingle();
      requireSameSession();
      final username = membership?['username'];
      final modules = membership?['allowed_modules'];
      final mustChange = membership?['must_change_password'];
      if (membership == null ||
          membership['billar_id'] != billarId ||
          membership['role'] != 'manager' ||
          membership['is_active'] != true ||
          mustChange is! bool ||
          username is! String ||
          !isValidStaffUsername(username) ||
          username != normalizeStaffUsername(username)) {
        return const AccountAccess(kind: AccountKind.blocked);
      }
      Set<StaffModule> allowed;
      try {
        allowed = parseStaffModules(modules);
      } on FormatException {
        return const AccountAccess(kind: AccountKind.blocked);
      }
      return AccountAccess(
        kind: AccountKind.staff,
        billarId: billarId,
        mustChangePassword: mustChange,
        allowedModules: allowed,
        username: username,
      );
    }

    Map<String, dynamic>? playerRow;
    try {
      final row =
          await _client
              .from('players')
              .setHeader('Authorization', 'Bearer ${session.accessToken}')
              .select()
              .eq('auth_user_id', user.id)
              .maybeSingle();
      requireSameSession();
      if (row != null) playerRow = Map<String, dynamic>.from(row);
    } on PostgrestException {
      requireSameSession();
      if (user.appMetadata['account_type'] == 'player') rethrow;
    }
    if (playerRow != null) {
      var player = PlayerEntity.fromCloudMap(playerRow, localId: null);
      if (player.isActive && player.isExpired) {
        final response = await _client.functions.invoke(
          'player-admin',
          headers: {'Authorization': 'Bearer ${session.accessToken}'},
          body: {'action': 'expire_player_account'},
        );
        requireSameSession();
        if (response.status < 200 || response.status >= 300) {
          final data = response.data;
          final message = data is Map ? data['error']?.toString() : null;
          throw StateError(
            message ?? 'No se pudo actualizar la vigencia del jugador.',
          );
        }
        player = player.copyWith(isActive: false);
      }
      return AccountAccess(
        kind: AccountKind.player,
        billarId: player.billarId,
        mustChangePassword: player.mustChangePassword,
        player: player,
      );
    }

    final requestedBillarId = user.appMetadata['billar_id']?.toString();
    var membershipsQuery = _client
        .from('business_memberships')
        .setHeader('Authorization', 'Bearer ${session.accessToken}')
        .select('billar_id, role, is_active, must_change_password')
        .eq('user_id', user.id)
        .eq('is_active', true);
    if (requestedBillarId != null && requestedBillarId.isNotEmpty) {
      membershipsQuery = membershipsQuery.eq('billar_id', requestedBillarId);
    }
    List<dynamic> membershipRows = [];
    var membershipsAvailable = true;
    try {
      membershipRows = await membershipsQuery;
      requireSameSession();
    } on PostgrestException catch (error) {
      requireSameSession();
      if (user.appMetadata['account_type'] == 'manager' ||
          !const {'42P01', 'PGRST205'}.contains(error.code)) {
        rethrow;
      }
      membershipsAvailable = false;
    }
    if (membershipRows.isNotEmpty) {
      final rows =
          membershipRows
              .map((row) => Map<String, dynamic>.from(row as Map))
              .toList();
      var selected = rows.first;
      if (rows.any((row) => row['role'] == 'admin')) {
        final settings =
            await _client
                .from('billar_settings')
                .setHeader('Authorization', 'Bearer ${session.accessToken}')
                .select('billar_id')
                .eq('user_id', user.id)
                .maybeSingle();
        requireSameSession();
        final matchingOwners = rows.where(
          (row) =>
              row['role'] == 'admin' &&
              settings != null &&
              settings['billar_id'] == row['billar_id'],
        );
        final managers = rows.where((row) => row['role'] == 'manager');
        if (matchingOwners.isNotEmpty) {
          selected = matchingOwners.first;
        } else if (managers.isNotEmpty) {
          selected = managers.first;
        } else {
          return const AccountAccess(kind: AccountKind.blocked);
        }
      }
      return AccountAccess(
        kind:
            selected['role'] == 'admin'
                ? AccountKind.owner
                : AccountKind.manager,
        billarId: selected['billar_id']?.toString() ?? '',
        mustChangePassword: selected['must_change_password'] == true,
      );
    }

    if (user.appMetadata['account_type'] == 'manager') {
      return const AccountAccess(kind: AccountKind.unavailable);
    }

    final settings =
        await _client
            .from('billar_settings')
            .setHeader('Authorization', 'Bearer ${session.accessToken}')
            .select('billar_id')
            .eq('user_id', user.id)
            .maybeSingle();
    requireSameSession();
    if (settings != null) {
      final billarId = settings['billar_id']?.toString() ?? '';
      if (membershipsAvailable) {
        return const AccountAccess(kind: AccountKind.blocked);
      }
      return AccountAccess(kind: AccountKind.owner, billarId: billarId);
    }
    return const AccountAccess(kind: AccountKind.unavailable);
  }

  Future<void> finishPasswordChange(String password) async {
    final session = _client.auth.currentSession;
    if (session == null) {
      throw StateError('Se requiere una sesión para cambiar la contraseña.');
    }
    if (password.length < 8) {
      throw ArgumentError('La contraseña debe tener al menos 8 caracteres.');
    }
    void requireSameSession() {
      if (!identical(_client.auth.currentSession, session)) {
        throw StateError('La sesión cambió durante el cambio de contraseña.');
      }
    }

    final staff = session.user.appMetadata['account_type'] == 'staff';
    if (staff) {
      final account = await resolveCurrentAccount();
      requireSameSession();
      if (account.kind != AccountKind.staff || !account.mustChangePassword) {
        throw StateError(
          'La cuenta no tiene un cambio de contraseña autorizado.',
        );
      }
    }
    final response = await _client.functions.invoke(
      'player-admin',
      headers: {'Authorization': 'Bearer ${session.accessToken}'},
      body: {'action': 'finish_password_change', 'password': password},
    );
    requireSameSession();
    if (response.status < 200 || response.status >= 300) {
      final data = response.data;
      final message = data is Map ? data['error']?.toString() : null;
      throw StateError(message ?? 'No se pudo actualizar la contraseña.');
    }
    if (response.data is! Map || response.data['ok'] != true) {
      throw StateError('No se pudo confirmar el cambio de contraseña.');
    }
    if (staff) {
      final account = await resolveCurrentAccount();
      requireSameSession();
      if (account.kind != AccountKind.staff ||
          account.mustChangePassword ||
          account.billarId != session.user.appMetadata['billar_id']) {
        throw StateError(
          'La contraseña pudo cambiar, pero no se pudo confirmar el acceso.',
        );
      }
    }
  }
}
