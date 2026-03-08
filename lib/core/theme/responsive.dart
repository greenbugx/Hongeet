import 'package:flutter/material.dart';

class ResponsiveLayout {
  static const double compactMaxWidth = 600;
  static const double mediumMaxWidth = 1024;
  static const double expandedMaxContentWidth = 1320;

  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compactMaxWidth;

  static bool isMedium(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width >= compactMaxWidth && width < mediumMaxWidth;
  }

  static bool isExpanded(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= mediumMaxWidth;

  static EdgeInsets pagePadding(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 1280) {
      return const EdgeInsets.symmetric(horizontal: 32, vertical: 22);
    }
    if (width >= mediumMaxWidth) {
      return const EdgeInsets.symmetric(horizontal: 24, vertical: 20);
    }
    if (width >= compactMaxWidth) {
      return const EdgeInsets.symmetric(horizontal: 20, vertical: 18);
    }
    return const EdgeInsets.symmetric(horizontal: 16, vertical: 16);
  }

  static double maxContentWidth(BuildContext context) {
    if (isExpanded(context)) {
      return expandedMaxContentWidth;
    }
    return double.infinity;
  }

  static int adaptiveGridColumns(
    BuildContext context, {
    double minCardWidth = 190,
    int minColumns = 2,
    int maxColumns = 6,
  }) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = (width / minCardWidth).floor();
    return columns.clamp(minColumns, maxColumns);
  }
}
