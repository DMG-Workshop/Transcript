import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// API keys, and only API keys.
///
/// Backed by the Keychain on iOS and Keystore-backed EncryptedSharedPreferences on
/// Android. Keys never enter the database, never appear in logs, and are never sent
/// anywhere except the provider the user configured them for — there is no backend for
/// them to leak through.
class SecureKeyStore {
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

  Future<String?> read(String providerId) =>
      _storage.read(key: '$_prefix$providerId');

  Future<void> write(String providerId, String key) =>
      _storage.write(key: '$_prefix$providerId', value: key);

  Future<void> delete(String providerId) =>
      _storage.delete(key: '$_prefix$providerId');

  Future<bool> has(String providerId) async =>
      (await read(providerId))?.isNotEmpty ?? false;

  /// Shown in settings in place of the key itself. The user needs to recognise which key
  /// is stored without the app ever displaying it.
  static String mask(String key) {
    if (key.length <= 8) return '•' * key.length;
    return '${key.substring(0, 3)}${'•' * 8}${key.substring(key.length - 4)}';
  }
}
