import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/data_saver_settings.dart';

enum ProgressBarStyle { defaultStyle, snake, glass }

enum UiPerformanceMode { auto, smooth, full }

class AppTheme {
  static ThemeData glassTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.transparent,
    primaryColor: const Color(0xFF1DB954),
    textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Color(0xFF111111),
      selectedItemColor: Color(0xFF1DB954),
      unselectedItemColor: Colors.grey,
      showUnselectedLabels: true,
      type: BottomNavigationBarType.fixed,
    ),
  );

  static ThemeData simpleDarkTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF0D0D0D),
    primaryColor: const Color(0xFF1DB954),
    textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Color(0xFF111111),
      selectedItemColor: Color(0xFF1DB954),
      unselectedItemColor: Colors.grey,
      showUnselectedLabels: true,
      type: BottomNavigationBarType.fixed,
    ),
  );
}

class ThemeProvider with ChangeNotifier {
  static const _useGlassThemeKey = 'use_glass_theme';
  static const _progressBarStyleKey = 'progress_bar_style';
  static const _uiPerformanceModeKey = 'ui_performance_mode';
  static const _dataSaverKey = DataSaverSettings.prefKey;

  bool _useGlassTheme = false;
  bool get useGlassTheme => _useGlassTheme;

  ProgressBarStyle _progressBarStyle = ProgressBarStyle.defaultStyle;
  ProgressBarStyle get progressBarStyle => _progressBarStyle;
  ProgressBarStyle get effectiveProgressBarStyle {
    if (!_useGlassTheme && _progressBarStyle == ProgressBarStyle.glass) {
      return ProgressBarStyle.defaultStyle;
    }
    return _progressBarStyle;
  }

  UiPerformanceMode _uiPerformanceMode = UiPerformanceMode.auto;
  UiPerformanceMode get uiPerformanceMode => _uiPerformanceMode;

  bool _dataSaverEnabled = false;
  bool get dataSaverEnabled => _dataSaverEnabled;

  ThemeData get currentTheme =>
      _useGlassTheme ? AppTheme.glassTheme : AppTheme.simpleDarkTheme;

  ThemeProvider() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    _useGlassTheme = prefs.getBool(_useGlassThemeKey) ?? false;
    final progressRaw =
        prefs.getString(_progressBarStyleKey) ??
        ProgressBarStyle.defaultStyle.name;
    _progressBarStyle = ProgressBarStyle.values.firstWhere(
      (style) => style.name == progressRaw,
      orElse: () => ProgressBarStyle.defaultStyle,
    );
    final perfRaw =
        prefs.getString(_uiPerformanceModeKey) ?? UiPerformanceMode.auto.name;
    _uiPerformanceMode = UiPerformanceMode.values.firstWhere(
      (mode) => mode.name == perfRaw,
      orElse: () => UiPerformanceMode.auto,
    );
    _dataSaverEnabled = prefs.getBool(_dataSaverKey) ?? false;
    DataSaverSettings.setInMemory(_dataSaverEnabled);

    if (!_useGlassTheme && _progressBarStyle == ProgressBarStyle.glass) {
      _progressBarStyle = ProgressBarStyle.defaultStyle;
      await prefs.setString(_progressBarStyleKey, _progressBarStyle.name);
    }
    notifyListeners();
  }

  Future<void> setUseGlassTheme(bool enabled) async {
    if (_useGlassTheme == enabled) return;
    _useGlassTheme = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_useGlassThemeKey, _useGlassTheme);

    if (!_useGlassTheme && _progressBarStyle == ProgressBarStyle.glass) {
      _progressBarStyle = ProgressBarStyle.defaultStyle;
      await prefs.setString(_progressBarStyleKey, _progressBarStyle.name);
    }
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    await setUseGlassTheme(!_useGlassTheme);
  }

  Future<void> setProgressBarStyle(ProgressBarStyle style) async {
    final next = (!_useGlassTheme && style == ProgressBarStyle.glass)
        ? ProgressBarStyle.defaultStyle
        : style;
    if (_progressBarStyle == next) return;

    _progressBarStyle = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_progressBarStyleKey, _progressBarStyle.name);
    notifyListeners();
  }

  Future<void> setUiPerformanceMode(UiPerformanceMode mode) async {
    if (_uiPerformanceMode == mode) return;
    _uiPerformanceMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_uiPerformanceModeKey, _uiPerformanceMode.name);
    notifyListeners();
  }

  Future<void> setDataSaverEnabled(bool enabled) async {
    if (_dataSaverEnabled == enabled) return;
    _dataSaverEnabled = enabled;
    DataSaverSettings.setInMemory(enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_dataSaverKey, enabled);
    notifyListeners();
  }

  static bool isLowEndLikely(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    final dpr = media?.devicePixelRatio ?? 3.0;
    final physicalPixels = media == null
        ? 0.0
        : media.size.width * media.size.height * dpr * dpr;
    return (dpr <= 2.2) ||
        (physicalPixels <= 1800000) ||
        (media?.disableAnimations ?? false);
  }

  UiPerformanceMode resolvedUiPerformanceMode(BuildContext context) {
    if (_useGlassTheme) {
      // Glass mode always renders at full visual strength.
      return UiPerformanceMode.full;
    }

    if (_uiPerformanceMode != UiPerformanceMode.auto) {
      return _uiPerformanceMode;
    }
    return isLowEndLikely(context)
        ? UiPerformanceMode.smooth
        : UiPerformanceMode.full;
  }
}
