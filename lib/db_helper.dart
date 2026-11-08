import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:path/path.dart';

class DBHelper {
  static final DBHelper instance = DBHelper._init();
  static Database? _database;

  // Hardware-backed Encrypted SharedPreferences
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _dbKeyName = 'wa_shield_sqlcipher_master_key_v1';

  DBHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('wa_shield_vault_encrypted.db');
    return _database!;
  }

  static const _dbFileName = 'wa_shield_vault_encrypted.db';

  // Generate or retrieve 256-bit cryptographic random key from Android Keystore.
  Future<String> _getOrCreateEncryptionKey() async {
    // Read the existing key, retrying transient Keystore/secure-storage glitches.
    // CRITICAL: a read that merely FAILS must never cause us to delete or
    // regenerate the stored key — doing so would make the existing encrypted
    // vault permanently unreadable. We only create a new key when a successful
    // read proves the key is genuinely absent (first run / explicitly reset).
    Object? lastError;
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final existingKey = await _secureStorage.read(key: _dbKeyName);
        if (existingKey != null && existingKey.isNotEmpty) {
          return existingKey;
        }
        // Read succeeded, key is genuinely absent -> create and PERSIST one.
        // If the write fails we must not return an unpersisted key (the next
        // launch could not reopen the DB), so let the error propagate/retry.
        final newKey = _generateKey();
        await _secureStorage.write(key: _dbKeyName, value: newKey);
        return newKey;
      } catch (e) {
        lastError = e;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    // Persistently unavailable: fail initialization rather than silently
    // regenerate the key or proceed with an unpersisted one. The caller surfaces
    // this as a recoverable error state (no data is touched or destroyed).
    throw StateError('WA Shield: encryption key unavailable ($lastError)');
  }

  String _generateKey() {
    final random = Random.secure();
    final keyBytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(keyBytes);
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    final encryptionPassword = await _getOrCreateEncryptionKey();

    // Open the vault. We do NOT delete or recreate it on failure: a transient
    // I/O or Keystore fault must never destroy an otherwise-recoverable
    // encrypted vault. A genuine wrong-key / corruption condition is surfaced to
    // the caller, which can offer the user an explicit, confirmed "discard
    // unreadable vault" action (resetVault) — the only path that deletes data.
    return await openDatabase(
      path,
      password: encryptionPassword, // AES-256 SQLCipher Encryption Active
      version: 2,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  /// Closes any open handle so the next access reopens from disk.
  Future<void> close() async {
    final db = _database;
    _database = null;
    if (db != null) {
      try {
        await db.close();
      } catch (_) {}
    }
  }

  /// Permanently discards an UNREADABLE vault (wrong key / corruption) and lets
  /// the next access create a fresh empty one. Destructive — call ONLY after the
  /// user has explicitly confirmed, never automatically on an open failure.
  Future<void> resetVault() async {
    await close();
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbFileName);
    try {
      await deleteDatabase(path);
    } catch (_) {}
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sender TEXT NOT NULL,
        content TEXT NOT NULL,
        package_name TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE media_vault (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_name TEXT NOT NULL,
        saved_path TEXT NOT NULL,
        media_type TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        is_deleted_by_sender INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await _createStatusVaultTable(db);
  }

  /// Non-destructive migrations. Existing tables and rows are never dropped.
  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createStatusVaultTable(db);
    }
  }

  Future<void> _createStatusVaultTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS status_vault (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_name TEXT NOT NULL UNIQUE,
        saved_path TEXT NOT NULL,
        media_type TEXT NOT NULL,
        source_pkg TEXT NOT NULL,
        original_mtime INTEGER NOT NULL,
        saved_at INTEGER NOT NULL
      )
    ''');
  }

  Future<int?> insertMessage({
    required String sender,
    required String content,
    required String packageName,
  }) async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    final recentDupes = await db.query(
      'messages',
      where: 'sender = ? AND content = ? AND (? - timestamp) < 3000',
      whereArgs: [sender, content, now],
    );

    if (recentDupes.isNotEmpty) return null;

    return await db.insert('messages', {
      'sender': sender,
      'content': content,
      'package_name': packageName,
      'timestamp': now,
      'is_deleted': 0,
    });
  }

  Future<bool> markLatestAsDeleted(String sender, String packageName) async {
    final db = await instance.database;

    // Scope the match to the SAME sender AND the SAME app (package). Without the
    // package filter, a "deleted" event from WhatsApp could revoke a message in
    // a same-named WhatsApp Business conversation (or vice-versa).
    final res = await db.query(
      'messages',
      where: 'sender = ? AND package_name = ? AND is_deleted = 0',
      whereArgs: [sender, packageName],
      orderBy: 'timestamp DESC',
      limit: 1,
    );

    if (res.isNotEmpty) {
      final int targetId = res.first['id'] as int;
      await db.update(
        'messages',
        {'is_deleted': 1},
        where: 'id = ?',
        whereArgs: [targetId],
      );
      return true;
    }
    return false;
  }

  Future<List<Map<String, dynamic>>> fetchMessages({bool onlyDeleted = false}) async {
    final db = await instance.database;
    return await db.query(
      'messages',
      where: onlyDeleted ? 'is_deleted = 1' : null,
      orderBy: 'timestamp DESC',
      limit: 300,
    );
  }

  Future<void> insertMedia({
    required String fileName,
    required String savedPath,
    required String mediaType,
  }) async {
    final db = await instance.database;
    await db.insert('media_vault', {
      'file_name': fileName,
      'saved_path': savedPath,
      'media_type': mediaType,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'is_deleted_by_sender': 0,
    });
  }

  Future<void> markMediaDeleted(String fileName) async {
    final db = await instance.database;
    await db.update(
      'media_vault',
      {'is_deleted_by_sender': 1},
      where: 'file_name = ?',
      whereArgs: [fileName],
    );
  }

  Future<List<Map<String, dynamic>>> fetchMedia() async {
    final db = await instance.database;
    return await db.query('media_vault', orderBy: 'timestamp DESC');
  }

  // ---------------------------------------------------------------------------
  // Status vault
  // ---------------------------------------------------------------------------

  /// Inserts a saved status. Returns the new row id, or null if a row with the
  /// same file_name already exists (idempotent save).
  Future<int?> insertSavedStatus({
    required String fileName,
    required String savedPath,
    required String mediaType,
    required String sourcePkg,
    required int originalMtime,
  }) async {
    final db = await instance.database;
    final id = await db.insert(
      'status_vault',
      {
        'file_name': fileName,
        'saved_path': savedPath,
        'media_type': mediaType,
        'source_pkg': sourcePkg,
        'original_mtime': originalMtime,
        'saved_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return id > 0 ? id : null;
  }

  Future<bool> isStatusSaved(String fileName) async {
    final db = await instance.database;
    final res = await db.query(
      'status_vault',
      columns: ['id'],
      where: 'file_name = ?',
      whereArgs: [fileName],
      limit: 1,
    );
    return res.isNotEmpty;
  }

  Future<Set<String>> fetchSavedStatusFileNames() async {
    final db = await instance.database;
    final res = await db.query('status_vault', columns: ['file_name']);
    return res.map((r) => r['file_name'] as String).toSet();
  }

  Future<List<Map<String, dynamic>>> fetchSavedStatuses() async {
    final db = await instance.database;
    return await db.query('status_vault', orderBy: 'saved_at DESC, id DESC');
  }

  Future<Map<String, dynamic>?> fetchSavedStatusById(int id) async {
    final db = await instance.database;
    final res = await db.query('status_vault', where: 'id = ?', whereArgs: [id], limit: 1);
    return res.isEmpty ? null : res.first;
  }

  Future<int> deleteSavedStatus(int id) async {
    final db = await instance.database;
    return await db.delete('status_vault', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> countSavedStatuses() async {
    final db = await instance.database;
    final res = await db.rawQuery('SELECT COUNT(*) AS c FROM status_vault');
    return (res.first['c'] as int?) ?? 0;
  }

  Future<void> clearAllData() async {
    final db = await instance.database;
    await db.delete('messages');
    await db.delete('media_vault');
    await db.delete('status_vault');
  }
}

