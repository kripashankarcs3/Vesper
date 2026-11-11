import 'dart:convert';
import 'dart:math';

/// What to do with the SQLCipher vault key, given what secure storage returned
/// and whether the encrypted DB file already exists on disk.
enum VaultKeyAction {
  /// A stored key was read successfully: use it.
  useExisting,

  /// No key stored AND no DB file: first run (or after a confirmed
  /// [DBHelper.resetVault], which deletes the DB). Safe to create a new key.
  createNew,

  /// No key stored but the DB file EXISTS: the vault was encrypted with a key we
  /// can no longer read. Creating a new key here would orphan the vault for
  /// good, so we refuse and surface the recoverable error state instead.
  failKeyMissingForExistingVault,

  /// Secure storage threw. Never treat a failed read as "absent".
  failReadError,
}

/// Pure decision function — the ONLY place that may answer "create a new key".
///
/// A new key is allowed only when a read SUCCEEDED, returned nothing, and the
/// DB file does not exist. Every other "no key" situation fails safe.
VaultKeyAction decideVaultKeyAction({
  required bool readSucceeded,
  required String? storedKey,
  required bool dbFileExists,
}) {
  if (!readSucceeded) return VaultKeyAction.failReadError;
  if (storedKey != null && storedKey.isNotEmpty) return VaultKeyAction.useExisting;
  if (dbFileExists) return VaultKeyAction.failKeyMissingForExistingVault;
  return VaultKeyAction.createNew;
}

/// Thrown when the vault key cannot be obtained. The message never contains
/// key material.
class VaultKeyUnavailableException implements Exception {
  final VaultKeyAction reason;
  final String message;
  const VaultKeyUnavailableException(this.reason, this.message);

  @override
  String toString() => 'VaultKeyUnavailableException(${reason.name}): $message';
}

typedef VaultKeyReader = Future<String?> Function();
typedef VaultKeyWriter = Future<void> Function(String value);
typedef VaultFileExists = Future<bool> Function();

/// Obtains the vault key with three guarantees:
///  1. Single-flight: concurrent callers share ONE in-flight lookup, so two
///     parallel first-run initialisations can never mint two different keys
///     (the root cause of the "file is not a database" vault loss).
///  2. Fail-safe: a new key is minted only per [decideVaultKeyAction].
///  3. Persist-before-use: a new key is written AND read back before it is
///     returned, so the DB is never created with a key that was not stored.
class VaultKeyProvider {
  VaultKeyProvider({
    required VaultKeyReader read,
    required VaultKeyWriter write,
    required VaultFileExists dbFileExists,
    String Function()? generate,
    int readAttempts = 3,
    Duration retryDelay = const Duration(milliseconds: 200),
  })  : _read = read,
        _write = write,
        _dbFileExists = dbFileExists,
        _generate = generate ?? generateVaultKey,
        _readAttempts = readAttempts,
        _retryDelay = retryDelay;

  final VaultKeyReader _read;
  final VaultKeyWriter _write;
  final VaultFileExists _dbFileExists;
  final String Function() _generate;
  final int _readAttempts;
  final Duration _retryDelay;

  Future<String>? _inFlight;

  /// Returns the vault key. Concurrent calls share one lookup; a failed lookup
  /// is not cached, so a later call retries.
  Future<String> obtainKey() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _obtain();
    _inFlight = future;
    future.then((_) {}, onError: (Object _) {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  /// Drops the cached result (e.g. after the vault was reset).
  void invalidate() => _inFlight = null;

  Future<String> _obtain() async {
    // Read, retrying transient Keystore / secure-storage failures.
    String? stored;
    var readOk = false;
    for (var attempt = 0; attempt < _readAttempts && !readOk; attempt++) {
      try {
        stored = await _read();
        readOk = true;
      } catch (_) {
        if (attempt + 1 < _readAttempts) await Future.delayed(_retryDelay);
      }
    }

    final dbExists = readOk && (stored == null || stored.isEmpty) ? await _dbFileExists() : false;
    final action = decideVaultKeyAction(
      readSucceeded: readOk,
      storedKey: stored,
      dbFileExists: dbExists,
    );

    switch (action) {
      case VaultKeyAction.useExisting:
        return stored!;
      case VaultKeyAction.failReadError:
        throw const VaultKeyUnavailableException(
          VaultKeyAction.failReadError,
          'secure storage could not be read',
        );
      case VaultKeyAction.failKeyMissingForExistingVault:
        throw const VaultKeyUnavailableException(
          VaultKeyAction.failKeyMissingForExistingVault,
          'vault file exists but its key is missing; refusing to create a new key',
        );
      case VaultKeyAction.createNew:
        final newKey = _generate();
        await _write(newKey);
        // Persist-before-use: confirm the key is really stored before the
        // caller creates a DB that depends on it.
        final readBack = await _read();
        if (readBack != newKey) {
          throw const VaultKeyUnavailableException(
            VaultKeyAction.failReadError,
            'newly created key could not be verified in secure storage',
          );
        }
        return newKey;
    }
  }
}

/// 256-bit cryptographically random key, base64url encoded.
String generateVaultKey() {
  final random = Random.secure();
  final keyBytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(keyBytes);
}
