import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('integral_pos_v1.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    String path;
    if (Platform.isWindows || Platform.isLinux) {
      ffi.sqfliteFfiInit();
      databaseFactory = ffi.databaseFactoryFfi;
      final dir = await getApplicationDocumentsDirectory();
      path = join(dir.path, 'BaumarSolutions', 'database', filePath);
      final file = File(path);
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
    } else {
      final dbPath = await getDatabasesPath();
      path = join(dbPath, filePath);
    }
    return await openDatabase(path, version: 36, onCreate: _createDB, onUpgrade: _upgradeDB);
  }

  Future<void> _upgradeDB(Database db, int oldV, int newV) async {
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
          await db.execute('ALTER TABLE players ADD COLUMN ${entry.key} ${entry.value}');
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
      await db.execute("ALTER TABLE players ADD COLUMN phone TEXT NOT NULL DEFAULT ''");
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
        await db.execute('ALTER TABLE tournaments ADD COLUMN race_to INTEGER NOT NULL DEFAULT 3');
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
          await db.execute('ALTER TABLE tournaments ADD COLUMN ${entry.key} ${entry.value}');
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
          await db.execute('ALTER TABLE tournaments ADD COLUMN ${entry.key} ${entry.value}');
        }
      }
    }
    if (oldV < 35) {
      if (!await _hasColumn(db, 'temp_reservations', 'source_key')) {
        await db.execute("ALTER TABLE temp_reservations ADD COLUMN source_key TEXT");
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
        await db.execute('ALTER TABLE sales_history ADD COLUMN customer_key TEXT');
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
      await db.execute('ALTER TABLE billiard_tables ADD COLUMN synced INTEGER NOT NULL DEFAULT 1');
    }
    if (oldV < 20) {
      await db.execute('ALTER TABLE pending_sales ADD COLUMN client_id TEXT');
    }
    if (oldV < 19) {
      // Informe de UTILIDAD (Etapa 4): costo unitario del producto al momento
      // de vender. Permite calcular "costo de lo vendido" histórico real
      // (aunque el costo del producto cambie después).
      await db.execute("ALTER TABLE sale_details ADD COLUMN cost_at_sale REAL NOT NULL DEFAULT 0");
    }
    if (oldV < 18) {
      // Anulación lógica de compras: marca la compra como anulada sin borrarla
      // (para que el pull de la nube no la re-inserte) y descuenta el stock
      // que la compra había sumado. 1 = anulada (excluida de informes/caja).
      await db.execute("ALTER TABLE purchases ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0");
      await db.execute(
        "ALTER TABLE purchase_details ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0",
      );
    }
    if (oldV < 17) {
      // Anulación lógica de ventas: permite marcar una venta como anulada
      // (con contraseña) sin borrarla, para que el pull de la nube no la
      // re-inserte. 1 = anulada (excluida de informes/caja/historial).
      await db.execute("ALTER TABLE sales_history ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0");
      await db.execute("ALTER TABLE sale_details ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0");
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
      await db.execute("ALTER TABLE purchases ADD COLUMN cash_source TEXT DEFAULT 'caja'");
    }
    if (oldV < 14) {
      // Usuario logueado que realizó la compra (para detalle/PDF y cortes por turno)
      await db.execute("ALTER TABLE purchases ADD COLUMN created_by TEXT DEFAULT ''");
      await db.execute("ALTER TABLE purchase_details ADD COLUMN created_by TEXT DEFAULT ''");
    }
    if (oldV < 12) {
      await db.execute("ALTER TABLE products ADD COLUMN presentation TEXT DEFAULT ''");
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
      await db.execute('ALTER TABLE sales_history ADD COLUMN paid REAL NOT NULL DEFAULT 0');
    }
    if (oldV < 3) {
      await db.execute('ALTER TABLE sales_history ADD COLUMN synced INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE sales_history ADD COLUMN cloud_id TEXT');
      await db.execute('ALTER TABLE purchases ADD COLUMN synced INTEGER NOT NULL DEFAULT 0');
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
      await db.execute('ALTER TABLE players ADD COLUMN synced INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE players ADD COLUMN cloud_id TEXT');
    }
    if (oldV < 7) {
      await db.execute("ALTER TABLE products ADD COLUMN category TEXT DEFAULT ''");
      await db.execute('''
        CREATE TABLE IF NOT EXISTS categories (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          billar_id TEXT    NOT NULL DEFAULT 'BILLAR_001',
          name      TEXT    NOT NULL UNIQUE
        )
      ''');
    }
    if (oldV < 9) {
      await db.execute('ALTER TABLE products ADD COLUMN synced INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE products ADD COLUMN cloud_id TEXT');
    }
    if (oldV < 8) {
      await db.execute(
        'ALTER TABLE match_results ADD COLUMN player_score INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE match_results ADD COLUMN opponent_score INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute('ALTER TABLE match_results ADD COLUMN accuracy REAL NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE match_results ADD COLUMN efficiency REAL NOT NULL DEFAULT 0');
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
      await db.execute('ALTER TABLE inventory_movements ADD COLUMN client_id TEXT');
      await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_inventory_movements_client_id '
        'ON inventory_movements (client_id)',
      );
      await db.execute('UPDATE inventory_movements SET synced = 0 WHERE cloud_id IS NULL');
    }
    if (oldV < 24) {
      await db.execute('ALTER TABLE products ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1');
    }
  }

  Future<bool> _hasColumn(Database db, String tableName, String columnName) async {
    final columns = await db.rawQuery('PRAGMA table_info($tableName)');
    return columns.any((column) => column['name'] == columnName);
  }

  Future<void> _createDB(Database db, int version) async {
    const billarId = "'BILLAR_001'";

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
        cloud_id        TEXT
      )
    ''');

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
    await db.execute('CREATE INDEX idx_tournaments_billar ON tournaments(billar_id, is_active)');

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

    await db.execute('''
      CREATE TABLE billiard_tables (
        id          INTEGER PRIMARY KEY,
        billar_id   TEXT    NOT NULL DEFAULT $billarId,
        name        TEXT    NOT NULL,
        table_type  TEXT    NOT NULL DEFAULT 'Pool',
        is_occupied INTEGER NOT NULL DEFAULT 0,
        start_time  TEXT,
        orders      TEXT    DEFAULT '[]',
        synced      INTEGER NOT NULL DEFAULT 1,
        is_deleted  INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE sales_history (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        billar_id      TEXT    NOT NULL DEFAULT $billarId,
        total          REAL    NOT NULL,
        paid           REAL    NOT NULL DEFAULT 0,
        date           TEXT    NOT NULL,
        type           TEXT    NOT NULL,
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
        visit_days   TEXT DEFAULT ''
      )
    ''');

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
