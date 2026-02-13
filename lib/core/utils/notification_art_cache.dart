import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'youtube_thumbnail_utils.dart';

class NotificationArtCache {
  static final Map<String, Future<Uri?>> _inFlight = {};
  static final Map<String, Uri> _memoryCache = {};

  static const int _targetSize = 512;
  static const Duration _downloadTimeout = Duration(seconds: 8);
  static const double _notificationZoomCrop = 1.0;
  static const String _cacheVersion = 'v3_nozoom';

  static Future<Uri?> getSquareArtUri(String imageUrl) async {
    final normalized = imageUrl.trim();
    if (normalized.isEmpty) return null;
    final cacheKey = '$_cacheVersion|$normalized';

    final memo = _memoryCache[cacheKey];
    if (memo != null) {
      final file = File.fromUri(memo);
      if (await file.exists()) return memo;
      _memoryCache.remove(cacheKey);
    }

    final inFlight = _inFlight[cacheKey];
    if (inFlight != null) return inFlight;

    final future = _buildSquareArt(normalized);
    _inFlight[cacheKey] = future;

    try {
      final uri = await future;
      if (uri != null) {
        _memoryCache[cacheKey] = uri;
      }
      return uri;
    } finally {
      if (identical(_inFlight[cacheKey], future)) {
        _inFlight.remove(cacheKey);
      }
    }
  }

  static Future<Uri?> _buildSquareArt(String imageUrl) async {
    try {
      final cacheFile = await _cacheFileFor('$_cacheVersion|$imageUrl');
      if (await cacheFile.exists() && await cacheFile.length() > 0) {
        return cacheFile.uri;
      }

      final candidates = YoutubeThumbnailUtils.candidateUrls(
        imageUrl: imageUrl,
      );
      if (candidates.isEmpty) {
        candidates.add(imageUrl);
      }

      for (final url in candidates) {
        final bytes = await _download(url);
        if (bytes == null || bytes.isEmpty) continue;

        final squareBytes = await _centerCropSquare(bytes);
        if (squareBytes == null || squareBytes.isEmpty) continue;

        await cacheFile.writeAsBytes(squareBytes, flush: true);
        return cacheFile.uri;
      }
    } catch (e) {
      AppLogger.warning('Notification art processing failed: $e', error: e);
    }

    return null;
  }

  static Future<File> _cacheFileFor(String key) async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory(
      '${dir.path}${Platform.pathSeparator}notification_art',
    );
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    final hash = _hashKey(key);
    return File('${cacheDir.path}${Platform.pathSeparator}$hash.png');
  }

  static int _hashKey(String input) {
    var hash = 0;
    for (final unit in input.codeUnits) {
      hash = 0x1fffffff & (hash + unit);
      hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
      hash ^= (hash >> 6);
    }
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash ^= (hash >> 11);
    hash = 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
    return hash;
  }

  static Future<Uint8List?> _download(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return null;

      final response = await http
          .get(
            uri,
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              'Accept': '*/*',
            },
          )
          .timeout(_downloadTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> _centerCropSquare(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      final w = image.width.toDouble();
      final h = image.height.toDouble();
      if (w <= 0 || h <= 0) return null;

      final baseSide = math.min(w, h);
      final side = (baseSide * _notificationZoomCrop).clamp(1.0, baseSide);
      final src = ui.Rect.fromLTWH((w - side) / 2, (h - side) / 2, side, side);
      final dst = ui.Rect.fromLTWH(
        0,
        0,
        _targetSize.toDouble(),
        _targetSize.toDouble(),
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(image, src, dst, ui.Paint());
      final picture = recorder.endRecording();
      final out = await picture.toImage(_targetSize, _targetSize);
      final data = await out.toByteData(format: ui.ImageByteFormat.png);

      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
