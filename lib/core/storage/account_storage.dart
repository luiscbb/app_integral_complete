import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/database_helper.dart';
import '../database/legacy_local_owner.dart';
import '../database/scoped_database.dart';
import 'preferences_service.dart';

class AccountStorage {
  static AccountStorage? _instance;

  static AccountStorage get instance {
    final instance = _instance;
    if (instance == null) {
      throw StateError('El almacenamiento por cuenta no está inicializado.');
    }
    return instance;
  }

  static void initialize(SupabaseClient client) {
    if (_instance != null) {
      throw StateError('El almacenamiento por cuenta ya está inicializado.');
    }
    final database = DatabaseHelper.instance;
    database.requireAccountScope();
    _instance = AccountStorage(
      client: client, database: database, preferences: PreferencesService(),
    );
  }

  AccountStorage({
    required SupabaseClient client,
    required DatabaseHelper database,
    required PreferencesService preferences,
  }) : _client = client,
       _database = database,
       _preferences = preferences {
    _subscription = client.auth.onAuthStateChange.listen((event) {
      if (_actorId == null) return;
      if (event.event == AuthChangeEvent.signedOut ||
          (event.event == AuthChangeEvent.signedIn &&
              !identical(event.session, _authorizedSession))) {
        _retired = true;
      } else if ((event.event == AuthChangeEvent.tokenRefreshed ||
              event.event == AuthChangeEvent.userUpdated) &&
          event.session?.user.id == _actorId &&
          identical(event.session, client.auth.currentSession)) {
        _authorizedSession = event.session;
      }
    });
  }

  final SupabaseClient _client;
  final DatabaseHelper _database;
  final PreferencesService _preferences;
  late final StreamSubscription<AuthState> _subscription;
  String? _actorId;
  String? _billarId;
  Session? _authorizedSession;
  bool _retired = false;
  bool _activating = false;

  bool get requiresRestart =>
      _retired || _actorId != null || _database.requiresRestartAfterMigration;
  bool get isActive => _actorId != null && !_retired &&
      identical(_client.auth.currentSession, _authorizedSession);
  void retire() {
    if (_actorId != null) _retired = true;
  }

  String? verifiedOwnerBillar(String actorId) =>
      _preferences.verifiedOwnerBillar(actorId);

  Future<void> activate({
    required String billarId,
    required bool migrateLegacyOwner,
    bool offline = false,
  }) async {
    final session = _client.auth.currentSession;
    if (session == null || session.user.id.isEmpty || billarId.trim().isEmpty) {
      throw StateError('Se requiere una cuenta y un billar válidos.');
    }
    if (isActive && _actorId == session.user.id && _billarId == billarId) return;
    if (_retired || _actorId != null || _activating ||
        _database.requiresRestartAfterMigration) {
      throw StateError('Cierra y vuelve a abrir la aplicación para cambiar de cuenta.');
    }
    _activating = true;
    ScopedDatabase? opened;
    var activated = false;
    bool isCurrentScope() =>
        !_retired &&
        _client.auth.currentSession?.user.id == session.user.id &&
        identical(_client.auth.currentSession, _authorizedSession ?? session) &&
        (_actorId == null || (_actorId == session.user.id && _billarId == billarId));
    void requireInitialSession() {
      if (!isCurrentScope() || !identical(_client.auth.currentSession, session)) {
        throw StateError('La sesión cambió durante la activación local.');
      }
    }

    try {
      if (offline && (migrateLegacyOwner ||
          _preferences.verifiedOwnerBillar(session.user.id) != billarId)) {
        throw StateError('La cuenta no tiene una vinculación local verificada.');
      }
      final scopedPreferences = _preferences.forScope(
        actorId: session.user.id,
        billarId: billarId,
        isCurrentScope: isCurrentScope,
      );
      final oldBillar = _preferences.legacyPreferencesSnapshot?['billar_id'];
      final hasLegacy = await _database.hasLegacyDatabase();
      if (migrateLegacyOwner && hasLegacy &&
          (oldBillar is! String || oldBillar.trim().isEmpty)) {
        throw StateError('La base anterior no tiene un billar identificable; se conservó sin modificar.');
      }
      final migrate = migrateLegacyOwner &&
          oldBillar == billarId &&
          hasLegacy;
      requireInitialSession();
      if (migrate) {
        final legacy = LegacyLocalOwner(
          openDatabase: () => _database.legacyDatabaseForMigration,
          client: _client,
          preferences: _preferences,
        );
        await legacy.bindConfirmedLegacyData(legacyBillarId: billarId);
        requireInitialSession();
        await legacy.migrateConfirmedPreferences(scopedPreferences);
        requireInitialSession();
        opened = await _database.migrateConfirmedLegacyDatabase(
          actorId: session.user.id,
          billarId: billarId,
          isCurrentScope: isCurrentScope,
        );
      } else {
        opened = await _database.openScopedDatabase(
          actorId: session.user.id,
          billarId: billarId,
          isCurrentScope: isCurrentScope,
          mustExist: offline,
        );
      }
      requireInitialSession();
      if (migrateLegacyOwner) {
        await _preferences.recordVerifiedOwner(session.user.id, billarId);
        requireInitialSession();
      }
      _actorId = session.user.id;
      _billarId = billarId;
      _authorizedSession = session;
      _database.activateAccountDatabase(opened);
      _preferences.activateScope(scopedPreferences);
      activated = true;
    } finally {
      _activating = false;
      if (!activated && opened != null) await opened.close();
    }
  }

  Future<void> dispose() => _subscription.cancel();
}
