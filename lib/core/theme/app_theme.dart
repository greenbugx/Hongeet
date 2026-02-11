import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppTheme {
  static ThemeData glassTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.transparent,
    primaryColor: const Color(0xFF1DB954),
    textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
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
    textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
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

  bool _useGlassTheme = false;
  bool get useGlassTheme => _useGlassTheme;

  ThemeData get currentTheme =>
      _useGlassTheme ? AppTheme.glassTheme : AppTheme.simpleDarkTheme;

  ThemeProvider() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    _useGlassTheme = prefs.getBool(_useGlassThemeKey) ?? true;
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    _useGlassTheme = !_useGlassTheme;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_useGlassThemeKey, _useGlassTheme);
    notifyListeners();
  }
}
