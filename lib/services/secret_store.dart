import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Developer API keys (B1 small fix): kept in Android's encrypted storage
/// instead of second_brain.json. Every call fails soft, so the app still runs
/// where secure storage is unavailable (tests, other platforms).
class SecretStore {
  static const _storage =
      FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static const _apiKey = 'llm_api_key';

  Future<String?> readApiKey() async {
    try {
      return await _storage.read(key: _apiKey);
    } catch (_) {
      return null;
    }
  }

  /// Saves (or, when empty, deletes) the key. False if it could not be stored.
  Future<bool> writeApiKey(String key) async {
    try {
      if (key.isEmpty) {
        await _storage.delete(key: _apiKey);
      } else {
        await _storage.write(key: _apiKey, value: key);
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
