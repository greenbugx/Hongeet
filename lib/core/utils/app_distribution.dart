import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppDistribution {
  static const _channel = MethodChannel('app_distribution');
  static const _izzyFlavor = 'izzy';

  static Future<bool> isStartupUpdateCheckEnabled() async {
    if (kIsWeb) return false;

    if (defaultTargetPlatform == TargetPlatform.windows) {
      return true;
    }

    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }

    try {
      final flavor = await _channel.invokeMethod<String>('flavor');
      final normalized = (flavor ?? '').trim().toLowerCase();
      return normalized != _izzyFlavor;
    } catch (_) {
      return true;
    }
  }
}
