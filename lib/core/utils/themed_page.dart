import 'package:flutter/material.dart';
import '../theme/responsive.dart';

class ThemedPage extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const ThemedPage({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usesDefaultPadding = padding == const EdgeInsets.all(16);
    final effectivePadding = usesDefaultPadding
        ? ResponsiveLayout.pagePadding(context)
        : padding;
    final maxWidth = ResponsiveLayout.maxContentWidth(context);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.surface, scheme.surfaceContainerLowest],
          ),
        ),
        child: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Padding(padding: effectivePadding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}
