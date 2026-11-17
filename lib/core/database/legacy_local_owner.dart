import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/sync_session.dart';
import '../storage/preferences_service.dart';

/// Preparation for binding an existing shared database to its confirmed owner.
/// This does not isolate database access.
class LegacyLocalOwner {
  LegacyLocalOwner({
    required Future<Database> Function() openDatabase,
    required SupabaseClient client,
    required PreferencesService preferences,
  }) : _openDatabase = openDatabase,
       _client = client,
       _preferences = preferences,
       _guard = SyncSessionGuard(client, preferences);

  final Future<Database> Function() _openDatabase;
  final SupabaseClient _client;
  final PreferencesService _preferences;
  final SyncSessionGuard _guard;

  static const _businessTables = [
    'products',
    'sales_history',
    'players',
    'billiard_tables',
    'cash_outflows',
    'inventory_movements',
    'tournaments',
    'cashier_sessions',
    'cash_outflow_concepts',
    'categories',
    'personal_clients',
    'personal_customer_accounts',
    'pending_product_deletions',
    'pending_provider_operations',
    'pending_staff_account_requests',
    'pending_owner_transactions',
  ];

  Future<void> bindConfirmedLegacyData({required String legacyBillarId}) async {
    final session = _guard.capture();
    final savedBillarId = _preferences.legacyPreferencesSnapshot?['billar_id'];
    if (legacyBillarId.trim().isEmpty ||
        savedBillarId != legacyBillarId ||
        legacyBillarId != session.billarId) {
      throw StateError('El billar anterior no coincide con la sesión actual.');
    }

    final settings =
        await _client
            .from('billar_settings')
            .setHeader('Authorization', 'Bearer ${session.token}')
            .select('user_id, billar_id')
            .eq('user_id', session.actorId)
            .eq('billar_id', session.billarId)
            .maybeSingle();
    _guard.require(session);
    if (settings == null ||
        settings['user_id'] != session.actorId ||
        settings['billar_id'] != session.billarId) {
      throw StateError('No se pudo verificar al administrador del billar.');
    }
    final membership =
        await _client
            .from('business_memberships')
            .setHeader('Authorization', 'Bearer ${session.token}')
            .select('role, is_active, must_change_password')
            .eq('user_id', session.actorId)
            .eq('billar_id', session.billarId)
            .maybeSingle();
    _guard.require(session);
    if (membership == null ||
        membership['role'] != 'admin' ||
        membership['is_active'] != true ||
        membership['must_change_password'] != false) {
      throw StateError('Se requiere un administrador activo.');
    }

    final db = await _openDatabase();
    await db.transaction((txn) async {
      _guard.require(session);
      for (final table in _businessTables) {
        final conflicting = await txn.rawQuery(
          "SELECT 1 FROM $table WHERE billar_id IS NOT NULL "
          "AND trim(billar_id) <> '' AND billar_id <> ? LIMIT 1",
          [session.billarId],
        );
        if (conflicting.isNotEmpty) {
          throw StateError('Los datos locales contienen otro billar: $table.');
        }
        await txn.update(table, {
          'billar_id': session.billarId,
        }, where: "billar_id IS NULL OR trim(billar_id) = ''");
      }
      final conflictingPurchases = await txn.rawQuery(
        "SELECT 1 FROM purchases WHERE billar_id IS NOT NULL AND "
        "(trim(billar_id) = '' OR billar_id <> ?) LIMIT 1",
        [session.billarId],
      );
      if (conflictingPurchases.isNotEmpty) {
        throw StateError('Los datos locales contienen otro billar: purchases.');
      }
      final conflictingSales = await txn.rawQuery(
        'SELECT 1 FROM pending_sales WHERE '
        '(actor_id IS NULL AND billar_id IS NOT NULL) OR '
        '(actor_id IS NOT NULL AND billar_id IS NULL) OR '
        '(actor_id IS NOT NULL AND (actor_id <> ? OR billar_id <> ?)) LIMIT 1',
        [session.actorId, session.billarId],
      );
      if (conflictingSales.isNotEmpty) {
        throw StateError('Hay ventas rápidas de otra cuenta o billar.');
      }
      for (final table in [
        'pending_provider_operations',
        'pending_staff_account_requests',
        'pending_owner_transactions',
      ]) {
        final conflicting = await txn.query(
          table,
          columns: ['actor_id'],
          where: 'actor_id <> ?',
          whereArgs: [session.actorId],
          limit: 1,
        );
        if (conflicting.isNotEmpty) {
          throw StateError('Hay solicitudes locales de otra cuenta: $table.');
        }
      }
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS legacy_local_owner (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          actor_id TEXT NOT NULL,
          billar_id TEXT NOT NULL
        )
      ''');
      final rows = await txn.query('legacy_local_owner', limit: 1);
      if (rows.isEmpty) {
        await txn.insert('legacy_local_owner', {
          'singleton': 1,
          'actor_id': session.actorId,
          'billar_id': session.billarId,
        });
      } else if (rows.single['actor_id'] != session.actorId ||
          rows.single['billar_id'] != session.billarId) {
        throw StateError('Los datos locales ya pertenecen a otra cuenta.');
      }
      _guard.require(session);
    });
  }

  Future<void> requireBoundOwner() async {
    final session = _guard.capture();
    final db = await _openDatabase();
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      ['legacy_local_owner'],
    );
    if (tables.isEmpty) {
      throw StateError(
        'Los datos locales todavía no tienen un propietario confirmado.',
      );
    }
    final rows = await db.query('legacy_local_owner', limit: 1);
    _guard.require(session);
    if (rows.length != 1 ||
        rows.single['actor_id'] != session.actorId ||
        rows.single['billar_id'] != session.billarId) {
      throw StateError(
        'Los datos locales no pertenecen a esta cuenta y billar.',
      );
    }
  }

  Future<void> migrateConfirmedPreferences(
    PreferencesService destination,
  ) async {
    final session = _guard.capture();
    await requireBoundOwner();
    _guard.require(session);
    await destination.importVerifiedLegacySettings(
      source: _preferences,
      expectedActorId: session.actorId,
      expectedBillarId: session.billarId,
      requireOwner: () => _guard.require(session),
    );
  }
}
