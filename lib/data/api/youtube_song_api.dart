import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

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

    final cached = _streamCache[normalized];
    if (cached != null && !cached.isExpired(const Duration(hours: 1))) {
      return cached.stream;
    }

    final inFlight = _inFlight[normalized];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _fetchBestStreamInternal(normalized);
    _inFlight[normalized] = future;

    try {
      return await future;
    } finally {
      if (identical(_inFlight[normalized], future)) {
        _inFlight.remove(normalized);
      }
    }
  }

  static Future<String> fetchBestStreamUrl(String videoId) async {
    final stream = await fetchBestStream(videoId);
    return stream.url;
  }

  static Future<YoutubeExtractedStream> _fetchBestStreamInternal(
    String normalized,
  ) async {
    print('Extracting stream via yt-dlp for: $normalized');
    final authHeaders = await _loadAuthHeaders();

    dynamic response;
    try {
      response = await _invokeExtractAudio(
        normalized,
        authHeaders,
        timeout: _primaryTimeout,
      );
    } on TimeoutException {
      if (authHeaders.isEmpty) rethrow;
      response = await _invokeExtractAudio(
        normalized,
        const {},
        timeout: _retryTimeout,
      );
    } on PlatformException catch (e) {
      if (authHeaders.isEmpty || !_isAuthRetryableError(e)) rethrow;
      response = await _invokeExtractAudio(
        normalized,
        const {},
        timeout: _retryTimeout,
      );
    }

    var stream = _coerceStream(response);
    if (stream == null) {
      final url = await _invokeExtractAudioUrl(
        normalized,
        authHeaders,
        timeout: _urlOnlyTimeout,
      );
      if (url == null || url.trim().isEmpty) {
        throw Exception('No playable stream URL returned');
      }
      stream = YoutubeExtractedStream(url.trim(), const {});
    }

    _streamCache[normalized] = _TimedStreamCache(stream);
    _trimCache(_streamCache, maxEntries: 250);
    return stream;
  }

  static Future<dynamic> _invokeExtractAudio(
    String videoId,
    Map<String, String> authHeaders, {
    required Duration timeout,
  }) {
    final payload = <String, dynamic>{'videoId': videoId};
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
    required Duration timeout,
  }) {
    final payload = <String, dynamic>{'videoId': videoId};
    if (authHeaders.isNotEmpty) {
      payload['authHeaders'] = authHeaders;
    }
    return _channel
        .invokeMethod<String>('extractAudioUrl', payload)
        .timeout(timeout);
  }

  static bool _isAuthRetryableError(PlatformException e) {
    final raw = '${e.code} ${e.message ?? ''}';
    final lower = raw.toLowerCase();
    return lower.contains('403') ||
        lower.contains('forbidden') ||
        lower.contains('access denied') ||
        lower.contains('http error 401') ||
        lower.contains('unauthorized');
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
