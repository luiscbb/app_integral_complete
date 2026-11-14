import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/storage/preferences_service.dart';

class PersonalClient {
  final int? id;
  final String clientId;
  final String name;
  final String phone;
  final String email;
  final String notes;
  final bool isActive;

  const PersonalClient({
    this.id,
    required this.clientId,
    required this.name,
    this.phone = '',
    this.email = '',
    this.notes = '',
    this.isActive = true,
  });

  factory PersonalClient.fromMap(Map<String, Object?> map) => PersonalClient(
    id: (map['id'] as num?)?.toInt(),
    clientId: map['client_id']?.toString() ?? '',
    name: map['name']?.toString() ?? '',
    phone: map['phone']?.toString() ?? '',
    email: map['email']?.toString() ?? '',
    notes: map['notes']?.toString() ?? '',
    isActive: map['is_active'] == true || map['is_active'] == 1,
  );
}

class PersonalCustomerAccount {
  final String clientKey;
  final String clientName;
  final List<Map<String, dynamic>> items;

  const PersonalCustomerAccount({
    required this.clientKey,
    required this.clientName,
    required this.items,
  });

  factory PersonalCustomerAccount.fromLocalMap(Map<String, Object?> map) {
    final decoded = jsonDecode(map['items_json']?.toString() ?? '[]');
    if (decoded is! List) {
      throw const FormatException('El consumo guardado no es una lista.');
    }
    return PersonalCustomerAccount(
      clientKey: map['client_key']?.toString() ?? '',
      clientName: map['client_name']?.toString() ?? '',
      items: decoded.whereType<Map>().map(Map<String, dynamic>.from).toList(),
    );
  }

  factory PersonalCustomerAccount.fromCloudMap(Map<String, dynamic> map) {
    final rawItems = map['items'];
    if (rawItems is! List) {
      throw const FormatException('El consumo remoto no es una lista.');
    }
    return PersonalCustomerAccount(
      clientKey: map['client_key']?.toString() ?? '',
      clientName: map['client_name']?.toString() ?? '',
      items: rawItems.whereType<Map>().map(Map<String, dynamic>.from).toList(),
    );
  }
}

class PersonalClientRepository {
  final _db = DatabaseHelper.instance;
  final _prefs = PreferencesService();
  SupabaseClient get _supabase => Supabase.instance.client;

  Future<List<PersonalClient>> getClients({
    bool includeInactive = false,
  }) async {
    await syncFromCloud();
    final db = await _db.database;
    final rows = await db.query(
      'personal_clients',
      where:
          includeInactive ? 'billar_id = ?' : 'billar_id = ? AND is_active = 1',
      whereArgs: [_prefs.billarId],
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map(PersonalClient.fromMap).toList();
  }

  Future<PersonalClient> saveClient(PersonalClient client) async {
    final db = await _db.database;
    final clientId = client.clientId.isEmpty ? _newClientId() : client.clientId;
    final now = DateTime.now().toUtc().toIso8601String();
    final row = {
      'client_id': clientId,
      'billar_id': _prefs.billarId,
      'name': client.name.trim().toUpperCase(),
      'phone': client.phone.trim(),
      'email': client.email.trim().toLowerCase(),
      'notes': client.notes.trim(),
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
      'synced': 0,
    };
    await db.insert(
      'personal_clients',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _pushClient(row);
    final saved = await db.query(
      'personal_clients',
      where: 'client_id = ? AND billar_id = ?',
      whereArgs: [clientId, _prefs.billarId],
      limit: 1,
    );
    return PersonalClient.fromMap(saved.single);
  }

  Future<void> archiveClient(String clientId) async {
    final db = await _db.database;
    final account = await db.query(
      'personal_customer_accounts',
      columns: ['items_json'],
      where: 'client_key = ? AND billar_id = ?',
      whereArgs: ['client:$clientId', _prefs.billarId],
      limit: 1,
    );
    if (account.isNotEmpty &&
        PersonalCustomerAccount.fromLocalMap(account.single).items.isNotEmpty) {
      throw StateError('Cierra primero la cuenta abierta de este cliente.');
    }
    await db.update(
      'personal_clients',
      {
        'is_active': 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'synced': 0,
      },
      where: 'client_id = ? AND billar_id = ?',
      whereArgs: [clientId, _prefs.billarId],
    );
    final rows = await db.query(
      'personal_clients',
      where: 'client_id = ? AND billar_id = ?',
      whereArgs: [clientId, _prefs.billarId],
      limit: 1,
    );
    if (rows.isNotEmpty) await _pushClient(rows.single);
  }

  Future<List<PersonalCustomerAccount>> getOpenAccounts() async {
    await syncFromCloud();
    final db = await _db.database;
    final rows = await db.query(
      'personal_customer_accounts',
      where: 'billar_id = ?',
      whereArgs: [_prefs.billarId],
      orderBy: 'updated_at DESC',
    );
    return rows
        .map(PersonalCustomerAccount.fromLocalMap)
        .where((account) => account.items.isNotEmpty)
        .toList();
  }

  Future<void> saveAccount({
    required String clientKey,
    required String clientName,
    required List<Map<String, dynamic>> items,
  }) async {
    final db = await _db.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('personal_customer_accounts', {
      'client_key': clientKey,
      'billar_id': _prefs.billarId,
      'client_name': clientName,
      'items_json': jsonEncode(items),
      'updated_at': now,
      'synced': 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    final rows = await db.query(
      'personal_customer_accounts',
      where: 'client_key = ? AND billar_id = ?',
      whereArgs: [clientKey, _prefs.billarId],
      limit: 1,
    );
    if (rows.isNotEmpty) await _pushAccount(rows.single);
  }

  Future<void> syncFromCloud() async {
    if (_supabase.auth.currentUser == null) return;
    try {
      final db = await _db.database;
      final clients = await _supabase
          .from('personal_clients')
          .select()
          .eq('billar_id', _prefs.billarId);
      for (final raw in clients) {
        final cloud = Map<String, dynamic>.from(raw);
        final clientId = cloud['client_id']?.toString();
        if (clientId == null || clientId.isEmpty) continue;
        final local = await db.query(
          'personal_clients',
          columns: ['synced'],
          where: 'client_id = ? AND billar_id = ?',
          whereArgs: [clientId, _prefs.billarId],
          limit: 1,
        );
        if (local.isNotEmpty &&
            (local.single['synced'] as num?)?.toInt() == 0) {
          continue;
        }
        await db.insert('personal_clients', {
          'client_id': clientId,
          'billar_id': _prefs.billarId,
          'name': cloud['name']?.toString() ?? '',
          'phone': cloud['phone']?.toString() ?? '',
          'email': cloud['email']?.toString() ?? '',
          'notes': cloud['notes']?.toString() ?? '',
          'is_active': cloud['is_active'] == true ? 1 : 0,
          'created_at':
              cloud['created_at']?.toString() ??
              DateTime.now().toIso8601String(),
          'updated_at':
              cloud['updated_at']?.toString() ??
              DateTime.now().toIso8601String(),
          'synced': 1,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      final accounts = await _supabase
          .from('personal_customer_accounts')
          .select()
          .eq('billar_id', _prefs.billarId);
      final cloudKeys = <String>{};
      for (final raw in accounts) {
        final cloud = Map<String, dynamic>.from(raw);
        final account = PersonalCustomerAccount.fromCloudMap(cloud);
        cloudKeys.add(account.clientKey);
        final local = await db.query(
          'personal_customer_accounts',
          columns: ['synced'],
          where: 'client_key = ? AND billar_id = ?',
          whereArgs: [account.clientKey, _prefs.billarId],
          limit: 1,
        );
        if (local.isNotEmpty &&
            (local.single['synced'] as num?)?.toInt() == 0) {
          continue;
        }
        await db.insert('personal_customer_accounts', {
          'client_key': account.clientKey,
          'billar_id': _prefs.billarId,
          'client_name': account.clientName,
          'items_json': jsonEncode(account.items),
          'updated_at':
              cloud['updated_at']?.toString() ??
              DateTime.now().toIso8601String(),
          'synced': 1,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      final pendingClients = await db.query(
        'personal_clients',
        where: 'billar_id = ? AND synced = 0',
        whereArgs: [_prefs.billarId],
      );
      for (final client in pendingClients) {
        await _pushClient(client);
      }
      final pendingAccounts = await db.query(
        'personal_customer_accounts',
        where: 'billar_id = ? AND synced = 0',
        whereArgs: [_prefs.billarId],
      );
      for (final account in pendingAccounts) {
        await _pushAccount(account);
      }

      final localSyncedAccounts = await db.query(
        'personal_customer_accounts',
        columns: ['client_key', 'synced'],
        where: 'billar_id = ? AND synced = 1',
        whereArgs: [_prefs.billarId],
      );
      for (final local in localSyncedAccounts) {
        final key = local['client_key']?.toString();
        if (key != null && !cloudKeys.contains(key)) {
          await db.delete(
            'personal_customer_accounts',
            where: 'client_key = ? AND billar_id = ? AND synced = 1',
            whereArgs: [key, _prefs.billarId],
          );
        }
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[PersonalClientRepository] Cloud sync failed; retaining local data: '
        '$error\n$stackTrace',
      );
    }
  }

  Future<void> _pushClient(Map<String, Object?> client) async {
    if (_supabase.auth.currentUser == null) return;
    try {
      await _supabase.from('personal_clients').upsert({
        'billar_id': client['billar_id'] ?? _prefs.billarId,
        'client_id': client['client_id'],
        'name': client['name'],
        'phone': client['phone'] ?? '',
        'email': client['email'] ?? '',
        'notes': client['notes'] ?? '',
        'is_active': (client['is_active'] as num?)?.toInt() != 0,
        'created_at': client['created_at'],
        'updated_at': client['updated_at'],
      }, onConflict: 'billar_id,client_id');
      final db = await _db.database;
      await db.update(
        'personal_clients',
        {'synced': 1},
        where: 'client_id = ? AND billar_id = ?',
        whereArgs: [
          client['client_id'],
          client['billar_id'] ?? _prefs.billarId,
        ],
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[PersonalClientRepository] Could not sync client: $error\n$stackTrace',
      );
    }
  }

  Future<void> _pushAccount(Map<String, Object?> account) async {
    if (_supabase.auth.currentUser == null) return;
    try {
      final rawItems = jsonDecode(account['items_json']?.toString() ?? '[]');
      if (rawItems is! List) {
        throw const FormatException('El consumo guardado no es una lista.');
      }
      await _supabase.from('personal_customer_accounts').upsert({
        'billar_id': account['billar_id'] ?? _prefs.billarId,
        'client_key': account['client_key'],
        'client_name': account['client_name'],
        'items': rawItems,
        'updated_at': account['updated_at'],
      }, onConflict: 'billar_id,client_key');
      final db = await _db.database;
      await db.update(
        'personal_customer_accounts',
        {'synced': 1},
        where: 'client_key = ? AND billar_id = ?',
        whereArgs: [
          account['client_key'],
          account['billar_id'] ?? _prefs.billarId,
        ],
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[PersonalClientRepository] Could not sync open account: '
        '$error\n$stackTrace',
      );
    }
  }

  String _newClientId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
