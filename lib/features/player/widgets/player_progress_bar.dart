import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

class PlayerProgressBar extends StatelessWidget {
  final double value;
  final double max;
  final ValueChanged<double> onChanged;
  final ProgressBarStyle style;

  const PlayerProgressBar({
    super.key,
    required this.value,
    required this.max,
    required this.onChanged,
    required this.style,
  });

  double get _safeMax => max > 0 ? max : 1.0;

  double get _safeValue => value.clamp(0.0, _safeMax).toDouble();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    switch (style) {
      case ProgressBarStyle.snake:
        return _SnakeProgressBar(
          value: _safeValue,
          max: _safeMax,
          onChanged: onChanged,
          activeColor: scheme.primary,
          inactiveColor: scheme.outlineVariant.withValues(alpha: 0.6),
        );
      case ProgressBarStyle.defaultStyle:
        return Slider(value: _safeValue, max: _safeMax, onChanged: onChanged);
    }
  }
}

class _SnakeProgressBar extends StatelessWidget {
  final double value;
  final double max;
  final ValueChanged<double> onChanged;
  final Color activeColor;
  final Color inactiveColor;

  const _SnakeProgressBar({
    required this.value,
    required this.max,
    required this.onChanged,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    final progress = (value / max).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        double clampX(double x) => x.clamp(0.0, width).toDouble();

        void updateFromX(double x) {
          if (width <= 0) return;
          final fraction = (clampX(x) / width).clamp(0.0, 1.0);
          onChanged((max * fraction).toDouble());
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => updateFromX(details.localPosition.dx),
          onHorizontalDragStart: (details) =>
              updateFromX(details.localPosition.dx),
          onHorizontalDragUpdate: (details) =>
              updateFromX(details.localPosition.dx),
          child: SizedBox(
            height: 42,
            width: double.infinity,
            child: CustomPaint(
              painter: _SnakeProgressPainter(
                progress: progress,
                activeColor: activeColor,
                inactiveColor: inactiveColor,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SnakeProgressPainter extends CustomPainter {
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  const _SnakeProgressPainter({
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 1 || size.height <= 1) return;

    final path = _buildPath(size);
    final iterator = path.computeMetrics().iterator;
    if (!iterator.moveNext()) return;
    final metric = iterator.current;
    if (metric.length <= 0) return;

    final inactivePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = inactiveColor;

    final activePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.6
      ..strokeCap = StrokeCap.round
      ..color = activeColor;

    canvas.drawPath(path, inactivePaint);

    final activeLen = metric.length * progress.clamp(0.0, 1.0);
    final activePath = metric.extractPath(0, activeLen);
    canvas.drawPath(activePath, activePaint);

    final tangent = metric.getTangentForOffset(
      activeLen.clamp(0.0, metric.length),
    );
    if (tangent != null) {
      final headFill = Paint()
        ..style = PaintingStyle.fill
        ..color = activeColor;
      final headOutline = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = inactiveColor.withValues(alpha: 0.7);

      canvas.drawCircle(tangent.position, 8, headFill);
      canvas.drawCircle(tangent.position, 8, headOutline);
    }
  }

  Path _buildPath(Size size) {
    if (size.width <= 8) {
      return Path()
        ..moveTo(0, size.height / 2)
        ..lineTo(size.width, size.height / 2);
    }

    final midY = size.height / 2;
    final left = 4.0;
    final right = math.max(left + 1, size.width - 4.0);
    final usableWidth = right - left;
    final amplitude = size.height * 0.18;
    const cycles = 3.2;
    const steps = 80;

    final path = Path()..moveTo(left, midY);
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final x = left + usableWidth * t;
      final y = midY + math.sin(t * cycles * 2 * math.pi) * amplitude;
      path.lineTo(x, y);
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant _SnakeProgressPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor;
  }
}
