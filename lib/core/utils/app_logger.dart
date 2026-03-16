import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

class AppLogger {
  static const String _name = 'Hongeet';

  static void info(String message) {
    developer.log(message, name: _name, level: 800);
    if (kDebugMode) debugPrint('[$_name/INFO] $message');
  }

  static void warning(String message, {Object? error, StackTrace? stackTrace}) {
    developer.log(
      message,
      name: _name,
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
    if (kDebugMode) {
      debugPrint('[$_name/WARN] $message');
      if (error != null) debugPrint('  error: $error');
    }
  }

  static void error(String message, {Object? error, StackTrace? stackTrace}) {
    developer.log(
      message,
      name: _name,
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
    if (kDebugMode) {
      debugPrint('[$_name/ERROR] $message');
      if (error != null) debugPrint('  error: $error');
    }
  }
}
