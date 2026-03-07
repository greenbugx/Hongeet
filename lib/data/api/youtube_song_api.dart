import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/utils/app_logger.dart';
import '../../core/utils/data_saver_settings.dart';

class YoutubeSongApi {
  static final YoutubeExplode _yt = YoutubeExplode();

  static const Duration _primaryTimeout = Duration(seconds: 14);
  static const Duration _retryTimeout = Duration(seconds: 8);
  static const Duration _streamMemoryTtl = Duration(hours: 1);
  static const Duration _streamPersistFreshTtl = Duration(minutes: 30);
  static const Duration _streamPersistStaleTtl = Duration(hours: 6);
  static const String _streamPersistKey = 'yt_stream_cache_v1';
  static const int _streamPersistMaxEntries = 220;

  static final Map<String, _TimedStreamCache> _streamCache = {};
  static final Map<String, Future<YoutubeExtractedStream>> _inFlight = {};
  static final Map<String, _StrategyHealth> _attemptHealth = {};
  static Future<void> _streamPersistWriteQueue = Future<void>.value();
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
    if (cached != null && !cached.isExpired(_streamMemoryTtl)) {
      return cached.stream;
    }

    final persisted = await _readPersistedStreamEntry(cacheKey);
    final hasPersistedFresh =
        persisted != null && !persisted.isExpired(_streamPersistFreshTtl);
    final hasPersistedStale =
        persisted != null && !persisted.isExpired(_streamPersistStaleTtl);
    final persistedStream = persisted?.stream;

    if (hasPersistedFresh && persistedStream != null) {
      _streamCache[cacheKey] = _TimedStreamCache(persistedStream);
      return persistedStream;
    }

    if (hasPersistedStale && persistedStream != null) {
      _streamCache[cacheKey] = _TimedStreamCache(persistedStream);
      unawaited(
        _refreshStreamInBackground(
          normalized,
          dataSaver: dataSaver,
          cacheKey: cacheKey,
        ),
      );
      return persistedStream;
    }

    final inFlight = _inFlight[cacheKey];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _fetchBestStreamInternal(
      normalized,
      dataSaver: dataSaver,
      fallbackStale: hasPersistedStale ? persistedStream : null,
    );
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
    YoutubeExtractedStream? fallbackStale,
  }) async {
    AppLogger.info('Extracting stream via youtube_explode for: $normalized');
    const maxTransientAttempts = 3;
    Object? lastError;

    for (var attempt = 1; attempt <= maxTransientAttempts; attempt++) {
      try {
        final stream = await _extractBestStreamOnce(normalized, dataSaver);
        await _cacheResolvedStream(
          normalized,
          dataSaver: dataSaver,
          stream: stream,
        );
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

    if (fallbackStale != null) {
      return fallbackStale;
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

  static Future<void> _refreshStreamInBackground(
    String normalized, {
    required bool dataSaver,
    required String cacheKey,
  }) async {
    final inFlight = _inFlight[cacheKey];
    if (inFlight != null) return;

    try {
      await _fetchBestStreamInternal(
        normalized,
        dataSaver: dataSaver,
        fallbackStale: null,
      );
    } catch (_) {
      // Keep stale stream cache when refresh fails.
    }
  }

  static Future<void> _cacheResolvedStream(
    String normalized, {
    required bool dataSaver,
    required YoutubeExtractedStream stream,
  }) async {
    final cacheKey = _cacheKey(normalized, dataSaver: dataSaver);
    _streamCache[cacheKey] = _TimedStreamCache(stream);
    _trimCache(_streamCache, maxEntries: 250);
    await _writePersistedStreamEntry(cacheKey, stream);
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

    final ordered = _orderAttemptsByHealth(attempts);
    Object? lastError;
    for (var i = 0; i < ordered.length; i++) {
      final attempt = ordered[i];
      try {
        final manifest = await _yt.videos.streamsClient
            .getManifest(
              videoId,
              ytClients: attempt.ytClients,
              requireWatchPage: attempt.requireWatchPage,
            )
            .timeout(attempt.timeout);
        _recordAttemptSuccess(attempt.label);
        return manifest;
      } catch (e) {
        lastError = e;
        _recordAttemptFailure(attempt.label, e);
        final hasNext = i < ordered.length - 1;
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

  static List<_ManifestAttempt> _orderAttemptsByHealth(
    List<_ManifestAttempt> attempts,
  ) {
    final available = attempts
        .where((a) => _isAttemptAvailable(a.label))
        .toList(growable: false);
    final base = available.isEmpty ? attempts : available;
    final ordered = List<_ManifestAttempt>.from(base);

    ordered.sort((a, b) {
      final scoreA = _attemptScore(a.label);
      final scoreB = _attemptScore(b.label);
      if ((scoreA - scoreB).abs() >= 0.08) {
        return scoreB.compareTo(scoreA);
      }
      final indexA = attempts.indexOf(a);
      final indexB = attempts.indexOf(b);
      return indexA.compareTo(indexB);
    });

    return ordered;
  }

  static bool _isAttemptAvailable(String label) {
    final health = _attemptHealth[label];
    if (health == null) return true;
    return !health.isCoolingDown;
  }

  static double _attemptScore(String label) {
    final health = _attemptHealth[label];
    if (health == null) return 0.65;
    return health.score;
  }

  static void _recordAttemptSuccess(String label) {
    final health = _attemptHealth.putIfAbsent(label, _StrategyHealth.new);
    health.recordSuccess();
  }

  static void _recordAttemptFailure(String label, Object error) {
    final health = _attemptHealth.putIfAbsent(label, _StrategyHealth.new);
    health.recordFailure(retryable: _isRetryableTransientExtractError(error));
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

  static Future<_PersistedStreamEntry?> _readPersistedStreamEntry(
    String cacheKey,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_streamPersistKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;

      for (final item in decoded) {
        final map = _asMap(item);
        if (map == null) continue;
        final entry = _PersistedStreamEntry.fromJson(map);
        if (entry == null) continue;
        if (entry.key == cacheKey) return entry;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static Future<void> _writePersistedStreamEntry(
    String cacheKey,
    YoutubeExtractedStream stream,
  ) async {
    _streamPersistWriteQueue = _streamPersistWriteQueue.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_streamPersistKey);

        final entries = <String, _PersistedStreamEntry>{};
        if (raw != null && raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            for (final item in decoded) {
              final map = _asMap(item);
              if (map == null) continue;
              final entry = _PersistedStreamEntry.fromJson(map);
              if (entry == null) continue;
              if (entry.isExpired(const Duration(days: 1))) continue;
              entries[entry.key] = entry;
            }
          }
        }

        entries[cacheKey] = _PersistedStreamEntry(
          key: cacheKey,
          timestamp: DateTime.now(),
          stream: stream,
        );

        final sorted = entries.values.toList(growable: false)
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        final trimmed = sorted
            .take(_streamPersistMaxEntries)
            .toList(growable: false);

        final encoded = jsonEncode(
          trimmed.map((e) => e.toJson()).toList(growable: false),
        );
        await prefs.setString(_streamPersistKey, encoded);
      } catch (_) {
        // Ignore persistence errors.
      }
    });

    return _streamPersistWriteQueue;
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      final casted = <String, dynamic>{};
      value.forEach((k, v) {
        casted[k.toString()] = v;
      });
      return casted;
    }
    return null;
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

class _PersistedStreamEntry {
  final String key;
  final DateTime timestamp;
  final YoutubeExtractedStream stream;

  const _PersistedStreamEntry({
    required this.key,
    required this.timestamp,
    required this.stream,
  });

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(timestamp) > ttl;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'key': key,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'url': stream.url,
      'headers': stream.headers,
    };
  }

  static _PersistedStreamEntry? fromJson(Map<String, dynamic> json) {
    final key = (json['key'] ?? '').toString().trim();
    final timestampMs = (json['timestamp'] as num?)?.toInt();
    final url = (json['url'] ?? '').toString().trim();
    if (key.isEmpty || timestampMs == null || timestampMs <= 0 || url.isEmpty) {
      return null;
    }

    final headers = <String, String>{};
    final rawHeaders = YoutubeSongApi._asMap(json['headers']);
    if (rawHeaders != null) {
      rawHeaders.forEach((k, v) {
        headers[k] = v.toString();
      });
    }

    return _PersistedStreamEntry(
      key: key,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
      stream: YoutubeExtractedStream(url, headers),
    );
  }
}

class _StrategyHealth {
  static const int _maxCounter = 600;

  int _successCount = 0;
  int _failureCount = 0;
  int _consecutiveFailures = 0;
  DateTime? _cooldownUntil;

  bool get isCoolingDown {
    final until = _cooldownUntil;
    if (until == null) return false;
    return DateTime.now().isBefore(until);
  }

  double get score {
    final total = _successCount + _failureCount;
    final base = total == 0 ? 0.65 : (_successCount / total);
    final penalty = (_consecutiveFailures * 0.07).clamp(0.0, 0.42);
    return (base - penalty).clamp(0.05, 1.0);
  }

  void recordSuccess() {
    _successCount = (_successCount + 1).clamp(0, _maxCounter);
    _consecutiveFailures = 0;
    _cooldownUntil = null;
    _decayIfNeeded();
  }

  void recordFailure({required bool retryable}) {
    _failureCount = (_failureCount + 1).clamp(0, _maxCounter);
    _consecutiveFailures = (_consecutiveFailures + 1).clamp(0, 8);

    if (retryable && _consecutiveFailures >= 2) {
      final seconds = switch (_consecutiveFailures) {
        2 => 20,
        3 => 45,
        4 => 90,
        5 => 180,
        _ => 300,
      };
      _cooldownUntil = DateTime.now().add(Duration(seconds: seconds));
    }
    _decayIfNeeded();
  }

  void _decayIfNeeded() {
    if (_successCount < _maxCounter && _failureCount < _maxCounter) return;
    _successCount = (_successCount * 0.7).round();
    _failureCount = (_failureCount * 0.7).round();
  }
}
