import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/utils/app_logger.dart';
import '../../core/utils/data_saver_settings.dart';

class YoutubeSongApi {
  static final YoutubeExplode _yt = YoutubeExplode();

  static const Duration _primaryTimeout = Duration(seconds: 14);
  static const Duration _retryTimeout = Duration(seconds: 8);

  static final Map<String, _TimedStreamCache> _streamCache = {};
  static final Map<String, Future<YoutubeExtractedStream>> _inFlight = {};
  static const Map<String, String> _defaultHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Referer': 'https://www.youtube.com/',
    'Origin': 'https://www.youtube.com',
  };

  static Future<YoutubeExtractedStream> fetchBestStream(String videoId) async {
    final normalized = videoId.trim();
    if (normalized.isEmpty) {
      throw Exception('videoId is required');
    }
    final dataSaver = await _isDataSaverEnabled();
    final cacheKey = _cacheKey(normalized, dataSaver: dataSaver);

    final cached = _streamCache[cacheKey];
    if (cached != null && !cached.isExpired(const Duration(hours: 1))) {
      return cached.stream;
    }

    final inFlight = _inFlight[cacheKey];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _fetchBestStreamInternal(normalized, dataSaver: dataSaver);
    _inFlight[cacheKey] = future;

    try {
      return await future;
    } finally {
      if (identical(_inFlight[cacheKey], future)) {
        _inFlight.remove(cacheKey);
      }
    }
  }

  static Future<String> fetchBestStreamUrl(String videoId) async {
    final stream = await fetchBestStream(videoId);
    return stream.url;
  }

  static Future<YoutubeExtractedStream> _fetchBestStreamInternal(
    String normalized, {
    required bool dataSaver,
  }) async {
    AppLogger.info('Extracting stream via youtube_explode for: $normalized');
    const maxTransientAttempts = 3;
    Object? lastError;

    for (var attempt = 1; attempt <= maxTransientAttempts; attempt++) {
      try {
        final stream = await _extractBestStreamOnce(normalized, dataSaver);

        _streamCache[_cacheKey(normalized, dataSaver: dataSaver)] =
            _TimedStreamCache(stream);
        _trimCache(_streamCache, maxEntries: 250);
        return stream;
      } catch (e, st) {
        lastError = e;
        final retryable = _isRetryableTransientExtractError(e);
        final hasNext = attempt < maxTransientAttempts;

        if (!retryable || !hasNext) {
          rethrow;
        }

        AppLogger.warning(
          'Transient extraction failure (attempt $attempt/$maxTransientAttempts), retrying',
          error: e,
          stackTrace: st,
        );
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      }
    }

    throw lastError ?? Exception('No playable stream URL returned');
  }

  static Future<YoutubeExtractedStream> _extractBestStreamOnce(
    String normalized,
    bool dataSaver,
  ) async {
    final manifest = await _getManifestWithFallback(normalized);
    final selected = _selectAudioStream(manifest, dataSaver: dataSaver);
    final url = selected.url.toString().trim();
    if (url.isEmpty) {
      throw Exception('No playable stream URL returned');
    }
    return YoutubeExtractedStream(url, _defaultHeaders);
  }

  static Future<StreamManifest> _getManifestWithFallback(String videoId) async {
    final attempts = <_ManifestAttempt>[
      const _ManifestAttempt(
        label: 'android-vr-fast',
        ytClients: [YoutubeApiClient.androidVr],
        requireWatchPage: false,
        timeout: _primaryTimeout,
      ),
      const _ManifestAttempt(
        label: 'android-vr-watch-page',
        ytClients: [YoutubeApiClient.androidVr],
        requireWatchPage: true,
        timeout: _retryTimeout,
      ),
      const _ManifestAttempt(
        label: 'android-music',
        ytClients: [YoutubeApiClient.androidMusic],
        requireWatchPage: false,
        timeout: _retryTimeout,
      ),
      const _ManifestAttempt(
        label: 'tv-fallback',
        ytClients: [YoutubeApiClient.tv],
        requireWatchPage: true,
        timeout: _retryTimeout,
      ),
    ];

    Object? lastError;
    for (var i = 0; i < attempts.length; i++) {
      final attempt = attempts[i];
      try {
        return await _yt.videos.streamsClient
            .getManifest(
              videoId,
              ytClients: attempt.ytClients,
              requireWatchPage: attempt.requireWatchPage,
            )
            .timeout(attempt.timeout);
      } catch (e) {
        lastError = e;
        final hasNext = i < attempts.length - 1;
        if (!hasNext) break;
        AppLogger.warning(
          'Extraction fallback after "${attempt.label}": $e',
          error: e,
        );
        await Future.delayed(Duration(milliseconds: 180 * (i + 1)));
      }
    }

    throw lastError ?? Exception('No playable stream URL returned');
  }

  static AudioOnlyStreamInfo _selectAudioStream(
    StreamManifest manifest, {
    required bool dataSaver,
  }) {
    final audioOnly = manifest.audioOnly;
    if (audioOnly.isEmpty) {
      throw Exception('No audio streams available');
    }

    final sorted = audioOnly.sortByBitrate(); // highest to lowest
    final preferredContainer = sorted
        .where(
          (s) =>
              s.container == StreamContainer.mp4 ||
              s.audioCodec.toLowerCase().contains('mp4a'),
        )
        .toList(growable: false);
    final candidates = preferredContainer.isNotEmpty
        ? preferredContainer
        : sorted;

    if (!dataSaver) {
      return candidates.first;
    }

    final capped =
        candidates
            .where((s) => s.bitrate.kiloBitsPerSecond <= 132)
            .toList(growable: false)
          ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    if (capped.isNotEmpty) {
      return capped.first;
    }

    return candidates.last;
  }

  static bool _isRetryableTransientExtractError(Object error) {
    if (error is TimeoutException) return true;

    final lower = error.toString().toLowerCase();
    if (lower.isEmpty) return false;

    const retryableTokens = <String>[
      'failed host lookup',
      'no address associated with hostname',
      'socketexception',
      'transporterror',
      'unable to download api page',
      'network is unreachable',
      'temporary failure in name resolution',
      'connection reset',
      'connection aborted',
      'timed out',
      'timeout',
      'the page needs to be reloaded',
      'page needs to be reloaded',
      'failed to extract any player response',
      'failed to extract player response',
    ];

    return retryableTokens.any(lower.contains);
  }

  static String _cacheKey(String videoId, {required bool dataSaver}) {
    return '$videoId::${dataSaver ? "ds" : "hq"}';
  }

  static Future<bool> _isDataSaverEnabled() async {
    if (DataSaverSettings.isEnabled) return true;
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(DataSaverSettings.prefKey) ?? false;
    DataSaverSettings.setInMemory(enabled);
    return enabled;
  }

  static void _trimCache(
    Map<String, _TimedStreamCache> cache, {
    required int maxEntries,
  }) {
    if (cache.length <= maxEntries) return;
    final keys = cache.keys.toList(growable: false);
    final removeCount = cache.length - maxEntries;
    for (var i = 0; i < removeCount; i++) {
      cache.remove(keys[i]);
    }
  }
}

class YoutubeExtractedStream {
  final String url;
  final Map<String, String> headers;

  const YoutubeExtractedStream(this.url, this.headers);
}

class _TimedStreamCache {
  final DateTime timestamp;
  final YoutubeExtractedStream stream;

  _TimedStreamCache(this.stream) : timestamp = DateTime.now();

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(timestamp) > ttl;
  }
}

class _ManifestAttempt {
  final String label;
  final List<YoutubeApiClient> ytClients;
  final bool requireWatchPage;
  final Duration timeout;

  const _ManifestAttempt({
    required this.label,
    required this.ytClients,
    required this.requireWatchPage,
    required this.timeout,
  });
}
