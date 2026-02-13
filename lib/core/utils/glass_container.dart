import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';

class GlassContainer extends StatelessWidget {
  final Widget child;
  final double blur;
  final double opacity;
  final BorderRadius borderRadius;

  const GlassContainer({
    super.key,
    required this.child,
    this.blur = 25,
    this.opacity = 0.12,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
  });

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    if (themeProvider.useGlassTheme) {
      final clampedOpacity = opacity.clamp(0.0, 1.0).toDouble();
      final effectiveBlur = blur.clamp(0.0, 60.0).toDouble();
      if (effectiveBlur <= 0.1) {
        return _buildGlassTint(clampedOpacity);
      }
      return _buildBlurredGlass(effectiveBlur, clampedOpacity);
    } else {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: borderRadius,
        ),
        child: child,
      );
    }
  }

  Widget _buildGlassTint(double clampedOpacity) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: clampedOpacity),
        borderRadius: borderRadius,
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: child,
    );
  }

  Widget _buildBlurredGlass(double effectiveBlur, double clampedOpacity) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: effectiveBlur, sigmaY: effectiveBlur),
        child: _buildGlassTint(clampedOpacity),
      ),
    );
  }
}
