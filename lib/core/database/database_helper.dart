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
    return await openDatabase(path, version: 13, onCreate: _createDB, onUpgrade: _upgradeDB);
  }
  Future<void> _upgradeDB(Database db, int oldV, int newV) async {
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
      await db.execute("ALTER TABLE billiard_tables ADD COLUMN table_type TEXT NOT NULL DEFAULT 'Pool'");
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
      await db.execute('ALTER TABLE match_results ADD COLUMN player_score INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE match_results ADD COLUMN opponent_score INTEGER NOT NULL DEFAULT 0');
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
          cloud_id       TEXT
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
        synced          INTEGER NOT NULL DEFAULT 0,
        cloud_id        TEXT
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
        orders      TEXT    DEFAULT '[]'
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
        synced     INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // No se precargan mesas por defecto; se crean en InitialSetup o ConfigPage.

    await db.execute('''
      CREATE TABLE players (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        name           TEXT    NOT NULL,
        nickname       TEXT    DEFAULT '',
        avatar         TEXT    DEFAULT '',
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
        synced         INTEGER NOT NULL DEFAULT 0,
        cloud_id       TEXT,
        created_at     TEXT    NOT NULL DEFAULT (datetime('now'))
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
        cloud_id       TEXT
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