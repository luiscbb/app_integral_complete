import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
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
    return await openDatabase(path, version: 7, onCreate: _createDB, onUpgrade: _upgradeDB);
  }

  Future<void> _upgradeDB(Database db, int oldV, int newV) async {
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
        category        TEXT    DEFAULT ''
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
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        name     TEXT NOT NULL,
        phone    TEXT DEFAULT '',
        address  TEXT DEFAULT '',
        category TEXT DEFAULT 'Lunes'
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

    for (int i = 1; i <= 8; i++) {
      await db.insert('billiard_tables', {
        'id': i,
        'billar_id': 'BILLAR_001',
        'name': 'Mesa $i',
        'is_occupied': 0,
        'orders': '[]',
      });
    }

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

  }
