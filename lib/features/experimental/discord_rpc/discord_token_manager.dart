// import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores the Discord user token grabbed from WebView localStorage
class DiscordTokenManager {
  DiscordTokenManager._();

  static const _storage = FlutterSecureStorage();
  static const _userTokenKey = 'discord_rpc_user_token';

  static Future<String?> getUserToken() async {
    // final prefs = await SharedPreferences.getInstance();
    return _storage.read(key: _userTokenKey);
  }

  static Future<void> saveUserToken(String token) async {
    // final prefs = await SharedPreferences.getInstance();
    await _storage.write(key: _userTokenKey, value: token);
  }

  static Future<bool> hasUserToken() async {
    final token = await getUserToken();
    return token != null && token.isNotEmpty;
  }

  /// Wipe token is called when user disables Discord RPC
  static Future<void> clearAll() async {
    // final prefs = await SharedPreferences.getInstance();
    await _storage.delete(key: _userTokenKey);
  }
}
