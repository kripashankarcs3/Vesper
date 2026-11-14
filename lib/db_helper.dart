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
      version: 3,
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

  /// Builds the full, current (v3) schema for a brand-new vault.
  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sender TEXT NOT NULL,
        content TEXT NOT NULL,
        package_name TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        msg_uid TEXT,
        chat_key TEXT,
        chat_title TEXT
      )
    ''');
    await _createMessageIndexes(db);

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
  /// sqflite runs onUpgrade inside one transaction, so a failed step rolls back
  /// and the version is not bumped.
  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createStatusVaultTable(db);
    }
    if (oldVersion < 3) {
      // v3: native capture. Existing rows keep NULL in the new columns; NULLs
      // never collide in a UNIQUE index.
      final cols = (await db.rawQuery('PRAGMA table_info(messages)'))
          .map((r) => r['name'] as String)
          .toSet();
      if (!cols.contains('msg_uid')) {
        await db.execute('ALTER TABLE messages ADD COLUMN msg_uid TEXT');
      }
      if (!cols.contains('chat_key')) {
        await db.execute('ALTER TABLE messages ADD COLUMN chat_key TEXT');
      }
      if (!cols.contains('chat_title')) {
        await db.execute('ALTER TABLE messages ADD COLUMN chat_title TEXT');
      }
      await _createMessageIndexes(db);
    }
  }

  Future<void> _createMessageIndexes(DatabaseExecutor db) async {
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_msg_uid ON messages(msg_uid)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_messages_chat_sender ON messages(chat_key, sender, timestamp)');
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

  /// Applies native capture events (from the encrypted queue) in ONE
  /// transaction. Every event is idempotent, so replaying a batch (e.g. after a
  /// crash before the queue was acked) changes nothing. Returns the number of
  /// rows changed.
  Future<int> applyCaptureEvents(List<Map<String, dynamic>> events) async {
    if (events.isEmpty) return 0;
    final db = await instance.database;
    var changed = 0;
    await db.transaction((txn) async {
      for (final e in events) {
        switch (e['type']) {
          case 'msg':
            final id = await txn.insert(
              'messages',
              {
                'sender': e['sender'] as String? ?? '',
                'content': e['text'] as String? ?? '',
                'package_name': e['pkg'] as String? ?? '',
                'timestamp': (e['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
                'is_deleted': 0,
                'msg_uid': e['uid'] as String?,
                'chat_key': e['chatKey'] as String?,
                'chat_title': (e['isGroup'] == true) ? e['chatTitle'] as String? : null,
              },
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
            if (id > 0) changed++;
          case 'del':
            changed += await txn.update(
              'messages',
              {'is_deleted': 1},
              where: 'msg_uid = ? AND is_deleted = 0',
              whereArgs: [e['uid']],
            );
          case 'del_latest':
            final res = await txn.query(
              'messages',
              columns: ['id'],
              where: 'chat_key = ? AND sender = ? AND is_deleted = 0 AND timestamp <= ?',
              whereArgs: [e['chatKey'], e['sender'], (e['beforeTs'] as num?)?.toInt() ?? 0],
              orderBy: 'timestamp DESC, id DESC',
              limit: 1,
            );
            if (res.isNotEmpty) {
              changed += await txn.update('messages', {'is_deleted': 1},
                  where: 'id = ?', whereArgs: [res.first['id']]);
            }
          case 'media':
            final name = e['fileName'] as String?;
            if (name == null) break;
            final exists = await txn.query('media_vault',
                columns: ['id'], where: 'file_name = ?', whereArgs: [name], limit: 1);
            if (exists.isEmpty) {
              await txn.insert('media_vault', {
                'file_name': name,
                'saved_path': e['savedPath'] as String? ?? '',
                'media_type': e['mediaType'] as String? ?? 'image',
                'timestamp': (e['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
                'is_deleted_by_sender': 0,
              });
              changed++;
            }
          case 'media_del':
            changed += await txn.update(
              'media_vault',
              {'is_deleted_by_sender': 1},
              where: 'file_name = ? AND is_deleted_by_sender = 0',
              whereArgs: [e['fileName']],
            );
          default:
            break; // unknown event types from a newer native side are skipped
        }
      }
    });
    return changed;
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

