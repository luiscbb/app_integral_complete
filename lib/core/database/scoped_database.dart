import 'package:sqflite/sqflite.dart';

class ScopedDatabase implements Database {
  ScopedDatabase({
    required Database database,
    required bool Function() isCurrentScope,
  }) : _database = database,
       _isCurrentScope = isCurrentScope;

  final Database _database;
  final bool Function() _isCurrentScope;

  void _requireScope() {
    if (!_isCurrentScope()) {
      throw StateError('La cuenta o el billar de la base local cambió.');
    }
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    _requireScope();
    return _database.transaction((txn) async {
      _requireScope();
      final result = await action(txn);
      _requireScope();
      return result;
    }, exclusive: exclusive);
  }

  @override
  Future<T> readTransaction<T>(Future<T> Function(Transaction txn) action) =>
      transaction(action);

  @override
  Database get database => this;

  @override
  String get path {
    _requireScope();
    return _database.path;
  }

  @override
  bool get isOpen => _isCurrentScope() && _database.isOpen;

  @override
  Future<void> close() => _database.close();

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      transaction((txn) => txn.execute(sql, arguments));

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      transaction((txn) => txn.rawInsert(sql, arguments));

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) => transaction(
    (txn) => txn.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    ),
  );

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => transaction(
    (txn) => txn.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    ),
  );

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => transaction((txn) => txn.rawQuery(sql, arguments));

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      transaction((txn) => txn.rawUpdate(sql, arguments));

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) => transaction(
    (txn) => txn.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    ),
  );

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      transaction((txn) => txn.rawDelete(sql, arguments));

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      transaction(
        (txn) => txn.delete(table, where: where, whereArgs: whereArgs),
      );

  @override
  Batch batch() {
    _requireScope();
    return _ScopedBatch(this);
  }

  @override
  Future<QueryCursor> rawQueryCursor(
    String sql,
    List<Object?>? arguments, {
    int? bufferSize,
  }) =>
      throw UnsupportedError(
        'Los cursores no están disponibles en bases aisladas.',
      );

  @override
  Future<QueryCursor> queryCursor(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
    int? bufferSize,
  }) =>
      throw UnsupportedError(
        'Los cursores no están disponibles en bases aisladas.',
      );

  @override
  Future<T> devInvokeMethod<T>(String method, [Object? arguments]) =>
      throw UnsupportedError('Operación de desarrollo no disponible.');

  @override
  Future<T> devInvokeSqlMethod<T>(
    String method,
    String sql, [
    List<Object?>? arguments,
  ]) => throw UnsupportedError('Operación de desarrollo no disponible.');
}

class _ScopedBatch implements Batch {
  _ScopedBatch(this._database);

  final ScopedDatabase _database;
  final _operations = <void Function(Batch)>[];

  @override
  int get length => _operations.length;

  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) => _database.transaction((txn) async {
    final batch = txn.batch();
    for (final operation in _operations) {
      operation(batch);
    }
    return batch.commit(noResult: noResult, continueOnError: continueOnError);
  }, exclusive: exclusive);

  @override
  Future<List<Object?>> apply({bool? noResult, bool? continueOnError}) async {
    _database._requireScope();
    final results = <Object?>[];
    for (final operation in _operations) {
      final result = await _database.transaction((txn) {
        final batch = txn.batch();
        operation(batch);
        return batch.apply(
          noResult: noResult,
          continueOnError: continueOnError,
        );
      });
      results.addAll(result);
    }
    _database._requireScope();
    return results;
  }

  @override
  void execute(String sql, [List<Object?>? arguments]) {
    final args = arguments?.toList();
    _operations.add((batch) => batch.execute(sql, args));
  }

  @override
  void rawInsert(String sql, [List<Object?>? arguments]) {
    final args = arguments?.toList();
    _operations.add((batch) => batch.rawInsert(sql, args));
  }

  @override
  void insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    final data = Map<String, Object?>.of(values);
    _operations.add(
      (batch) => batch.insert(
        table,
        data,
        nullColumnHack: nullColumnHack,
        conflictAlgorithm: conflictAlgorithm,
      ),
    );
  }

  @override
  void rawUpdate(String sql, [List<Object?>? arguments]) {
    final args = arguments?.toList();
    _operations.add((batch) => batch.rawUpdate(sql, args));
  }

  @override
  void update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    final data = Map<String, Object?>.of(values);
    final args = whereArgs?.toList();
    _operations.add(
      (batch) => batch.update(
        table,
        data,
        where: where,
        whereArgs: args,
        conflictAlgorithm: conflictAlgorithm,
      ),
    );
  }

  @override
  void rawDelete(String sql, [List<Object?>? arguments]) {
    final args = arguments?.toList();
    _operations.add((batch) => batch.rawDelete(sql, args));
  }

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) {
    final args = whereArgs?.toList();
    _operations.add(
      (batch) => batch.delete(table, where: where, whereArgs: args),
    );
  }

  @override
  void rawQuery(String sql, [List<Object?>? arguments]) {
    final args = arguments?.toList();
    _operations.add((batch) => batch.rawQuery(sql, args));
  }

  @override
  void query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    final selectedColumns = columns?.toList();
    final args = whereArgs?.toList();
    _operations.add(
      (batch) => batch.query(
        table,
        distinct: distinct,
        columns: selectedColumns,
        where: where,
        whereArgs: args,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      ),
    );
  }
}
