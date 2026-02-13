import 'package:shared_preferences/shared_preferences.dart';

class DataSaverSettings {
  static const String prefKey = 'data_saver_enabled';

  static bool _enabled = false;
  static bool get isEnabled => _enabled;

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(prefKey) ?? false;
  }

  static Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, enabled);
  }

  static void setInMemory(bool enabled) {
    _enabled = enabled;
  }
}
