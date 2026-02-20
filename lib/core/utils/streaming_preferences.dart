import 'package:shared_preferences/shared_preferences.dart';

class StreamingPreferences {
  static bool _streamingEnabled = false;
  static bool get isStreamingEnabled => _streamingEnabled;

  static bool _useYoutube = false;
  static bool _useSaavn = false;
  static bool get useYoutube => _useYoutube;
  static bool get useSaavn => _useSaavn;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _useYoutube = prefs.getBool('use_youtube_service') ?? false;
    _useSaavn = prefs.getBool('use_saavn_service') ?? false;
    _streamingEnabled = _useYoutube || _useSaavn;
  }

  /// Call after user toggles streaming in settings so guards see the new value when they check `isStreamingEnabled`.
  static Future<void> reload() async => load();

  static Future<bool> isStreamingEnabledAsync() async {
    await load();
    return _streamingEnabled;
  }
}
