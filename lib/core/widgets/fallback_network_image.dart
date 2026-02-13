import 'package:flutter/material.dart';

class FallbackNetworkImage extends StatelessWidget {
  final List<String> urls;
  final double? width;
  final double? height;
  final int? cacheWidth;
  final int? cacheHeight;
  final BoxFit fit;
  final Alignment alignment;
  final FilterQuality filterQuality;
  final Widget fallback;

  const FallbackNetworkImage({
    super.key,
    required this.urls,
    required this.fallback,
    this.width,
    this.height,
    this.cacheWidth,
    this.cacheHeight,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.medium,
  });

  @override
  Widget build(BuildContext context) {
    return _buildAt(0);
  }

  Widget _buildAt(int index) {
    if (index >= urls.length) {
      return fallback;
    }

    final url = urls[index].trim();
    if (url.isEmpty) {
      return _buildAt(index + 1);
    }

    return Image.network(
      url,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      fit: fit,
      alignment: alignment,
      filterQuality: filterQuality,
      errorBuilder: (context, error, stackTrace) => _buildAt(index + 1),
    );
  }
}
