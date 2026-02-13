import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/utils/app_logger.dart';
import '../../core/utils/data_saver_settings.dart';

class YoutubeSongApi {
  static const MethodChannel _channel = MethodChannel('youtube_extractor');
  static const String _headersAssetPath = 'response.json';

  static const Duration _primaryTimeout = Duration(seconds: 16);
  static const Duration _retryTimeout = Duration(seconds: 8);
  static const Duration _urlOnlyTimeout = Duration(seconds: 10);

  static final Map<String, _TimedStreamCache> _streamCache = {};
  static final Map<String, Future<YoutubeExtractedStream>> _inFlight = {};
  static Map<String, String>? _cachedAuthHeaders;

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
    AppLogger.info('Extracting stream via yt-dlp for: $normalized');
    final authHeaders = await _loadAuthHeaders();
    const maxTransientAttempts = 3;
    Object? lastError;

    for (var attempt = 1; attempt <= maxTransientAttempts; attempt++) {
      try {
        final stream = await _extractBestStreamOnce(
          normalized,
          authHeaders,
          dataSaver: dataSaver,
        );

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
    Map<String, String> authHeaders, {
    required bool dataSaver,
  }) async {
    final attempts = <_NativeExtractAttempt>[
      const _NativeExtractAttempt(
        authHeaders: {},
        timeout: _primaryTimeout,
        label: 'no-auth-primary',
      ),
      if (authHeaders.isNotEmpty)
        _NativeExtractAttempt(
          authHeaders: authHeaders,
          timeout: _retryTimeout,
          label: 'auth-fallback',
        ),
      if (authHeaders.isNotEmpty)
        const _NativeExtractAttempt(
          authHeaders: {},
          timeout: _retryTimeout,
          label: 'no-auth-recheck',
        ),
    ];

    Object? lastError;

    for (final attempt in attempts) {
      try {
        final response = await _invokeExtractAudio(
          normalized,
          attempt.authHeaders,
          dataSaver: dataSaver,
          timeout: attempt.timeout,
        );
        final stream = _coerceStream(response);
        if (stream != null) {
          if (attempt.label != 'no-auth-primary') {
            AppLogger.info(
              'Extraction succeeded on ${attempt.label} for $normalized',
            );
          }
          return stream;
        }
        lastError = Exception('No playable stream URL returned');
      } catch (e) {
        lastError = e;
      }
    }

    for (final attempt in attempts) {
      try {
        final url = await _invokeExtractAudioUrl(
          normalized,
          attempt.authHeaders,
          dataSaver: dataSaver,
          timeout: _urlOnlyTimeout,
        );
        if (url != null && url.trim().isNotEmpty) {
          if (attempt.label != 'no-auth-primary') {
            AppLogger.info(
              'URL-only extraction succeeded on ${attempt.label} for $normalized',
            );
          }
          return YoutubeExtractedStream(url.trim(), const {});
        }
        lastError = Exception('No playable stream URL returned');
      } catch (e) {
        lastError = e;
      }
    }

    throw lastError ?? Exception('No playable stream URL returned');
  }

  static Future<dynamic> _invokeExtractAudio(
    String videoId,
    Map<String, String> authHeaders, {
    required bool dataSaver,
    required Duration timeout,
  }) {
    final payload = <String, dynamic>{
      'videoId': videoId,
      'dataSaver': dataSaver,
    };
    if (authHeaders.isNotEmpty) {
      payload['authHeaders'] = authHeaders;
    }
    return _channel
        .invokeMethod<dynamic>('extractAudio', payload)
        .timeout(timeout);
  }

  static Future<String?> _invokeExtractAudioUrl(
    String videoId,
    Map<String, String> authHeaders, {
    required bool dataSaver,
    required Duration timeout,
  }) {
    final payload = <String, dynamic>{
      'videoId': videoId,
      'dataSaver': dataSaver,
    };
    if (authHeaders.isNotEmpty) {
      payload['authHeaders'] = authHeaders;
    }
    return _channel
        .invokeMethod<String>('extractAudioUrl', payload)
        .timeout(timeout);
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

  static YoutubeExtractedStream? _coerceStream(dynamic raw) {
    if (raw == null) return null;

    if (raw is String) {
      final url = raw.trim();
      if (url.isEmpty) return null;
      return YoutubeExtractedStream(url, const {});
    }

    if (raw is! Map) return null;

    final url = (raw['url'] ?? '').toString().trim();
    if (url.isEmpty) return null;

    final headersRaw = raw['headers'];
    final headers = <String, String>{};
    if (headersRaw is Map) {
      for (final entry in headersRaw.entries) {
        final key = entry.key.toString().trim();
        final value = entry.value?.toString().trim() ?? '';
        if (key.isNotEmpty && value.isNotEmpty) {
          headers[key] = value;
        }
      }
    }

    return YoutubeExtractedStream(url, headers);
  }

  static Future<Map<String, String>> _loadAuthHeaders() async {
    if (_cachedAuthHeaders != null) return _cachedAuthHeaders!;

    try {
      final raw = await rootBundle.loadString(_headersAssetPath);
      final headers = _parseAuthHeaders(raw);
      _cachedAuthHeaders = headers;
      return headers;
    } catch (_) {
      _cachedAuthHeaders = const {};
      return const {};
    }
  }

  static Map<String, String> _parseAuthHeaders(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const {};

    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return _normalizeHeaders(
          decoded.map((key, value) => MapEntry('$key', '${value ?? ''}')),
        );
      }
    } catch (_) {
      // Not JSON; continue parsing as raw request headers.
    }

    final headers = <String, String>{};
    final lines = text.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('GET ') ||
          trimmed.startsWith('POST ') ||
          trimmed.startsWith('PUT ') ||
          trimmed.startsWith('DELETE ') ||
          !trimmed.contains(':')) {
        continue;
      }

      final idx = trimmed.indexOf(':');
      final key = trimmed.substring(0, idx).trim();
      final value = trimmed.substring(idx + 1).trim();
      if (key.isEmpty || value.isEmpty) continue;
      headers[key] = value;
    }

    return _normalizeHeaders(headers);
  }

  static Map<String, String> _normalizeHeaders(Map<String, String> headers) {
    final lower = <String, String>{};
    for (final entry in headers.entries) {
      final key = entry.key.trim().toLowerCase();
      final value = entry.value.trim();
      if (key.isEmpty || value.isEmpty) continue;
      lower[key] = value;
    }

    final normalized = <String, String>{};

    void pick(String source, String target) {
      final value = lower[source];
      if (value != null && value.isNotEmpty) {
        normalized[target] = value;
      }
    }

    pick('cookie', 'Cookie');
    pick('authorization', 'Authorization');
    pick('user-agent', 'User-Agent');
    pick('accept', 'Accept');
    pick('accept-language', 'Accept-Language');
    pick('x-goog-visitor-id', 'X-Goog-Visitor-Id');
    pick('x-goog-authuser', 'X-Goog-AuthUser');
    pick('x-youtube-client-name', 'X-Youtube-Client-Name');
    pick('x-youtube-client-version', 'X-Youtube-Client-Version');
    pick('x-youtube-bootstrap-logged-in', 'X-Youtube-Bootstrap-Logged-In');
    pick('x-origin', 'X-Origin');
    pick('referer', 'Referer');
    pick('origin', 'Origin');

    if (!normalized.containsKey('Referer')) {
      normalized['Referer'] = 'https://music.youtube.com/';
    }
    if (!normalized.containsKey('Origin')) {
      normalized['Origin'] = 'https://music.youtube.com';
    }
    if (!normalized.containsKey('Accept')) {
      normalized['Accept'] = '*/*';
    }
    if (!normalized.containsKey('Accept-Language')) {
      normalized['Accept-Language'] = 'en-US,en;q=0.9';
    }

    return normalized;
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

class _NativeExtractAttempt {
  final Map<String, String> authHeaders;
  final Duration timeout;
  final String label;

  const _NativeExtractAttempt({
    required this.authHeaders,
    required this.timeout,
    required this.label,
  });
}
