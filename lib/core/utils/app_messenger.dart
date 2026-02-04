import 'package:flutter/material.dart';

class AppMessenger {
  static final GlobalKey<NavigatorState> navigatorKey =
  GlobalKey<NavigatorState>();

  static OverlayEntry? _entry;

  static void show(
      String message, {
        Color? color,
        Duration duration = const Duration(seconds: 2),
      }) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;

    _entry?.remove();

    _entry = OverlayEntry(
      builder: (_) => SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 90, left: 16, right: 16),
            child: _Toast(
              message: message,
              color: color ?? Colors.black.withOpacity(0.85),
            ),
          ),
        ),
      ),
    );

    overlay.insert(_entry!);

    Future.delayed(duration, () {
      _entry?.remove();
      _entry = null;
    });
  }
}

class _Toast extends StatelessWidget {
  final String message;
  final Color color;

  const _Toast({
    required this.message,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          message,
          style: const TextStyle(color: Colors.white),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
