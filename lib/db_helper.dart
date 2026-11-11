import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:path/path.dart';
import 'vault_key.dart';

class DBHelper {
  static final DBHelper instance = DBHelper._init();
  static Database? _database;
  static Future<Database>? _opening;

  // Hardware-backed Encrypted SharedPreferences.
  // IMPORTANT: these options and the key name MUST stay exactly as they are —
  // existing installs keep their vault key under them. resetOnError must stay
  // false: the plugin would otherwise deleteAll() (i.e. destroy the key) on any
  // read error.
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true, resetOnError: false),
  );
  static const _dbKeyName = 'wa_shield_sqlcipher_master_key_v1';
  static const _dbFileName = 'wa_shield_vault_encrypted.db';

  late final VaultKeyProvider _keyProvider = VaultKeyProvider(
    read: () => _secureStorage.read(key: _dbKeyName),
    write: (v) => _secureStorage.write(key: _dbKeyName, value: v),
    dbFileExists: () async => File(await _dbFilePath()).exists(),
  );

  DBHelper._init();

  Future<String> _dbFilePath() async => join(await getDatabasesPath(), _dbFileName);

  /// Single-flight open. Many callers (initState refresh, media watcher, status
  /// screen, notification stream) hit this concurrently at startup; previously
  /// each ran its own _initDB, and on first run two of them could each mint a
  /// different key — the DB got created with one key while storage kept the
  /// other, so the vault became unreadable on the next cold start. A failed
  /// open is not cached, so a later access retries.
  Future<Database> get database {
    final db = _database;
    if (db != null) return Future.value(db);
    final pending = _opening;
    if (pending != null) return pending;
    final future = _initDB().then((opened) {
      _database = opened;
      return opened;
    });
    _opening = future;
    future.then((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_opening, future)) _opening = null;
    });
    return future;
  }

  Future<Database> _initDB() async {
    final path = await _dbFilePath();
    // Fail-safe key lookup (see vault_key.dart): a new key is created ONLY when
    // the DB file does not exist; a missing key for an existing vault throws.
    final encryptionPassword = await _keyProvider.obtainKey();

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
    // Let an in-flight open finish first so its handle is not leaked.
    final pending = _opening;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
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
    final path = await _dbFilePath();
    try {
      await deleteDatabase(path);
    } catch (_) {}
    // The stored key is kept; with the DB gone, the next open reuses it.
    _keyProvider.invalidate();
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

