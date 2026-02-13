import 'dart:io';
import 'package:flutter/services.dart';

class BatteryOptimizationHelper {
  static const _channel = MethodChannel('battery_optimization');

  static Future<bool> isIgnoringOptimizations() async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod('isIgnoring');
  }

  static Future<bool> requestDisableOptimization() async {
    if (!Platform.isAndroid) return true;
    final launched = await _channel.invokeMethod<dynamic>('request');
    if (launched is bool) return launched;
    return true;
  }

  static Future<String> getManufacturer() async {
    return await _channel.invokeMethod('manufacturer');
  }

  static bool isAggressiveOEM(String m) {
    final o = m.toLowerCase();
    return o.contains('xiaomi') ||
        o.contains('redmi') ||
        o.contains('poco') ||
        o.contains('oppo') ||
        o.contains('vivo') ||
        o.contains('realme') ||
        o.contains('huawei');
  }
}
