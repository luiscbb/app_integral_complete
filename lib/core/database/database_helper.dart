import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite/sqflite.dart';

import '../utils/uuid_v4.dart';
import 'scoped_database.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  static bool _ffiInitialized = false;
  bool _legacyMigrationInProgress = false;
  bool _legacyClosedForMigration = false;
  bool _requiresAccountScope = false;
  ScopedDatabase? _activeScopedDatabase;
  final Map<String, Future<void>> _scopeLocks = {};

  DatabaseHelper._init();

  bool get isAccountDatabaseAvailable =>
      !_requiresAccountScope || (_activeScopedDatabase?.isOpen ?? false);
  bool get requiresRestartAfterMigration =>
      _legacyClosedForMigration && _activeScopedDatabase == null;

  Future<Database> get database async {
    if (_requiresAccountScope) {
      final scoped = _activeScopedDatabase;
      if (scoped == null || !scoped.isOpen) {
        throw StateError('La base local de la cuenta no está disponible.');
      }
      return scoped;
    }
    return legacyDatabaseForMigration;
  }

  void requireAccountScope() {
    if (_database?.isOpen == true || _activeScopedDatabase != null) {
      throw StateError('La base local ya fue abierta.');
    }
    _database = null;
    _requiresAccountScope = true;
  }

  void activateAccountDatabase(ScopedDatabase database) {
    if (!_requiresAccountScope ||
        _activeScopedDatabase != null ||
        !database.isOpen) {
      throw StateError('No se puede activar la base de la cuenta.');
    }
    _activeScopedDatabase = database;
  }

  Future<bool> hasLegacyDatabase() async =>
      File(await _databasePath('integral_pos_v1.db')).exists();

  Future<Database> get legacyDatabaseForMigration async {
    if (_legacyMigrationInProgress ||
        _legacyClosedForMigration ||
        _activeScopedDatabase != null) {
      throw StateError(
        'La base local anterior está cerrada para la migración.',
      );
    }
    if (_database != null) return _database!;
    final db = await _initDB('integral_pos_v1.db');
    if (_legacyMigrationInProgress ||
        _legacyClosedForMigration ||
        _activeScopedDatabase != null) {
      await db.close();
      throw StateError(
        'La base local anterior está cerrada para la migración.',
      );
    }
    _database = db;
    return db;
  }

  String _scopedFileName(String actorId, String billarId) {
    if (actorId.trim().isEmpty || billarId.trim().isEmpty) {
      throw ArgumentError('La cuenta y el billar son obligatorios.');
    }
    String encode(String value) =>
        base64Url.encode(utf8.encode(value)).replaceAll('=', '');
    final fileName = 'integral_pos_${encode(actorId)}.${encode(billarId)}.db';
    if (utf8.encode(fileName).length > 200) {
      throw ArgumentError(
        'Los identificadores del ámbito local son demasiado largos.',
      );
    }
    return fileName;
  }

  Future<T> _withScopedFileLock<T>(
    String path,
    Future<T> Function() action,
  ) async {
    final previous = _scopeLocks[path];
    final completed = Completer<void>();
    _scopeLocks[path] = completed.future;
    try {
      if (previous != null) await previous;
      final lock = await File('$path.lock').open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive);
        try {
          return await action();
        } finally {
          await lock.unlock();
        }
      } finally {
        await lock.close();
      }
    } finally {
      if (identical(_scopeLocks[path], completed.future)) {
        _scopeLocks.remove(path);
      }
      completed.complete();
    }
  }

  Future<ScopedDatabase> openScopedDatabase({
    required String actorId,
    required String billarId,
    required bool Function() isCurrentScope,
    bool mustExist = false,
  }) async {
    if (!isCurrentScope()) {
      throw StateError('La cuenta o el billar de la base local cambió.');
    }
    final fileName = _scopedFileName(actorId, billarId);
    final path = await _databasePath(fileName);
    return _withScopedFileLock(path, () async {
      if (!isCurrentScope()) {
        throw StateError('La cuenta o el billar de la base local cambió.');
      }
      final exists = await File(path).exists();
      if (mustExist && !exists) {
        throw StateError('La base local verificada ya no está disponible.');
      }
      if (exists) {
        final existing = await openDatabase(
          path,
          readOnly: true,
          singleInstance: false,
        );
        try {
          await _requireScopedDatabaseOwner(existing, actorId, billarId);
        } finally {
          await existing.close();
        }
      }
      if (!isCurrentScope()) {
        throw StateError('La cuenta o el billar de la base local cambió.');
      }
      final db = await _initDB(fileName, singleInstance: false);
      try {
        await db.transaction((txn) async {
          if (!isCurrentScope()) {
            throw StateError('La cuenta o el billar de la base local cambió.');
          }
          await txn.execute('''
            CREATE TABLE IF NOT EXISTS local_scope_identity (
              singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
              actor_id TEXT NOT NULL,
              billar_id TEXT NOT NULL
            )
          ''');
          final rows = await txn.query('local_scope_identity');
          if (rows.isEmpty) {
            await txn.insert('local_scope_identity', {
              'singleton': 1,
              'actor_id': actorId,
              'billar_id': billarId,
            });
          } else if (rows.length != 1 ||
              rows.single['singleton'] != 1 ||
              rows.single['actor_id'] != actorId ||
              rows.single['billar_id'] != billarId) {
            throw StateError('La base local pertenece a otra cuenta o billar.');
          }
          if (!isCurrentScope()) {
            throw StateError('La cuenta o el billar de la base local cambió.');
          }
        });
        if (!isCurrentScope()) {
          throw StateError('La cuenta o el billar de la base local cambió.');
        }
        return ScopedDatabase(database: db, isCurrentScope: isCurrentScope);
      } catch (_) {
        await db.close();
        rethrow;
      }
    });
  }

  Future<void> _requireScopedDatabaseOwner(
    Database db,
    String actorId,
    String billarId,
  ) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      ['local_scope_identity'],
    );
    if (tables.isEmpty) {
      await _requireDatabaseOwner(db, actorId, billarId);
      return;
    }
    final rows = await db.query('local_scope_identity');
    if (rows.length != 1 ||
        rows.single['singleton'] != 1 ||
        rows.single['actor_id'] != actorId ||
        rows.single['billar_id'] != billarId) {
      throw StateError('La base local pertenece a otra cuenta o billar.');
    }
  }

  Future<ScopedDatabase> migrateConfirmedLegacyDatabase({
    required String actorId,
    required String billarId,
    required bool Function() isCurrentScope,
  }) async {
    final fileName = _scopedFileName(actorId, billarId);
    void requireScope() {
      if (!isCurrentScope()) {
        throw StateError('La cuenta o el billar cambió durante la migración.');
      }
    }

    requireScope();
    if (_legacyMigrationInProgress) {
      throw StateError('Ya hay una migración local en curso.');
    }
    _legacyMigrationInProgress = true;
    try {
      final legacyPath = await _databasePath('integral_pos_v1.db');
      final targetPath = await _databasePath(fileName);
      requireScope();
      if (!await File(legacyPath).exists()) {
        throw StateError('No existe una base local anterior para migrar.');
      }
      final previous = _database;
      _database = null;
      if (previous?.isOpen == true) await previous!.close();
      requireScope();

      final legacy = await _initDB('integral_pos_v1.db', singleInstance: false);
      try {
        final locking = await legacy.rawQuery('PRAGMA locking_mode=EXCLUSIVE');
        if (locking.length != 1 ||
            locking.single.values.single != 'exclusive') {
          throw StateError('No se pudo bloquear la base local anterior.');
        }
        await legacy.execute('BEGIN EXCLUSIVE');
        await legacy.execute('COMMIT');
        await _requireDatabaseOwner(legacy, actorId, billarId);
        requireScope();
        final checkpoint = await legacy.rawQuery('PRAGMA wal_checkpoint(FULL)');
        if (checkpoint.length != 1 || checkpoint.single['busy'] != 0) {
          throw StateError(
            'No se pudieron consolidar los datos locales anteriores.',
          );
        }
        requireScope();
        await _withScopedFileLock(targetPath, () async {
          requireScope();
          final target = File(targetPath);
          if (await target.exists()) {
            await _validateLegacyCopy(targetPath, actorId, billarId);
          } else {
            final temporary = File('$targetPath.migrating.${newUuidV4()}');
            try {
              await File(legacyPath).copy(temporary.path);
              requireScope();
              await _validateLegacyCopy(temporary.path, actorId, billarId);
              requireScope();
              await temporary.rename(targetPath);
            } finally {
              if (await temporary.exists()) await temporary.delete();
            }
          }
          _legacyClosedForMigration = true;
          requireScope();
        });
      } finally {
        await legacy.close();
      }
      requireScope();
      return await openScopedDatabase(
        actorId: actorId,
        billarId: billarId,
        isCurrentScope: isCurrentScope,
      );
    } finally {
      _legacyMigrationInProgress = false;
    }
  }

  Future<void> _requireDatabaseOwner(
    Database db,
    String actorId,
    String billarId,
  ) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      ['legacy_local_owner'],
    );
    if (tables.isEmpty) {
      throw StateError(
        'La base local anterior no tiene propietario confirmado.',
      );
    }
    final rows = await db.query('legacy_local_owner', limit: 1);
    if (rows.length != 1 ||
        rows.single['actor_id'] != actorId ||
        rows.single['billar_id'] != billarId) {
      throw StateError(
        'La base local anterior pertenece a otra cuenta o billar.',
      );
    }
  }

  Future<void> _validateLegacyCopy(
    String path,
    String actorId,
    String billarId,
  ) async {
    final db = await openDatabase(path, readOnly: true, singleInstance: false);
    try {
      await _requireDatabaseOwner(db, actorId, billarId);
      final result = await db.rawQuery('PRAGMA quick_check');
      if (result.length != 1 || result.single.values.single != 'ok') {
        throw StateError(
          'La copia de la base local no superó la verificación.',
        );
      }
    } finally {
      await db.close();
    }
  }

  Future<String> _databasePath(String filePath) async {
    if (Platform.isWindows || Platform.isLinux) {
      if (!_ffiInitialized) {
        ffi.sqfliteFfiInit();
        databaseFactory = ffi.databaseFactoryFfi;
        _ffiInitialized = true;
      }
      final dir = await getApplicationDocumentsDirectory();
      final path = join(dir.path, 'BaumarSolutions', 'database', filePath);
      final file = File(path);
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      return path;
    }
    final dbPath = await getDatabasesPath();
    return join(dbPath, filePath);
  }

  Future<Database> _initDB(
    String filePath, {
    bool singleInstance = true,
  }) async {
    final path = await _databasePath(filePath);
    return await openDatabase(
      path,
      version: 61,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
      singleInstance: singleInstance,
    );
  }

  Future<void> _upgradeDB(Database db, int oldV, int newV) async {
    if (oldV < 57) {
      await _createTableSyncConflicts(db);
    }
    if (oldV < 55) {
      await _createStaffTableServiceDrafts(db);
    }
    if (oldV < 56 &&
        !await _hasColumn(
          db,
          'staff_table_service_consumptions',
          'confirmed',
        )) {
      await db.execute(
        'ALTER TABLE staff_table_service_consumptions ADD COLUMN confirmed INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldV < 58) {
      await _createStaffTableServiceDrafts(db);
      if (!await _hasColumn(db, 'staff_table_service_consumptions', 'late')) {
        await db.execute(
          'ALTER TABLE staff_table_service_consumptions ADD COLUMN late INTEGER NOT NULL DEFAULT 0 CHECK (late IN (0, 1))',
        );
      }
    }
    if (oldV < 59) {
      await _createStaffTableCheckoutOutbox(db);
    }
    if (oldV < 60) {
      await _createStaffTableVisibilityCache(db);
    }
    if (oldV < 61) {
      await _createStaffTableLateAdjustmentOutbox(db);
    }
    if (oldV < 54) {
      await _createPendingCashRequests(db);
    }
    if (oldV < 53) {
      await _createStaffProviderOperations(db);
    }
    if (oldV < 51) {
      await _createStaffPurchaseOperations(db);
    }
    if (oldV < 50) {
      await _createStaffSaleCache(db);
    }
    if (oldV < 49) {
      await _createPendingOwnerPromos(db);
    }
    if (oldV < 48) {
      if (oldV >= 46 &&
          !await _hasColumn(
            db,
            'pending_staff_sales',
            'reservation_snapshot',
          )) {
        await db.execute(
          'ALTER TABLE pending_staff_sales ADD COLUMN reservation_snapshot TEXT',
        );
      }
      if (!await _hasColumn(db, 'sale_details', 'cost_available')) {
        await db.execute(
          'ALTER TABLE sale_details ADD COLUMN cost_available INTEGER NOT NULL DEFAULT 1',
        );
      }
    }
    if (oldV < 47) {
      await _createReconciledStaffSales(db);
    }
    if (oldV < 46) {
      await _createPendingStaffSales(db);
    }
    if (oldV < 45) {
      await _createPendingOwnerTransactions(db);
    }
    if (oldV < 43) {
      if (!await _hasColumn(db, 'pending_sales', 'billar_id')) {
        await db.execute('ALTER TABLE pending_sales ADD COLUMN billar_id TEXT');
      }
      if (!await _hasColumn(db, 'pending_sales', 'actor_id')) {
        await db.execute('ALTER TABLE pending_sales ADD COLUMN actor_id TEXT');
      }
    }
    if (oldV < 42 && !await _hasColumn(db, 'purchases', 'billar_id')) {
      await db.execute('ALTER TABLE purchases ADD COLUMN billar_id TEXT');
    }
    if (oldV < 40) {
      await _createPendingProviderOperations(db);
    }
    if (oldV < 39) {
      await _createPendingStaffRequests(db);
    }
    if (oldV < 37 && !await _hasColumn(db, 'sales_history', 'source_module')) {
      await db.execute(
        'ALTER TABLE sales_history ADD COLUMN source_module TEXT',
      );
    }
    if (oldV < 36 && !await _hasColumn(db, 'players', 'opponent_8_ball_foul')) {
      await db.execute(
        'ALTER TABLE players ADD COLUMN opponent_8_ball_foul INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldV < 26) {
      final columns = <String, String>{
        'email': "TEXT NOT NULL DEFAULT ''",
        'player_code': "TEXT NOT NULL DEFAULT ''",
        'handicap': 'INTEGER NOT NULL DEFAULT 1',
        'billar_id': "TEXT NOT NULL DEFAULT 'BILLAR_001'",
        'is_active': 'INTEGER NOT NULL DEFAULT 1',
        'registered_at': 'TEXT',
        'expires_at': 'TEXT',
        'archived_at': 'TEXT',
        'auth_user_id': 'TEXT',
        'must_change_password': 'INTEGER NOT NULL DEFAULT 0',
        'client_id': 'TEXT',
      };
      for (final entry in columns.entries) {
        if (!await _hasColumn(db, 'players', entry.key)) {
          await db.execute(
            'ALTER TABLE players ADD COLUMN ${entry.key} ${entry.value}',
          );
        }
      }
      await db.execute('''
        UPDATE players
        SET client_id = lower(hex(randomblob(16)))
        WHERE client_id IS NULL OR client_id = ''
      ''');
      await db.execute('''
        UPDATE players
        SET player_code = 'JUG-LEGACY-' || id
        WHERE player_code IS NULL OR player_code = ''
      ''');
      await db.execute('''
        UPDATE players
        SET registered_at = COALESCE(registered_at, datetime('now')),
            expires_at = COALESCE(expires_at, datetime('now', '+1 year'))
      ''');
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_players_client_id ON players(client_id)',
      );
    }
    if (oldV < 27 && !await _hasColumn(db, 'players', 'phone')) {
      await db.execute(
        "ALTER TABLE players ADD COLUMN phone TEXT NOT NULL DEFAULT ''",
      );
    }
    if (oldV < 28) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS tournaments (
          id TEXT PRIMARY KEY,
          billar_id TEXT NOT NULL,
          name TEXT NOT NULL,
          tournament_format TEXT NOT NULL,
          capacity INTEGER,
          entries_json TEXT NOT NULL DEFAULT '[]',
          race_to INTEGER NOT NULL DEFAULT 3,
          sets_to_play INTEGER NOT NULL DEFAULT 1,
          guaranteed_pool REAL NOT NULL DEFAULT 0,
          entry_fee REAL NOT NULL DEFAULT 0,
          time_fee REAL NOT NULL DEFAULT 0,
          prizes_json TEXT NOT NULL DEFAULT '[]',
          game_type TEXT NOT NULL DEFAULT 'Bola 9',
          playoff_qualifiers INTEGER NOT NULL DEFAULT 0,
          matches_json TEXT NOT NULL DEFAULT '[]',
          is_active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tournaments_billar ON tournaments(billar_id, is_active)',
      );
    }
    if (oldV < 29) {
      if (!await _hasColumn(db, 'tournaments', 'race_to')) {
        await db.execute(
          'ALTER TABLE tournaments ADD COLUMN race_to INTEGER NOT NULL DEFAULT 3',
        );
      }
      if (!await _hasColumn(db, 'tournaments', 'matches_json')) {
        await db.execute(
          "ALTER TABLE tournaments ADD COLUMN matches_json TEXT NOT NULL DEFAULT '[]'",
        );
      }
    }
    if (oldV < 30 && !await _hasColumn(db, 'tournaments', 'sets_to_play')) {
      await db.execute(
        'ALTER TABLE tournaments ADD COLUMN sets_to_play INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (oldV < 31) {
      final columns = <String, String>{
        'guaranteed_pool': 'REAL NOT NULL DEFAULT 0',
        'entry_fee': 'REAL NOT NULL DEFAULT 0',
        'time_fee': 'REAL NOT NULL DEFAULT 0',
        'prizes_json': "TEXT NOT NULL DEFAULT '[]'",
      };
      for (final entry in columns.entries) {
        if (!await _hasColumn(db, 'tournaments', entry.key)) {
          await db.execute(
            'ALTER TABLE tournaments ADD COLUMN ${entry.key} ${entry.value}',
          );
        }
      }
    }
    if (oldV < 33) {
      final columns = <String, String>{
        'game_type': "TEXT NOT NULL DEFAULT 'Bola 9'",
        'playoff_qualifiers': 'INTEGER NOT NULL DEFAULT 0',
      };
      for (final entry in columns.entries) {
        if (!await _hasColumn(db, 'tournaments', entry.key)) {
          await db.execute(
            'ALTER TABLE tournaments ADD COLUMN ${entry.key} ${entry.value}',
          );
        }
      }
    }
    if (oldV < 35) {
      if (!await _hasColumn(db, 'temp_reservations', 'source_key')) {
        await db.execute(
          "ALTER TABLE temp_reservations ADD COLUMN source_key TEXT",
        );
      }
      await db.execute('''
        CREATE TABLE IF NOT EXISTS personal_clients (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          client_id TEXT NOT NULL UNIQUE,
          billar_id TEXT NOT NULL,
          name TEXT NOT NULL,
          phone TEXT NOT NULL DEFAULT '',
          email TEXT NOT NULL DEFAULT '',
          notes TEXT NOT NULL DEFAULT '',
          is_active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS personal_customer_accounts (
          client_key TEXT PRIMARY KEY,
          billar_id TEXT NOT NULL,
          client_name TEXT NOT NULL,
          items_json TEXT NOT NULL DEFAULT '[]',
          updated_at TEXT NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0
        )
      ''');
      if (!await _hasColumn(db, 'sales_history', 'customer_key')) {
        await db.execute(
          'ALTER TABLE sales_history ADD COLUMN customer_key TEXT',
        );
      }
      if (!await _hasColumn(db, 'tournaments', 'is_cancelled')) {
        await db.execute(
          'ALTER TABLE tournaments ADD COLUMN is_cancelled INTEGER NOT NULL DEFAULT 0',
        );
      }
    }
    if (oldV < 25 && !await _hasColumn(db, 'billiard_tables', 'is_deleted')) {
      await db.execute(
        'ALTER TABLE billiard_tables ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldV < 22) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pending_product_deletions (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          billar_id  TEXT NOT NULL,
          product_id INTEGER NOT NULL,
          image_path TEXT,
          synced     INTEGER NOT NULL DEFAULT 0,
          UNIQUE (billar_id, product_id)
        )
      ''');
    }
    if (oldV < 21 && !await _hasColumn(db, 'billiard_tables', 'synced')) {
      await db.execute(
        'ALTER TABLE billiard_tables ADD COLUMN synced INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (oldV < 20) {
      await db.execute('ALTER TABLE pending_sales ADD COLUMN client_id TEXT');
    }
    if (oldV < 19) {
      // Informe de UTILIDAD (Etapa 4): costo unitario del producto al momento
      // de vender. Permite calcular "costo de lo vendido" histórico real
      // (aunque el costo del producto cambie después).
      await db.execute(
        "ALTER TABLE sale_details ADD COLUMN cost_at_sale REAL NOT NULL DEFAULT 0",
      );
    }
    if (oldV < 18) {
      // Anulación lógica de compras: marca la compra como anulada sin borrarla
      // (para que el pull de la nube no la re-inserte) y descuenta el stock
      // que la compra había sumado. 1 = anulada (excluida de informes/caja).
      await db.execute(
        "ALTER TABLE purchases ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0",
      );
      await db.execute(
        "ALTER TABLE purchase_details ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0",
      );
    }
    if (oldV < 17) {
      // Anulación lógica de ventas: permite marcar una venta como anulada
      // (con contraseña) sin borrarla, para que el pull de la nube no la
      // re-inserte. 1 = anulada (excluida de informes/caja/historial).
      await db.execute(
        "ALTER TABLE sales_history ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0",
      );
      await db.execute(
        "ALTER TABLE sale_details ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0",
      );
    }
    if (oldV < 16) {
      // Catálogo de conceptos de retiro/gasto de caja (patrón de categorías).
      await db.execute('''
        CREATE TABLE IF NOT EXISTS cash_outflow_concepts (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          billar_id TEXT    NOT NULL DEFAULT 'BILLAR_001',
          name      TEXT    NOT NULL UNIQUE
        )
      ''');
    }
    if (oldV < 15) {
      // Origen del dinero de la compra (Caja/Cajero/Transferencia/Tarjeta),
      // para el corte de efectivo por turno/cajero.
      await db.execute(
        "ALTER TABLE purchases ADD COLUMN cash_source TEXT DEFAULT 'caja'",
      );
    }
    if (oldV < 14) {
      // Usuario logueado que realizó la compra (para detalle/PDF y cortes por turno)
      await db.execute(
        "ALTER TABLE purchases ADD COLUMN created_by TEXT DEFAULT ''",
      );
      await db.execute(
        "ALTER TABLE purchase_details ADD COLUMN created_by TEXT DEFAULT ''",
      );
    }
    if (oldV < 12) {
      await db.execute(
        "ALTER TABLE products ADD COLUMN presentation TEXT DEFAULT ''",
      );
    }
    if (oldV < 11) {
      // Migrar tabla providers a nueva estructura con más campos
      await db.execute('''
        CREATE TABLE IF NOT EXISTS providers_new (
          id           INTEGER PRIMARY KEY AUTOINCREMENT,
          name         TEXT NOT NULL,
          phone        TEXT DEFAULT '',
          email        TEXT DEFAULT '',
          address      TEXT DEFAULT '',
          contact_name TEXT DEFAULT '',
          notes        TEXT DEFAULT '',
          category     TEXT DEFAULT 'General',
          visit_days   TEXT DEFAULT ''
        )
      ''');
      try {
        await db.execute('''
          INSERT INTO providers_new (id, name, phone, address, category)
          SELECT id, name, phone, address, category FROM providers
        ''');
        await db.execute('DROP TABLE providers');
        await db.execute('ALTER TABLE providers_new RENAME TO providers');
      } catch (_) {
        // Si falla, simplemente dejamos la nueva tabla
      }
      await db.execute('''
        CREATE TABLE IF NOT EXISTS provider_products (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          provider_id INTEGER NOT NULL,
          product_id  INTEGER NOT NULL,
          UNIQUE(provider_id, product_id),
          FOREIGN KEY (provider_id) REFERENCES providers (id) ON DELETE CASCADE,
          FOREIGN KEY (product_id)  REFERENCES products  (id) ON DELETE CASCADE
        )
      ''');
    }
    if (oldV < 10) {
      await db.execute(
        "ALTER TABLE billiard_tables ADD COLUMN table_type TEXT NOT NULL DEFAULT 'Pool'",
      );
    }
    if (oldV < 2) {
      await db.execute(
        'ALTER TABLE sales_history ADD COLUMN paid REAL NOT NULL DEFAULT 0',
      );
    }
    if (oldV < 3) {
      await db.execute(
        'ALTER TABLE sales_history ADD COLUMN synced INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute('ALTER TABLE sales_history ADD COLUMN cloud_id TEXT');
      await db.execute(
        'ALTER TABLE purchases ADD COLUMN synced INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute('ALTER TABLE purchases ADD COLUMN cloud_id TEXT');
    }
    if (oldV < 4) {
      await db.execute('''
        CREATE TABLE players (
          id             INTEGER PRIMARY KEY AUTOINCREMENT,
          name           TEXT    NOT NULL,
          nickname       TEXT    DEFAULT '',
          avatar         TEXT    DEFAULT '',
          email          TEXT    NOT NULL DEFAULT '',
          player_code    TEXT    NOT NULL DEFAULT '',
          handicap       INTEGER NOT NULL DEFAULT 1,
          billar_id      TEXT    NOT NULL DEFAULT 'BILLAR_001',
          is_active      INTEGER NOT NULL DEFAULT 1,
          registered_at  TEXT,
          expires_at     TEXT,
          archived_at    TEXT,
          auth_user_id   TEXT,
          must_change_password INTEGER NOT NULL DEFAULT 0,
          client_id      TEXT,
          wins           INTEGER NOT NULL DEFAULT 0,
          losses         INTEGER NOT NULL DEFAULT 0,
          draws          INTEGER NOT NULL DEFAULT 0,
          total_matches  INTEGER NOT NULL DEFAULT 0,
          total_seconds  INTEGER NOT NULL DEFAULT 0,
          break_and_run  INTEGER NOT NULL DEFAULT 0,
          golden_breaks  INTEGER NOT NULL DEFAULT 0,
          high_run       INTEGER NOT NULL DEFAULT 0,
          current_streak INTEGER NOT NULL DEFAULT 0,
          best_streak    INTEGER NOT NULL DEFAULT 0,
          created_at     TEXT    NOT NULL DEFAULT (datetime('now'))
        )
      ''');
    }
    if (oldV < 5) {
      await db.execute('''
        CREATE TABLE match_results (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          game_type   TEXT    NOT NULL DEFAULT 'Bola 8',
          player1_id  INTEGER NOT NULL,
          player2_id  INTEGER NOT NULL,
          winner_id   INTEGER,
          is_draw     INTEGER NOT NULL DEFAULT 0,
          golden_break INTEGER NOT NULL DEFAULT 0,
          break_and_run INTEGER NOT NULL DEFAULT 0,
          notes       TEXT    DEFAULT '',
          date        TEXT    NOT NULL DEFAULT (datetime('now')),
          synced      INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY (player1_id) REFERENCES players(id) ON DELETE CASCADE,
          FOREIGN KEY (player2_id) REFERENCES players(id) ON DELETE CASCADE,
          FOREIGN KEY (winner_id) REFERENCES players(id) ON DELETE SET NULL
        )
      ''');
    }
    if (oldV < 6) {
      await db.execute(
        'ALTER TABLE players ADD COLUMN synced INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute('ALTER TABLE players ADD COLUMN cloud_id TEXT');
    }
    if (oldV < 7) {
      await db.execute(
        "ALTER TABLE products ADD COLUMN category TEXT DEFAULT ''",
      );
      await db.execute('''
        CREATE TABLE IF NOT EXISTS categories (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          billar_id TEXT    NOT NULL DEFAULT 'BILLAR_001',
          name      TEXT    NOT NULL UNIQUE
        )
      ''');
    }
    if (oldV < 9) {
      await db.execute(
        'ALTER TABLE products ADD COLUMN synced INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute('ALTER TABLE products ADD COLUMN cloud_id TEXT');
    }
    if (oldV < 8) {
      await db.execute(
        'ALTER TABLE match_results ADD COLUMN player_score INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE match_results ADD COLUMN opponent_score INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE match_results ADD COLUMN accuracy REAL NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE match_results ADD COLUMN efficiency REAL NOT NULL DEFAULT 0',
      );
    }
    if (oldV < 13) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS temp_reservations (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          source      TEXT    NOT NULL,
          source_id   INTEGER NOT NULL DEFAULT 0,
          product_id  INTEGER NOT NULL,
          quantity    REAL    NOT NULL,
          created_at  TEXT    NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS inventory_movements (
          id             INTEGER PRIMARY KEY AUTOINCREMENT,
          billar_id      TEXT    NOT NULL DEFAULT 'BILLAR_001',
          product_id     INTEGER NOT NULL,
          movement_type  TEXT    NOT NULL,
          quantity       REAL    NOT NULL,
          unit_cost      REAL    NOT NULL DEFAULT 0,
          unit_price     REAL    NOT NULL DEFAULT 0,
          reference_id   INTEGER,
          reference_type TEXT,
          notes          TEXT    DEFAULT '',
          created_at     TEXT    NOT NULL DEFAULT (datetime('now')),
          synced         INTEGER NOT NULL DEFAULT 0,
          cloud_id       TEXT,
          client_id      TEXT UNIQUE
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS cash_outflows (
          id             INTEGER PRIMARY KEY AUTOINCREMENT,
          billar_id      TEXT    NOT NULL DEFAULT 'BILLAR_001',
          outflow_type   TEXT    NOT NULL,
          amount         REAL    NOT NULL,
          description    TEXT    NOT NULL DEFAULT '',
          payment_method TEXT    DEFAULT 'Efectivo',
          created_by     TEXT    DEFAULT '',
          created_at     TEXT    NOT NULL DEFAULT (datetime('now')),
          synced         INTEGER NOT NULL DEFAULT 0,
          cloud_id       TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS cashier_sessions (
          id             INTEGER PRIMARY KEY AUTOINCREMENT,
          billar_id      TEXT    NOT NULL DEFAULT 'BILLAR_001',
          opened_at      TEXT    NOT NULL DEFAULT (datetime('now')),
          closed_at      TEXT,
          opening_amount REAL    NOT NULL DEFAULT 0,
          closing_amount REAL,
          expected_amount REAL,
          difference     REAL,
          is_closed      INTEGER NOT NULL DEFAULT 0,
          partial_closures TEXT  DEFAULT '[]',
          notes          TEXT    DEFAULT '',
          created_by     TEXT    DEFAULT '',
          closed_by      TEXT    DEFAULT '',
          synced         INTEGER NOT NULL DEFAULT 0,
          cloud_id       TEXT
        )
      ''');
    }
    if (oldV < 23) {
      await db.execute(
        'ALTER TABLE inventory_movements ADD COLUMN client_id TEXT',
      );
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_inventory_movements_client_id '
        'ON inventory_movements (client_id)',
      );
      await db.execute(
        'UPDATE inventory_movements SET synced = 0 WHERE cloud_id IS NULL',
      );
    }
    if (oldV < 24) {
      await db.execute(
        'ALTER TABLE products ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1',
      );
    }
    if (oldV < 38) {
      if (!await _hasColumn(db, 'products', 'stock_revision')) {
        await db.execute(
          'ALTER TABLE products ADD COLUMN stock_revision INTEGER',
        );
      }
      if (!await _hasColumn(db, 'products', 'local_revision')) {
        await db.execute(
          'ALTER TABLE products ADD COLUMN local_revision INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!await _hasColumn(db, 'products', 'stock_conflict')) {
        await db.execute(
          'ALTER TABLE products ADD COLUMN stock_conflict INTEGER NOT NULL DEFAULT 0',
        );
      }
      await _createProductRevisionTrigger(db);
    }
    if (oldV < 41) {
      if (!await _hasColumn(db, 'providers', 'is_active')) {
        await db.execute(
          'ALTER TABLE providers ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1',
        );
      }
      final pending = await db.query(
        'pending_provider_operations',
        columns: ['id'],
        where: 'operation = ? AND payload = ?',
        whereArgs: ['delete', 'null'],
      );
      for (final row in pending) {
        await db.update(
          'pending_provider_operations',
          {
            'payload': jsonEncode({'request_id': newUuidV4()}),
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    }
    if (oldV < 44 && await _hasColumn(db, 'billiard_tables', 'id')) {
      final columns = await db.rawQuery('PRAGMA table_info(billiard_tables)');
      const expected = {
        'id',
        'billar_id',
        'name',
        'table_type',
        'is_occupied',
        'start_time',
        'orders',
        'synced',
        'is_deleted',
      };
      final actual = columns.map((column) => column['name']).toSet();
      if (actual.length != expected.length || !actual.containsAll(expected)) {
        throw StateError(
          'La estructura local de mesas requiere revisión antes de migrar.',
        );
      }
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name <> 'billiard_tables'",
      );
      for (final table in tables) {
        final name = (table['name'] as String).replaceAll('"', '""');
        final keys = await db.rawQuery('PRAGMA foreign_key_list("$name")');
        if (keys.any(
          (key) => key['table']?.toString().toLowerCase() == 'billiard_tables',
        )) {
          throw StateError(
            'Hay referencias a mesas que requieren revisión antes de migrar.',
          );
        }
      }
      final objects = await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE tbl_name = ? "
        "AND type IN ('index', 'trigger') AND sql IS NOT NULL",
        ['billiard_tables'],
      );
      await _createBilliardTables(db, 'billiard_tables_v44');
      await db.execute('''
        INSERT INTO billiard_tables_v44
          (id, billar_id, name, table_type, is_occupied, start_time, orders, synced, is_deleted)
        SELECT id, billar_id, name, table_type, is_occupied, start_time, orders, synced, is_deleted
        FROM billiard_tables
      ''');
      await db.execute('DROP TABLE billiard_tables');
      await db.execute(
        'ALTER TABLE billiard_tables_v44 RENAME TO billiard_tables',
      );
      for (final object in objects) {
        await db.execute(object['sql'] as String);
      }
    }
    if (oldV < 52) {
      await _addProviderPaymentTerms(db);
      await _addPurchasePaymentTerms(db);
    }
  }

  Future<void> _addPurchasePaymentTerms(Database db) async {
    const columns = {
      'payment_condition': 'TEXT',
      'payment_method': 'TEXT',
      'credit_days': 'INTEGER',
      'due_date': 'TEXT',
      'paid_amount': 'REAL',
      'balance_due': 'REAL',
    };
    for (final entry in columns.entries) {
      if (!await _hasColumn(db, 'purchases', entry.key)) {
        await db.execute(
          'ALTER TABLE purchases ADD COLUMN ${entry.key} ${entry.value}',
        );
      }
    }
  }

  Future<void> _addProviderPaymentTerms(Database db) async {
    if (!await _hasColumn(db, 'providers', 'credit_days')) {
      await db.execute(
        'ALTER TABLE providers ADD COLUMN credit_days INTEGER '
        "CHECK (credit_days IS NULL OR (typeof(credit_days) = 'integer' "
        'AND credit_days >= 0 AND credit_days <= 2147483647))',
      );
    }
    if (!await _hasColumn(db, 'providers', 'preferred_payment_method')) {
      await db.execute(
        'ALTER TABLE providers ADD COLUMN preferred_payment_method TEXT '
        "CHECK (preferred_payment_method IN ('efectivo', 'tarjeta', 'transferencia', 'credito'))",
      );
    }
  }

  Future<void> _createBilliardTables(Database db, String tableName) async {
    await db.execute('''
      CREATE TABLE $tableName (
        id          INTEGER NOT NULL,
        billar_id   TEXT    NOT NULL DEFAULT 'BILLAR_001',
        name        TEXT    NOT NULL,
        table_type  TEXT    NOT NULL DEFAULT 'Pool',
        is_occupied INTEGER NOT NULL DEFAULT 0,
        start_time  TEXT,
        orders      TEXT    DEFAULT '[]',
        synced      INTEGER NOT NULL DEFAULT 1,
        is_deleted  INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (billar_id, id)
      )
    ''');
  }

  Future<bool> _hasColumn(
    Database db,
    String tableName,
    String columnName,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($tableName)');
    return columns.any((column) => column['name'] == columnName);
  }

  Future<void> _createProductRevisionTrigger(Database db) async {
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS product_local_revision
      AFTER UPDATE OF barcode, name, description, price, cost, stock,
        image_path, is_promo, parent_id, pieces_per_unit, category,
        presentation, is_active ON products
      WHEN NEW.synced = 0 AND (
        NEW.barcode IS NOT OLD.barcode OR NEW.name IS NOT OLD.name OR
        NEW.description IS NOT OLD.description OR NEW.price IS NOT OLD.price OR
        NEW.cost IS NOT OLD.cost OR NEW.stock IS NOT OLD.stock OR
        NEW.image_path IS NOT OLD.image_path OR NEW.is_promo IS NOT OLD.is_promo OR
        NEW.parent_id IS NOT OLD.parent_id OR NEW.pieces_per_unit IS NOT OLD.pieces_per_unit OR
        NEW.category IS NOT OLD.category OR NEW.presentation IS NOT OLD.presentation OR
        NEW.is_active IS NOT OLD.is_active
      )
      BEGIN
        UPDATE products SET local_revision = local_revision + 1 WHERE id = NEW.id;
      END
    ''');
  }

  Future<void> _createPendingStaffRequests(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_staff_account_requests (
        request_id TEXT PRIMARY KEY,
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        username TEXT NOT NULL,
        full_name TEXT NOT NULL,
        job_title TEXT NOT NULL,
        modules_json TEXT NOT NULL,
        UNIQUE (actor_id, billar_id, username)
      )
    ''');
  }

  Future<void> _createPendingOwnerTransactions(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_owner_transactions (
        kind TEXT NOT NULL CHECK (kind IN ('sale', 'purchase')),
        local_id INTEGER NOT NULL,
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        request_id TEXT NOT NULL UNIQUE,
        payload TEXT NOT NULL,
        PRIMARY KEY (kind, local_id)
      )
    ''');
  }

  Future<void> _createStaffProviderOperations(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS staff_provider_operations (
        request_id TEXT PRIMARY KEY,
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        receipt TEXT
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_provider_pending
      ON staff_provider_operations (actor_id, billar_id) WHERE receipt IS NULL
    ''');
  }

  Future<void> _createStaffPurchaseOperations(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS staff_purchase_operations (
        request_id TEXT PRIMARY KEY,
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        receipt TEXT
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_purchase_pending
      ON staff_purchase_operations (actor_id, billar_id) WHERE receipt IS NULL
    ''');
  }

  Future<void> _createStaffSaleCache(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS staff_sale_catalog (
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        product_id INTEGER NOT NULL,
        product_json TEXT NOT NULL,
        stock REAL NOT NULL,
        stock_revision INTEGER NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (actor_id, billar_id, product_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS staff_sale_cart (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        product_id INTEGER NOT NULL,
        quantity INTEGER NOT NULL CHECK (quantity > 0),
        UNIQUE (actor_id, billar_id, product_id)
      )
    ''');
  }

  Future<void> _createPendingStaffSales(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_staff_sales (
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        request_id TEXT NOT NULL UNIQUE,
        payload TEXT NOT NULL,
        reservation_snapshot TEXT,
        remote_sale_id INTEGER,
        PRIMARY KEY (actor_id, billar_id)
      )
    ''');
  }

  Future<void> _createReconciledStaffSales(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS reconciled_staff_sales (
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        request_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        remote_sale_id INTEGER NOT NULL,
        local_sale_id INTEGER NOT NULL,
        PRIMARY KEY (actor_id, billar_id, request_id),
        UNIQUE (billar_id, remote_sale_id)
      )
    ''');
  }

  Future<void> _createPendingOwnerPromos(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_owner_promos (
        product_id INTEGER PRIMARY KEY,
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        is_new INTEGER NOT NULL CHECK (is_new IN (0, 1)),
        request_id TEXT UNIQUE,
        payload TEXT,
        CHECK ((request_id IS NULL) = (payload IS NULL))
      )
    ''');
  }

  Future<void> _createPendingProviderOperations(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pending_provider_operations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        provider_id INTEGER NOT NULL,
        operation TEXT NOT NULL CHECK (operation IN ('save', 'products', 'delete')),
        payload TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_pending_provider_actor
      ON pending_provider_operations (actor_id, billar_id, id)
    ''');
  }

  Future<void> _createPendingCashRequests(Database db) async {
    await db.execute('''
    CREATE TABLE IF NOT EXISTS pending_cash_requests (
      actor_id TEXT NOT NULL,
      billar_id TEXT NOT NULL,
      request_id TEXT NOT NULL UNIQUE,
      operation TEXT NOT NULL,
      payload TEXT NOT NULL,
      PRIMARY KEY (actor_id, billar_id)
    )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cash_shared_movement_cache (
        cloud_id INTEGER PRIMARY KEY,
        billar_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        amount REAL NOT NULL,
        payment_method TEXT NOT NULL,
        description TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createTableSyncConflicts(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS table_sync_conflicts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        table_id INTEGER NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT NOT NULL,
        UNIQUE (actor_id, billar_id, table_id, payload)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_table_sync_conflict_scope
      ON table_sync_conflicts (actor_id, billar_id, table_id)
    ''');
  }

  Future<void> _createStaffTableServiceDrafts(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS staff_table_service_drafts (
        service_id TEXT PRIMARY KEY,
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        table_id INTEGER NOT NULL,
        table_type TEXT NOT NULL CHECK (table_type IN ('Billar', 'Comanda')),
        opened_at TEXT NOT NULL,
        state TEXT NOT NULL CHECK (state IN ('pending', 'active', 'conflict', 'closed'))
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_table_open_draft
      ON staff_table_service_drafts (actor_id, billar_id, table_id, table_type)
      WHERE state <> 'closed'
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS staff_table_service_consumptions (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        request_id TEXT NOT NULL UNIQUE,
        service_id TEXT NOT NULL,
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        product_id INTEGER NOT NULL,
        product_name TEXT NOT NULL,
        quantity REAL NOT NULL,
        price REAL NOT NULL,
        recorded_at TEXT NOT NULL,
        confirmed INTEGER NOT NULL DEFAULT 0 CHECK (confirmed IN (0, 1)),
        late INTEGER NOT NULL DEFAULT 0 CHECK (late IN (0, 1))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_staff_table_service_consumptions
      ON staff_table_service_consumptions (actor_id, billar_id, service_id, sequence)
    ''');
  }

  Future<void> _createStaffTableCheckoutOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS staff_table_checkout_outbox (
        request_id TEXT NOT NULL UNIQUE,
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        service_id TEXT NOT NULL,
        table_id INTEGER NOT NULL,
        payload TEXT NOT NULL,
        receipt TEXT,
        local_sale_id INTEGER,
        PRIMARY KEY (actor_id, billar_id, service_id)
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_table_checkout_pending
      ON staff_table_checkout_outbox (actor_id, billar_id)
      WHERE local_sale_id IS NULL
    ''');
  }

  Future<void> _createStaffTableVisibilityCache(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS staff_table_visibility_cache (
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        table_type TEXT NOT NULL CHECK (table_type IN ('Billar', 'Comanda')),
        payload TEXT NOT NULL,
        fetched_at TEXT NOT NULL,
        PRIMARY KEY (actor_id, billar_id, table_type)
      )
    ''');
  }

  Future<void> _createStaffTableLateAdjustmentOutbox(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS staff_table_late_adjustment_outbox (
        request_id TEXT NOT NULL UNIQUE,
        actor_id TEXT NOT NULL,
        billar_id TEXT NOT NULL,
        service_id TEXT NOT NULL,
        table_id INTEGER NOT NULL,
        payload TEXT NOT NULL,
        receipt TEXT,
        local_sale_id INTEGER,
        PRIMARY KEY (request_id)
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_table_late_adjustment_pending
      ON staff_table_late_adjustment_outbox (actor_id, billar_id)
      WHERE local_sale_id IS NULL
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_staff_table_late_adjustment_service
      ON staff_table_late_adjustment_outbox (actor_id, billar_id, service_id)
    ''');
  }

  Future<void> _createDB(Database db, int version) async {
    const billarId = "'BILLAR_001'";

    await _createTableSyncConflicts(db);
    await _createStaffTableServiceDrafts(db);
    await _createStaffTableCheckoutOutbox(db);
    await _createStaffTableVisibilityCache(db);
    await _createStaffTableLateAdjustmentOutbox(db);
    await _createPendingCashRequests(db);
    await _createPendingStaffRequests(db);
    await _createPendingProviderOperations(db);
    await _createPendingOwnerTransactions(db);
    await _createPendingStaffSales(db);
    await _createStaffPurchaseOperations(db);
    await _createStaffProviderOperations(db);
    await _createStaffSaleCache(db);
    await _createReconciledStaffSales(db);
    await _createPendingOwnerPromos(db);
    await db.execute('''
      CREATE TABLE products (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        billar_id       TEXT    NOT NULL DEFAULT $billarId,
        barcode         TEXT,
        name            TEXT    NOT NULL,
        description     TEXT    DEFAULT '',
        price           REAL    NOT NULL DEFAULT 0.0,
        cost            REAL    NOT NULL DEFAULT 0.0,
        stock           REAL    NOT NULL DEFAULT 0.0,
        image_path      TEXT,
        is_promo        INTEGER NOT NULL DEFAULT 0,
        parent_id       INTEGER,
        pieces_per_unit INTEGER NOT NULL DEFAULT 1,
        category        TEXT    DEFAULT '',
        presentation    TEXT    DEFAULT '',
        is_active       INTEGER NOT NULL DEFAULT 1,
        synced          INTEGER NOT NULL DEFAULT 0,
        stock_revision  INTEGER,
        local_revision  INTEGER NOT NULL DEFAULT 0,
        stock_conflict  INTEGER NOT NULL DEFAULT 0,
        cloud_id        TEXT
      )
    ''');
    await _createProductRevisionTrigger(db);

    await db.execute('''
      CREATE TABLE tournaments (
        id TEXT PRIMARY KEY,
        billar_id TEXT NOT NULL,
        name TEXT NOT NULL,
        tournament_format TEXT NOT NULL,
        capacity INTEGER,
        entries_json TEXT NOT NULL DEFAULT '[]',
        race_to INTEGER NOT NULL DEFAULT 3,
        sets_to_play INTEGER NOT NULL DEFAULT 1,
        guaranteed_pool REAL NOT NULL DEFAULT 0,
        entry_fee REAL NOT NULL DEFAULT 0,
        time_fee REAL NOT NULL DEFAULT 0,
        prizes_json TEXT NOT NULL DEFAULT '[]',
        game_type TEXT NOT NULL DEFAULT 'Bola 9',
        playoff_qualifiers INTEGER NOT NULL DEFAULT 0,
        matches_json TEXT NOT NULL DEFAULT '[]',
        is_active INTEGER NOT NULL DEFAULT 1,
        is_cancelled INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_tournaments_billar ON tournaments(billar_id, is_active)',
    );

    await db.execute('''
      CREATE TABLE pending_product_deletions (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        billar_id  TEXT NOT NULL,
        product_id INTEGER NOT NULL,
        image_path TEXT,
        synced     INTEGER NOT NULL DEFAULT 0,
        UNIQUE (billar_id, product_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE categories (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        billar_id TEXT    NOT NULL DEFAULT $billarId,
        name      TEXT    NOT NULL UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE promo_items (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_id INTEGER NOT NULL,
        child_id  INTEGER NOT NULL,
        quantity  INTEGER NOT NULL,
        FOREIGN KEY (parent_id) REFERENCES products (id) ON DELETE CASCADE
      )
    ''');

    await _createBilliardTables(db, 'billiard_tables');

    await db.execute('''
      CREATE TABLE sales_history (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        billar_id      TEXT    NOT NULL DEFAULT $billarId,
        total          REAL    NOT NULL,
        paid           REAL    NOT NULL DEFAULT 0,
        date           TEXT    NOT NULL,
        type           TEXT    NOT NULL,
        source_module  TEXT,
        payment_method TEXT    NOT NULL DEFAULT 'Efectivo',
        cancelled      INTEGER NOT NULL DEFAULT 0,
        customer_key   TEXT,
        synced         INTEGER NOT NULL DEFAULT 0,
        cloud_id       TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE sale_details (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_id       INTEGER NOT NULL,
        product_id    INTEGER,
        product_name  TEXT    NOT NULL,
        quantity      REAL    NOT NULL,
        price_at_sale REAL    NOT NULL,
        cancelled     INTEGER NOT NULL DEFAULT 0,
        cost_at_sale  REAL    NOT NULL DEFAULT 0,
        cost_available INTEGER NOT NULL DEFAULT 1,
        FOREIGN KEY (sale_id) REFERENCES sales_history (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE providers (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        name         TEXT NOT NULL,
        phone        TEXT DEFAULT '',
        email        TEXT DEFAULT '',
        address      TEXT DEFAULT '',
        contact_name TEXT DEFAULT '',
        notes        TEXT DEFAULT '',
        category     TEXT DEFAULT 'General',
        visit_days   TEXT DEFAULT '',
        is_active    INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await _addProviderPaymentTerms(db);

    await db.execute('''
      CREATE TABLE provider_products (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        provider_id INTEGER NOT NULL,
        product_id  INTEGER NOT NULL,
        UNIQUE(provider_id, product_id),
        FOREIGN KEY (provider_id) REFERENCES providers (id) ON DELETE CASCADE,
        FOREIGN KEY (product_id)  REFERENCES products  (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE purchases (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        billar_id   TEXT,
        provider_id INTEGER,
        total       REAL NOT NULL,
        date        TEXT NOT NULL,
        reference   TEXT DEFAULT '',
        created_by  TEXT DEFAULT '',
        cash_source TEXT DEFAULT 'caja',
        cancelled   INTEGER NOT NULL DEFAULT 0,
        synced      INTEGER NOT NULL DEFAULT 0,
        cloud_id    TEXT
      )
    ''');
    await _addPurchasePaymentTerms(db);

    await db.execute('''
      CREATE TABLE purchase_details (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        purchase_id   INTEGER NOT NULL,
        product_id    INTEGER NOT NULL,
        quantity      REAL    NOT NULL,
        cost_per_unit REAL    NOT NULL,
        created_by    TEXT    DEFAULT '',
        cancelled     INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (purchase_id) REFERENCES purchases (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE pending_sales (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        billar_id  TEXT,
        actor_id   TEXT,
        product    TEXT    NOT NULL,
        quantity   INTEGER NOT NULL,
        price      REAL    NOT NULL,
        created_at TEXT    NOT NULL,
        synced     INTEGER NOT NULL DEFAULT 0,
        client_id  TEXT
      )
    ''');

    // No se precargan mesas por defecto; se crean en InitialSetup o ConfigPage.

    await db.execute('''
      CREATE TABLE players (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        name           TEXT    NOT NULL,
        nickname       TEXT    DEFAULT '',
        avatar         TEXT    DEFAULT '',
        email          TEXT    NOT NULL DEFAULT '',
        player_code    TEXT    NOT NULL DEFAULT '',
        phone          TEXT    NOT NULL DEFAULT '',
        handicap       INTEGER NOT NULL DEFAULT 1,
        billar_id      TEXT    NOT NULL DEFAULT 'BILLAR_001',
        is_active      INTEGER NOT NULL DEFAULT 1,
        registered_at  TEXT,
        expires_at     TEXT,
        archived_at    TEXT,
        auth_user_id   TEXT,
        must_change_password INTEGER NOT NULL DEFAULT 0,
        client_id      TEXT,
        wins           INTEGER NOT NULL DEFAULT 0,
        losses         INTEGER NOT NULL DEFAULT 0,
        draws          INTEGER NOT NULL DEFAULT 0,
        total_matches  INTEGER NOT NULL DEFAULT 0,
        total_seconds  INTEGER NOT NULL DEFAULT 0,
        break_and_run  INTEGER NOT NULL DEFAULT 0,
        golden_breaks  INTEGER NOT NULL DEFAULT 0,
        opponent_8_ball_foul INTEGER NOT NULL DEFAULT 0,
        high_run       INTEGER NOT NULL DEFAULT 0,
        current_streak INTEGER NOT NULL DEFAULT 0,
        best_streak    INTEGER NOT NULL DEFAULT 0,
        synced         INTEGER NOT NULL DEFAULT 0,
        cloud_id       TEXT,
        created_at     TEXT    NOT NULL DEFAULT (datetime('now'))
      )
    ''');

    await db.execute('''
      CREATE TABLE personal_clients (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        client_id TEXT NOT NULL UNIQUE,
        billar_id TEXT NOT NULL,
        name TEXT NOT NULL,
        phone TEXT NOT NULL DEFAULT '',
        email TEXT NOT NULL DEFAULT '',
        notes TEXT NOT NULL DEFAULT '',
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE personal_customer_accounts (
        client_key TEXT PRIMARY KEY,
        billar_id TEXT NOT NULL,
        client_name TEXT NOT NULL,
        items_json TEXT NOT NULL DEFAULT '[]',
        updated_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE match_results (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        game_type   TEXT    NOT NULL DEFAULT 'Bola 8',
        player1_id  INTEGER,
        player2_id  INTEGER,
        winner_id   INTEGER,
        is_draw     INTEGER NOT NULL DEFAULT 0,
        golden_break INTEGER NOT NULL DEFAULT 0,
        break_and_run INTEGER NOT NULL DEFAULT 0,
        opponent_8_ball_foul INTEGER NOT NULL DEFAULT 0,
        player_score INTEGER NOT NULL DEFAULT 0,
        opponent_score INTEGER NOT NULL DEFAULT 0,
        accuracy    REAL    NOT NULL DEFAULT 0,
        efficiency  REAL    NOT NULL DEFAULT 0,
        notes       TEXT    DEFAULT '',
        date        TEXT    NOT NULL DEFAULT (datetime('now')),
        synced      INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE temp_reservations (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        source      TEXT    NOT NULL,
        source_id   INTEGER NOT NULL DEFAULT 0,
        source_key  TEXT,
        product_id  INTEGER NOT NULL,
        quantity    REAL    NOT NULL,
        created_at  TEXT    NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE inventory_movements (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        billar_id      TEXT    NOT NULL DEFAULT $billarId,
        product_id     INTEGER NOT NULL,
        movement_type  TEXT    NOT NULL,
        quantity       REAL    NOT NULL,
        unit_cost      REAL    NOT NULL DEFAULT 0,
        unit_price     REAL    NOT NULL DEFAULT 0,
        reference_id   INTEGER,
        reference_type TEXT,
        notes          TEXT    DEFAULT '',
        created_at     TEXT    NOT NULL DEFAULT (datetime('now')),
        synced         INTEGER NOT NULL DEFAULT 0,
        cloud_id       TEXT,
        client_id      TEXT UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE cash_outflows (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        billar_id      TEXT    NOT NULL DEFAULT $billarId,
        outflow_type   TEXT    NOT NULL,
        amount         REAL    NOT NULL,
        description    TEXT    NOT NULL DEFAULT '',
        payment_method TEXT    DEFAULT 'Efectivo',
        created_by     TEXT    DEFAULT '',
        created_at     TEXT    NOT NULL DEFAULT (datetime('now')),
        synced         INTEGER NOT NULL DEFAULT 0,
        cloud_id       TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE cash_outflow_concepts (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        billar_id TEXT    NOT NULL DEFAULT $billarId,
        name      TEXT    NOT NULL UNIQUE
      )
    ''');

    await db.execute('''
      CREATE TABLE cashier_sessions (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        billar_id      TEXT    NOT NULL DEFAULT $billarId,
        opened_at      TEXT    NOT NULL DEFAULT (datetime('now')),
        closed_at      TEXT,
        opening_amount REAL    NOT NULL DEFAULT 0,
        closing_amount REAL,
        expected_amount REAL,
        difference     REAL,
        is_closed      INTEGER NOT NULL DEFAULT 0,
        partial_closures TEXT  DEFAULT '[]',
        notes          TEXT    DEFAULT '',
        created_by     TEXT    DEFAULT '',
        closed_by      TEXT    DEFAULT '',
        synced         INTEGER NOT NULL DEFAULT 0,
        cloud_id       TEXT
      )
    ''');
  }
}
