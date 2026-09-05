import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where API keys are kept.
///
/// An interface rather than a concrete class so tests, widget tests and the simulator can
/// run against an in-memory implementation — the platform keychain is not available in a
/// test binding, and mocking it would test the mock rather than the flow.
abstract class KeyStore {
  Future<String?> read(String providerId);
  Future<void> write(String providerId, String key);
  Future<void> delete(String providerId);
  Future<bool> has(String providerId);
}

/// API keys, and only API keys.
///
/// Backed by the Keychain on iOS and Keystore-backed EncryptedSharedPreferences on
/// Android. Keys never enter the database, never appear in logs, and are never sent
/// anywhere except the provider the user configured them for — there is no backend for
/// them to leak through.
class SecureKeyStore implements KeyStore {
  const SecureKeyStore([this._storage = _defaultStorage]);

  static const _defaultStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      // Available after first unlock, so a background transcription can continue after
      // a reboot, but never synced to iCloud or restored to another device.
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const String _prefix = 'provider_key.';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String providerId) =>
      _storage.read(key: '$_prefix$providerId');

  @override
  Future<void> write(String providerId, String key) =>
      _storage.write(key: '$_prefix$providerId', value: key);

  @override
  Future<void> delete(String providerId) =>
      _storage.delete(key: '$_prefix$providerId');

  @override
  Future<bool> has(String providerId) async =>
      (await read(providerId))?.isNotEmpty ?? false;

  /// Shown in settings in place of the key itself. The user needs to recognise which key
  /// is stored without the app ever displaying it.
  static String mask(String key) {
    if (key.length <= 8) return '•' * key.length;
    return '${key.substring(0, 3)}${'•' * 8}${key.substring(key.length - 4)}';
  }
}


/// Keys held only for the lifetime of the process. Used by tests, and by the simulator
/// where there is no keychain worth writing to.
class InMemoryKeyStore implements KeyStore {
  final Map<String, String> _keys = {};

  @override
  Future<String?> read(String providerId) async => _keys[providerId];

  @override
  Future<void> write(String providerId, String key) async =>
      _keys[providerId] = key;

  @override
  Future<void> delete(String providerId) async => _keys.remove(providerId);

  @override
  Future<bool> has(String providerId) async =>
      _keys[providerId]?.isNotEmpty ?? false;
}
