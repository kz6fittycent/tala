import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'log.dart';
import 'nc_api.dart';

/// Why the keyring couldn't answer. Never holds a secret.
class KeyringException implements Exception {
  KeyringException({required this.locked, required this.message});

  /// The user has to unlock it. Otherwise no keyring service answered, which
  /// can clear up by itself while a login session is still starting.
  final bool locked;
  final String message;

  @override
  String toString() => 'KeyringException(locked: $locked, $message)';
}

/// Where secrets are kept. Each operating system supplies its own native code
/// behind the same channel; the rest of the app only sees this interface.
abstract class SecretStore {
  Future<String?> read(String item);
  Future<void> write(String item, String label, String secret);
  Future<void> delete(String item);
}

class KeyringSecretStore implements SecretStore {
  static const MethodChannel _channel = MethodChannel('tala/keyring');

  Future<T?> _call<T>(String method, Map<String, String> args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw KeyringException(
        locked: e.code == 'locked',
        message: e.message ?? e.code,
      );
    } on MissingPluginException {
      throw KeyringException(
        locked: false,
        message: 'No keyring code on this platform',
      );
    }
  }

  @override
  Future<String?> read(String item) =>
      _call<String>('read', {'item': item});

  @override
  Future<void> write(String item, String label, String secret) => _call<void>(
    'write',
    {'item': item, 'label': label, 'secret': secret},
  );

  @override
  Future<void> delete(String item) => _call<void>('delete', {'item': item});
}

/// Keeps the signed-in account in the keyring. Also moves an account across
/// from the prototype's plain file, which is removed only once the keyring has
/// been read back and matches.
class AccountStore {
  AccountStore({SecretStore? secrets, File? legacyFile})
    : _secrets = secrets ?? KeyringSecretStore(),
      _legacy = legacyFile ??
          File(
            '${Platform.environment['HOME']}'
            '/.config/tala-prototype/credentials.json',
          );

  final SecretStore _secrets;
  final File _legacy;

  static const _item = 'account';
  static const _label = 'Tala account';

  /// The saved account, or null if there is none. Throws [KeyringException] if
  /// the keyring can't answer and there's no old file to fall back on.
  Future<Credentials?> load() async {
    final String? stored;
    try {
      stored = await _secrets.read(_item);
    } on KeyringException catch (e) {
      final old = _readLegacy();
      if (old == null) rethrow;
      log('account: keyring unavailable, using the old file for now: '
          '${e.message}');
      return old;
    }
    if (stored != null) {
      final creds = _decode(stored);
      if (creds != null) {
        _deleteLegacy();
        return creds;
      }
      log('account: the keyring entry could not be read');
    }
    final old = _readLegacy();
    if (old != null) await _migrate(old);
    return old;
  }

  /// Throws [KeyringException] if it couldn't be stored.
  Future<void> save(Credentials creds) =>
      _secrets.write(_item, _label, _encode(creds));

  Future<void> _migrate(Credentials creds) async {
    final encoded = _encode(creds);
    try {
      await _secrets.write(_item, _label, encoded);
      if (await _secrets.read(_item) != encoded) {
        log('account: keyring read-back did not match, keeping the old file');
        return;
      }
    } on KeyringException catch (e) {
      log('account: moving to the keyring failed, keeping the old file: '
          '${e.message}');
      return;
    }
    _deleteLegacy();
    log('account: moved to the keyring');
  }

  Credentials? _readLegacy() {
    try {
      if (!_legacy.existsSync()) return null;
      final creds = _decode(_legacy.readAsStringSync());
      if (creds == null) log('account: the old file could not be read');
      return creds;
    } on FileSystemException catch (e) {
      log('account: the old file could not be read: ${e.osError?.message}');
      return null;
    }
  }

  void _deleteLegacy() {
    try {
      if (_legacy.existsSync()) _legacy.deleteSync();
    } on FileSystemException catch (e) {
      log('account: removing the old file failed: ${e.osError?.message}');
    }
  }

  static String _encode(Credentials c) => jsonEncode({
    'server': c.server,
    'user': c.user,
    'appPassword': c.appPassword,
  });

  static Credentials? _decode(String text) {
    try {
      final d = jsonDecode(text) as Map<String, dynamic>;
      return Credentials(
        d['server'] as String,
        d['user'] as String,
        d['appPassword'] as String,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

/// Exercises the real keyring with a throwaway entry, then the account store.
/// Logs outcomes only, never contents. Returns whether everything worked.
Future<bool> keyringSelfTest() async {
  const item = 'selftest';
  final secrets = KeyringSecretStore();
  final value = 'selftest-${DateTime.now().microsecondsSinceEpoch}';
  var passed = true;
  try {
    await secrets.write(item, 'Tala self-test (safe to delete)', value);
    final matched = await secrets.read(item) == value;
    log('keyring: round trip ${matched ? 'matched' : 'DID NOT MATCH'}');
    await secrets.delete(item);
    final gone = await secrets.read(item) == null;
    log('keyring: delete ${gone ? 'worked' : 'DID NOT WORK'}');
    passed = matched && gone;
  } on KeyringException catch (e) {
    log('keyring: failed, locked=${e.locked}: ${e.message}');
    passed = false;
  }
  try {
    final creds = await AccountStore().load();
    log('keyring: account ${creds == null ? 'not found' : 'found'}');
  } on KeyringException catch (e) {
    log('keyring: account load failed, locked=${e.locked}: ${e.message}');
    passed = false;
  }
  return passed;
}
