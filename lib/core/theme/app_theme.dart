import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/data_saver_settings.dart';

enum ProgressBarStyle { defaultStyle, snake }

enum UiPerformanceMode { auto, smooth, full }

class AppTheme {
  static const Color defaultSeedColor = Color(0xFF28C76F);

  static ThemeData buildTheme({required Color seedColor}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    );

    final textTheme = Typography.material2021(
      platform: TargetPlatform.android,
    ).white.apply(fontFamily: 'Inter');

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      fontFamily: 'Inter',
      textTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: scheme.secondaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final isSelected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected ? scheme.onSecondaryContainer : scheme.onSurface,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(
          color: scheme.onSurface.withValues(alpha: 0.7),
        ),
        selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: textTheme.labelMedium,
        indicatorColor: scheme.secondaryContainer,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.3),
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.86),
        ),
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
        side: WidgetStatePropertyAll(
          BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        hintStyle: WidgetStatePropertyAll(
          textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant.withValues(alpha: 0.86),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        titleTextStyle: textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        subtitleTextStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        behavior: SnackBarBehavior.floating,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surfaceContainerHigh,
        backgroundColor: scheme.surfaceContainerHigh,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.onPrimary;
          }
          return scheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return scheme.primary;
          }
          return scheme.surfaceContainerHighest;
        }),
      ),
    );

    return base;
  }
}

class ThemeProvider with ChangeNotifier {
  static const _seedColorKey = 'theme_seed_color';
  static const _legacyUseGlassThemeKey = 'use_glass_theme';
  static const _progressBarStyleKey = 'progress_bar_style';
  static const _uiPerformanceModeKey = 'ui_performance_mode';
  static const _dataSaverKey = DataSaverSettings.prefKey;

  // Kept only for backwards compatibility with older UI branches
  bool get useGlassTheme => false;

  Color _seedColor = AppTheme.defaultSeedColor;
  Color get seedColor => _seedColor;

  ProgressBarStyle _progressBarStyle = ProgressBarStyle.defaultStyle;
  ProgressBarStyle get progressBarStyle => _progressBarStyle;
  ProgressBarStyle get effectiveProgressBarStyle => _progressBarStyle;

  UiPerformanceMode _uiPerformanceMode = UiPerformanceMode.auto;
  UiPerformanceMode get uiPerformanceMode => _uiPerformanceMode;

  bool _dataSaverEnabled = false;
  bool get dataSaverEnabled => _dataSaverEnabled;

  ThemeData get currentTheme => AppTheme.buildTheme(seedColor: _seedColor);

  ThemeProvider() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyUseGlassThemeKey);
    final storedSeed = prefs.getInt(_seedColorKey);
    _seedColor = storedSeed == null
        ? AppTheme.defaultSeedColor
        : Color(storedSeed);

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
    notifyListeners();
  }

  Future<void> setSeedColor(Color color) async {
    if (_seedColor.toARGB32() == color.toARGB32()) return;
    _seedColor = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_seedColorKey, color.toARGB32());
    notifyListeners();
  }

  @Deprecated('Glass theme has been removed')
  Future<void> setUseGlassTheme(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyUseGlassThemeKey);
  }

  @Deprecated('Glass theme has been removed')
  Future<void> toggleTheme() async {
    await setUseGlassTheme(false);
  }

  Future<void> setProgressBarStyle(ProgressBarStyle style) async {
    if (_progressBarStyle == style) return;
    _progressBarStyle = style;
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
    if (_uiPerformanceMode != UiPerformanceMode.auto) {
      return _uiPerformanceMode;
    }
    return isLowEndLikely(context)
        ? UiPerformanceMode.smooth
        : UiPerformanceMode.full;
  }
}
