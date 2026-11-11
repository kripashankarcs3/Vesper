import 'package:flutter_test/flutter_test.dart';
import 'package:wa_shield/vault_key.dart';

/// In-memory stand-in for flutter_secure_storage with controllable latency and
/// failures. Holds a fake key only.
class _FakeStore {
  String? value;
  int reads = 0;
  int writes = 0;
  bool failReads = false;
  bool dropWrites = false;
  Duration latency = Duration.zero;

  Future<String?> read() async {
    reads++;
    await Future.delayed(latency);
    if (failReads) throw Exception('keystore unavailable');
    return value;
  }

  Future<void> write(String v) async {
    writes++;
    await Future.delayed(latency);
    if (!dropWrites) value = v;
  }
}

VaultKeyProvider _provider(_FakeStore store, {bool dbExists = false}) {
  var n = 0;
  return VaultKeyProvider(
    read: store.read,
    write: store.write,
    dbFileExists: () async => dbExists,
    generate: () => 'generated-${++n}',
    retryDelay: Duration.zero,
  );
}

void main() {
  group('decideVaultKeyAction', () {
    test('key present -> use it (DB present or not)', () {
      for (final db in [true, false]) {
        expect(
          decideVaultKeyAction(readSucceeded: true, storedKey: 'k', dbFileExists: db),
          VaultKeyAction.useExisting,
        );
      }
    });

    test('key absent + DB absent -> create new (first run / after reset)', () {
      expect(
        decideVaultKeyAction(readSucceeded: true, storedKey: null, dbFileExists: false),
        VaultKeyAction.createNew,
      );
      expect(
        decideVaultKeyAction(readSucceeded: true, storedKey: '', dbFileExists: false),
        VaultKeyAction.createNew,
      );
    });

    test('key absent + DB present -> fail safe, never create', () {
      expect(
        decideVaultKeyAction(readSucceeded: true, storedKey: null, dbFileExists: true),
        VaultKeyAction.failKeyMissingForExistingVault,
      );
      expect(
        decideVaultKeyAction(readSucceeded: true, storedKey: '', dbFileExists: true),
        VaultKeyAction.failKeyMissingForExistingVault,
      );
    });

    test('read error -> fail, regardless of DB state', () {
      for (final db in [true, false]) {
        expect(
          decideVaultKeyAction(readSucceeded: false, storedKey: null, dbFileExists: db),
          VaultKeyAction.failReadError,
        );
      }
    });
  });

  group('VaultKeyProvider', () {
    test('existing key is returned and never overwritten', () async {
      final store = _FakeStore()..value = 'existing';
      final key = await _provider(store, dbExists: true).obtainKey();
      expect(key, 'existing');
      expect(store.writes, 0);
    });

    test('first run creates, persists and verifies exactly one key', () async {
      final store = _FakeStore();
      final key = await _provider(store).obtainKey();
      expect(key, 'generated-1');
      expect(store.value, 'generated-1');
      expect(store.writes, 1);
    });

    test('REGRESSION: concurrent first-run callers share ONE key', () async {
      // Old code: two parallel _initDB calls both read null, both generated a
      // key; the DB was created with one, storage kept the other.
      final store = _FakeStore()..latency = const Duration(milliseconds: 5);
      final p = _provider(store);
      final keys = await Future.wait([p.obtainKey(), p.obtainKey(), p.obtainKey()]);
      expect(keys.toSet(), {'generated-1'});
      expect(store.writes, 1);
      expect(store.value, 'generated-1');
    });

    test('key absent but DB present -> throws, writes nothing', () async {
      final store = _FakeStore();
      await expectLater(
        _provider(store, dbExists: true).obtainKey(),
        throwsA(isA<VaultKeyUnavailableException>().having(
            (e) => e.reason, 'reason', VaultKeyAction.failKeyMissingForExistingVault)),
      );
      expect(store.writes, 0);
      expect(store.value, isNull);
    });

    test('read error -> throws after retries, writes nothing', () async {
      final store = _FakeStore()..failReads = true;
      await expectLater(
        _provider(store).obtainKey(),
        throwsA(isA<VaultKeyUnavailableException>()
            .having((e) => e.reason, 'reason', VaultKeyAction.failReadError)),
      );
      expect(store.reads, 3);
      expect(store.writes, 0);
    });

    test('failure is not cached: a later call can succeed', () async {
      final store = _FakeStore()..failReads = true;
      final p = _provider(store, dbExists: true);
      await expectLater(p.obtainKey(), throwsA(isA<VaultKeyUnavailableException>()));
      store
        ..failReads = false
        ..value = 'existing';
      expect(await p.obtainKey(), 'existing');
    });

    test('unverifiable write -> throws instead of returning an unstored key', () async {
      final store = _FakeStore()..dropWrites = true;
      await expectLater(
        _provider(store).obtainKey(),
        throwsA(isA<VaultKeyUnavailableException>()),
      );
    });

    test('exception text never contains key material', () async {
      final store = _FakeStore()..dropWrites = true;
      try {
        await _provider(store).obtainKey();
        fail('expected exception');
      } on VaultKeyUnavailableException catch (e) {
        expect(e.toString(), isNot(contains('generated-')));
      }
    });
  });
}
