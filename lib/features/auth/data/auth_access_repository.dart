import 'package:supabase_flutter/supabase_flutter.dart';

import '../../players/domain/entities/player_stats.dart';

enum AccountKind { owner, manager, player, unavailable }

class AccountAccess {
  final AccountKind kind;
  final String billarId;
  final bool mustChangePassword;
  final PlayerEntity? player;

  const AccountAccess({
    required this.kind,
    this.billarId = '',
    this.mustChangePassword = false,
    this.player,
  });
}

class AuthAccessRepository {
  SupabaseClient get _client => Supabase.instance.client;

  Future<AccountAccess> resolveCurrentAccount() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      return const AccountAccess(kind: AccountKind.unavailable);
    }

    Map<String, dynamic>? playerRow;
    try {
      final row = await _client
          .from('players')
          .select()
          .eq('auth_user_id', user.id)
          .maybeSingle();
      if (row != null) playerRow = Map<String, dynamic>.from(row);
    } on PostgrestException {
      if (user.appMetadata['account_type'] == 'player') rethrow;
    }
    if (playerRow != null) {
      var player = PlayerEntity.fromCloudMap(playerRow, localId: null);
      if (player.isActive && player.isExpired) {
        final response = await _client.functions.invoke(
          'player-admin',
          body: {'action': 'expire_player_account'},
        );
        if (response.status < 200 || response.status >= 300) {
          final data = response.data;
          final message = data is Map ? data['error']?.toString() : null;
          throw StateError(message ?? 'No se pudo actualizar la vigencia del jugador.');
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
        .select('billar_id, role, is_active, must_change_password')
        .eq('user_id', user.id)
        .eq('is_active', true);
    if (requestedBillarId != null && requestedBillarId.isNotEmpty) {
      membershipsQuery = membershipsQuery.eq('billar_id', requestedBillarId);
    }
    List<dynamic> membershipRows = [];
    try {
      membershipRows = await membershipsQuery.limit(1);
    } on PostgrestException {
      if (user.appMetadata['account_type'] == 'manager') rethrow;
    }
    if (membershipRows.isNotEmpty) {
      final row = Map<String, dynamic>.from(membershipRows.first);
      return AccountAccess(
        kind: row['role'] == 'admin' ? AccountKind.owner : AccountKind.manager,
        billarId: row['billar_id']?.toString() ?? '',
        mustChangePassword: row['must_change_password'] == true,
      );
    }

    if (user.appMetadata['account_type'] == 'manager') {
      return const AccountAccess(kind: AccountKind.unavailable);
    }

    final settings = await _client
        .from('billar_settings')
        .select('billar_id')
        .eq('user_id', user.id)
        .maybeSingle();
    if (settings != null) {
      return AccountAccess(
        kind: AccountKind.owner,
        billarId: settings['billar_id']?.toString() ?? '',
      );
    }
    return const AccountAccess(kind: AccountKind.unavailable);
  }

  Future<void> finishPasswordChange(String password) async {
    final response = await _client.functions.invoke(
      'player-admin',
      body: {'action': 'finish_password_change', 'password': password},
    );
    if (response.status < 200 || response.status >= 300) {
      final data = response.data;
      final message = data is Map ? data['error']?.toString() : null;
      throw StateError(message ?? 'No se pudo actualizar la contraseña.');
    }
  }
}
