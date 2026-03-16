import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/utils/youtube_thumbnail_utils.dart';
import '../models/saavn_song.dart';

class YoutubeApi {
  static final YoutubeExplode _yt = YoutubeExplode();

  static const Duration _searchTimeout = Duration(seconds: 10);
  static const Duration _searchFallbackTimeout = Duration(seconds: 7);
  static const Duration _relatedTimeout = Duration(seconds: 10);
  static const Duration _relatedFallbackTimeout = Duration(seconds: 8);
  static const Duration _chartsTimeout = Duration(seconds: 10);
  static const Duration _chartSongsTimeout = Duration(seconds: 12);
  static const Duration _ytmBootstrapTimeout = Duration(seconds: 6);
  static const Duration _ytmSearchTimeout = Duration(seconds: 8);
  static const Duration _ytmContinuationTimeout = Duration(seconds: 7);

  static const String _ytmSongsParams = 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D';
  static const String _ytmClientNameHeader = '67';
  static const String _ytmClientNameBody = 'WEB_REMIX';
  static const String _fallbackYtmApiKey =
      'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
  static const String _fallbackYtmClientVersion = '1.20260101.00.00';
  static const String _ytmUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';
  static const Duration _ytmBootstrapTtl = Duration(hours: 6);
  static const int _maxYtmPages = 3;
  static const int _maxChartArtworkFallbackLookups = 10;
  static const Duration _trendingAlbumsCacheTtl = Duration(minutes: 20);
  static const Duration _searchMemoryTtl = Duration(minutes: 2);
  static const Duration _searchPersistFreshTtl = Duration(minutes: 8);
  static const Duration _searchPersistStaleTtl = Duration(hours: 24);
  static const String _searchPersistKey = 'yt_search_cache_v1';
  static const int _searchPersistMaxEntries = 90;
  static const String _strategyYtmStrict = 'ytm_strict';
  static const String _strategyYtmRelaxed = 'ytm_relaxed';
  static const String _strategyYtExplode = 'yt_explode';

  static final Map<String, _TimedSongsCache> _searchCache = {};
  static final Map<String, _TimedSongsCache> _relatedCache = {};
  static final Map<String, _TimedChartsCache> _chartsCache = {};
  static final Map<String, _TimedSongsCache> _chartSongsCache = {};
  static final Map<String, _TimedAlbumsCache> _albumsCache = {};
  static final Map<String, _TimedArtistsCache> _artistsCache = {};
  static final Map<String, _TimedSongsCache> _artistSongsCache = {};
  static final Map<String, _TimedArtistProfileCache> _artistProfileCache = {};
  static final Map<String, String> _sessionSongArtworkOverrides = {};
  static final Map<String, _StrategyHealth> _searchStrategyHealth = {};
  static Future<void> _searchPersistWriteQueue = Future<void>.value();
  static const int _maxSessionSongArtworkOverrides = 2000;
  static _YtmBootstrapCache? _ytmBootstrapCache;
  static Future<_YtmBootstrapCache>? _ytmBootstrapInFlight;

  static Future<List<SaavnSong>> searchSongs(
    String query, {
    int take = 24,
    bool forceRefresh = false,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];

    final safeTake = take.clamp(2, 50);
    final cacheKey = '${normalized.toLowerCase()}::$safeTake';
    final artistQuery = _isLikelyArtistQuery(normalized);
    final effectiveQuery = _buildMusicSearchQuery(normalized);

    if (!forceRefresh) {
      final cached = _searchCache[cacheKey];
      if (cached != null && !cached.isExpired(_searchMemoryTtl)) {
        return cached.songs;
      }
    }

    final persisted = await _readPersistedSearchEntry(cacheKey);
    final persistedSongs =
        persisted?.limitedSongs(safeTake) ?? const <SaavnSong>[];
    final hasPersistedSongs = persistedSongs.isNotEmpty;
    final persistedIsUsableStale =
        persisted != null && persisted.age <= _searchPersistStaleTtl;

    if (!forceRefresh && hasPersistedSongs && persisted != null) {
      _searchCache[cacheKey] = _TimedSongsCache(persistedSongs);

      if (persisted.age <= _searchPersistFreshTtl) {
        if (persisted.age > _searchMemoryTtl) {
          unawaited(
            _refreshSearchCacheInBackground(
              cacheKey: cacheKey,
              query: normalized,
              effectiveQuery: effectiveQuery,
              artistQuery: artistQuery,
              safeTake: safeTake,
            ),
          );
        }
        return persistedSongs;
      }

      if (persistedIsUsableStale) {
        unawaited(
          _refreshSearchCacheInBackground(
            cacheKey: cacheKey,
            query: normalized,
            effectiveQuery: effectiveQuery,
            artistQuery: artistQuery,
            safeTake: safeTake,
          ),
        );
        return persistedSongs;
      }
    }

    try {
      final songs = await _searchSongsFromNetwork(
        query: normalized,
        effectiveQuery: effectiveQuery,
        artistQuery: artistQuery,
        safeTake: safeTake,
      );
      final immutable = List<SaavnSong>.unmodifiable(songs);
      _searchCache[cacheKey] = _TimedSongsCache(immutable);
      _trimCache(_searchCache, maxEntries: 60);
      await _writePersistedSearchEntry(cacheKey, immutable);
      return immutable;
    } catch (_) {
      if (hasPersistedSongs && persistedIsUsableStale) {
        _searchCache[cacheKey] = _TimedSongsCache(persistedSongs);
        return persistedSongs;
      }
      rethrow;
    }
  }

  static Future<List<SaavnSong>> _searchSongsFromNetwork({
    required String query,
    required String effectiveQuery,
    required bool artistQuery,
    required int safeTake,
  }) async {
    final plan = _buildSearchStrategyPlan();
    List<SaavnSong> ytmSongs = const [];
    List<SaavnSong> fallbackSongs = const [];
    Object? lastError;

    for (final strategy in plan) {
      if (strategy == _strategyYtmStrict && ytmSongs.isEmpty) {
        try {
          final songs = await _searchViaYtm(query: query, take: safeTake);
          if (songs.isNotEmpty) {
            _recordSearchStrategySuccess(strategy);
            ytmSongs = songs;
            break;
          }
          _recordSearchStrategyFailure(strategy, StateError('empty result'));
        } catch (e) {
          _recordSearchStrategyFailure(strategy, e);
          lastError ??= e;
        }
      } else if (strategy == _strategyYtmRelaxed && ytmSongs.isEmpty) {
        try {
          final songs = await _searchViaYtm(
            query: query,
            take: safeTake,
            useSongsParams: false,
            requireSongsShelf: false,
          );
          if (songs.isNotEmpty) {
            _recordSearchStrategySuccess(strategy);
            ytmSongs = songs;
            break;
          }
          _recordSearchStrategyFailure(strategy, StateError('empty result'));
        } catch (e) {
          _recordSearchStrategyFailure(strategy, e);
          lastError ??= e;
        }
      } else if (strategy == _strategyYtExplode && ytmSongs.isEmpty) {
        try {
          fallbackSongs = await _searchViaYoutubeExplodeWithFallback(
            query: effectiveQuery,
            originalQuery: query,
            artistQuery: artistQuery,
            take: safeTake,
          );
          if (fallbackSongs.isNotEmpty) {
            _recordSearchStrategySuccess(strategy);
            break;
          }
          _recordSearchStrategyFailure(strategy, StateError('empty result'));
        } catch (e) {
          _recordSearchStrategyFailure(strategy, e);
          lastError ??= e;
        }
      }
    }

    final songs = _mergeWithDedup(ytmSongs, fallbackSongs, safeTake);
    if (songs.isEmpty && lastError != null) {
      throw lastError;
    }
    return songs;
  }

  static Future<List<YtmAlbum>> searchAlbums(
    String query, {
    int take = 10,
    bool forceRefresh = false,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];

    final safeTake = take.clamp(1, 20);
    final cacheKey =
        'ytm_search_albums::${normalized.toLowerCase()}::$safeTake';

    if (!forceRefresh) {
      final cached = _albumsCache[cacheKey];
      if (cached != null && !cached.isExpired(const Duration(minutes: 15))) {
        return cached.albums;
      }
    }

    _YtmBootstrapCache? bootstrap;
    try {
      bootstrap = await _getYtmBootstrap();
    } catch (_) {
      bootstrap = null;
    }
    if (bootstrap == null) return const [];

    final out = <YtmAlbum>[];
    final seen = <String>{};
    void append(List<YtmAlbum> albums) {
      for (final album in albums) {
        final key = album.browseId.toLowerCase();
        if (!seen.add(key)) continue;
        out.add(album);
        if (out.length >= safeTake) break;
      }
    }

    final queries = <String>[
      normalized,
      '$normalized album',
      '$normalized full album',
      '$normalized soundtrack',
    ];
    final seenQueries = <String>{};
    for (final q in queries) {
      if (out.length >= safeTake) break;
      final trimmed = q.trim();
      if (trimmed.isEmpty) continue;
      if (!seenQueries.add(trimmed.toLowerCase())) continue;
      try {
        final batch = await _searchAlbumsViaYtm(
          bootstrap: bootstrap,
          query: trimmed,
          take: safeTake,
        );
        append(batch);
      } catch (_) {
        continue;
      }
    }

    if (out.length < safeTake) {
      try {
        append(
          await _searchAlbumsViaYoutubePlaylists(
            query: normalized,
            take: safeTake,
          ),
        );
      } catch (_) {
        // Keep YTM-only results if playlist fallback fails.
      }
    }

    final immutable = List<YtmAlbum>.unmodifiable(
      out.take(safeTake).toList(growable: false),
    );
    if (immutable.isNotEmpty) {
      _albumsCache[cacheKey] = _TimedAlbumsCache(immutable);
      _trimAlbumsCache(maxEntries: 140);
    } else {
      _albumsCache.remove(cacheKey);
    }
    return immutable;
  }

  static String extractArtistBrowseId(String browseIdOrUrl) {
    final raw = browseIdOrUrl.trim();
    if (raw.isEmpty) return '';

    final uri = Uri.tryParse(raw);
    if (uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.pathSegments.isNotEmpty) {
      final segments = uri.pathSegments;
      if (segments.length >= 2 && segments.first.toLowerCase() == 'channel') {
        return segments[1].trim();
      }
      if (segments.length >= 2 && segments.first.toLowerCase() == 'browse') {
        return segments[1].trim();
      }
      if (segments.isNotEmpty) {
        return segments.last.trim();
      }
    }

    return raw;
  }

  static Future<List<YtmArtist>> searchArtists(
    String query, {
    int take = 8,
    bool forceRefresh = false,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];

    final safeTake = take.clamp(1, 30);
    final cacheKey =
        'ytm_search_artists::${normalized.toLowerCase()}::$safeTake';

    if (!forceRefresh) {
      final cached = _artistsCache[cacheKey];
      if (cached != null && !cached.isExpired(const Duration(minutes: 15))) {
        return cached.artists;
      }
    }

    final out = <YtmArtist>[];
    final seen = <String>{};
    void append(List<YtmArtist> artists) {
      for (final artist in artists) {
        final key = artist.browseId.toLowerCase();
        if (!seen.add(key)) continue;
        out.add(artist);
        if (out.length >= safeTake) break;
      }
    }

    _YtmBootstrapCache? bootstrap;
    try {
      bootstrap = await _getYtmBootstrap();
    } catch (_) {
      bootstrap = null;
    }

    if (bootstrap != null) {
      final queries = <String>[
        normalized,
        '$normalized artist',
        '$normalized official artist',
        '$normalized topic',
      ];
      final seenQueries = <String>{};
      for (final q in queries) {
        if (out.length >= safeTake) break;
        final trimmed = q.trim();
        if (trimmed.isEmpty) continue;
        if (!seenQueries.add(trimmed.toLowerCase())) continue;

        try {
          final payload = await _postYtmSearch(
            bootstrap: bootstrap,
            query: trimmed,
            useSongsParams: false,
            timeout: _ytmSearchTimeout,
          );
          final parsed = _parseYtmArtistsFromSearchResults(
            payload,
            take: safeTake * 2,
          );
          append(parsed);
        } catch (_) {
          continue;
        }
      }
    }

    if (out.length < safeTake) {
      try {
        append(
          await _searchArtistsViaYoutubeExplode(
            query: normalized,
            take: safeTake,
          ),
        );
      } catch (_) {
        // Keep current list if fallback fails.
      }
    }

    final immutable = List<YtmArtist>.unmodifiable(
      out.take(safeTake).toList(growable: false),
    );
    if (immutable.isNotEmpty) {
      _artistsCache[cacheKey] = _TimedArtistsCache(immutable);
      _trimArtistsCache(maxEntries: 140);
    } else {
      _artistsCache.remove(cacheKey);
    }
    return immutable;
  }

  static Future<YtmArtistProfile> artistProfile(
    String artistBrowseIdOrUrl, {
    String? artistName,
    int topSongsTake = 24,
    int releasesTake = 20,
    bool forceRefresh = false,
  }) async {
    var browseId = extractArtistBrowseId(artistBrowseIdOrUrl);
    var resolvedArtistName = artistName?.trim() ?? '';

    if (browseId.isEmpty && resolvedArtistName.isEmpty) {
      throw StateError('Missing artist identity');
    }

    if (browseId.isEmpty && resolvedArtistName.isNotEmpty) {
      final candidates = await searchArtists(
        resolvedArtistName,
        take: 6,
        forceRefresh: forceRefresh,
      );
      if (candidates.isNotEmpty) {
        final best = _pickBestArtistCandidate(candidates, resolvedArtistName);
        browseId = best.browseId;
        resolvedArtistName = best.name;
      }
    }

    if (browseId.isEmpty) {
      if (resolvedArtistName.isNotEmpty) {
        return _fallbackArtistProfileByName(
          resolvedArtistName,
          take: safeClamp(topSongsTake, 6, 60),
          forceRefresh: forceRefresh,
        );
      }
      throw StateError('Artist profile not found');
    }

    final safeSongsTake = safeClamp(topSongsTake, 6, 60);
    final safeReleasesTake = releasesTake.clamp(6, 60);
    final cacheKey =
        '${browseId.toLowerCase()}::$safeSongsTake::$safeReleasesTake';

    if (!forceRefresh) {
      final cached = _artistProfileCache[cacheKey];
      if (cached != null && !cached.isExpired(const Duration(minutes: 20))) {
        return cached.profile;
      }
    }

    Map<String, dynamic>? payload;
    try {
      final bootstrap = await _getYtmBootstrap();
      payload = await _postYtmBrowse(
        bootstrap: bootstrap,
        browseId: browseId,
        timeout: _chartSongsTimeout,
      );
    } catch (_) {
      payload = null;
    }

    final header = payload == null
        ? _ArtistHeaderResult(
            name: resolvedArtistName,
            imageUrl: '',
            bio: '',
            monthlyAudience: '',
          )
        : _parseArtistHeader(payload, fallbackName: resolvedArtistName);

    List<SaavnSong> topSongs = payload == null
        ? const <SaavnSong>[]
        : _extractSongsFromPayload(payload, take: safeSongsTake);
    if (topSongs.isEmpty) {
      try {
        topSongs = await artistSongs(
          browseId,
          artistName: header.name.isNotEmpty ? header.name : resolvedArtistName,
          take: safeSongsTake,
          forceRefresh: forceRefresh,
        );
      } catch (_) {
        topSongs = const <SaavnSong>[];
      }
    }

    final albums = payload == null
        ? const <YtmAlbum>[]
        : _parseArtistReleasesFromShelves(
            payload,
            take: safeReleasesTake,
            section: _ArtistReleaseSection.albums,
          );
    final singlesAndEps = payload == null
        ? const <YtmAlbum>[]
        : _parseArtistReleasesFromShelves(
            payload,
            take: safeReleasesTake,
            section: _ArtistReleaseSection.singlesAndEps,
          );

    final profile = YtmArtistProfile(
      browseId: browseId,
      name: header.name.isNotEmpty
          ? header.name
          : (resolvedArtistName.isNotEmpty ? resolvedArtistName : browseId),
      imageUrl: header.imageUrl,
      bio: header.bio,
      monthlyAudience: header.monthlyAudience,
      topSongs: List<SaavnSong>.unmodifiable(topSongs),
      albums: List<YtmAlbum>.unmodifiable(albums),
      singlesAndEps: List<YtmAlbum>.unmodifiable(singlesAndEps),
    );

    _artistProfileCache[cacheKey] = _TimedArtistProfileCache(profile);
    _trimArtistProfileCache(maxEntries: 80);
    return profile;
  }

  static int safeClamp(int value, int min, int max) {
    return value < min ? min : (value > max ? max : value);
  }

  static Future<YtmArtistProfile> _fallbackArtistProfileByName(
    String artistName, {
    required int take,
    required bool forceRefresh,
  }) async {
    List<SaavnSong> songs = const <SaavnSong>[];
    try {
      songs = await searchSongs(
        artistName,
        take: take,
        forceRefresh: forceRefresh,
      );
    } catch (_) {
      songs = const <SaavnSong>[];
    }

    var imageUrl = '';
    if (songs.isNotEmpty) {
      imageUrl = songs.first.imageUrl;
    }

    return YtmArtistProfile(
      browseId: '',
      name: artistName,
      imageUrl: imageUrl,
      bio: '',
      monthlyAudience: '',
      topSongs: List<SaavnSong>.unmodifiable(songs),
      albums: const <YtmAlbum>[],
      singlesAndEps: const <YtmAlbum>[],
    );
  }

  static Future<void> _refreshSearchCacheInBackground({
    required String cacheKey,
    required String query,
    required String effectiveQuery,
    required bool artistQuery,
    required int safeTake,
  }) async {
    try {
      final songs = await _searchSongsFromNetwork(
        query: query,
        effectiveQuery: effectiveQuery,
        artistQuery: artistQuery,
        safeTake: safeTake,
      );
      if (songs.isEmpty) return;

      final immutable = List<SaavnSong>.unmodifiable(songs);
      _searchCache[cacheKey] = _TimedSongsCache(immutable);
      _trimCache(_searchCache, maxEntries: 60);
      await _writePersistedSearchEntry(cacheKey, immutable);
    } catch (_) {
      // Keep stale cache in place when refresh fails.
    }
  }

  static List<String> _buildSearchStrategyPlan() {
    final ytm = <String>[];
    if (_isSearchStrategyAvailable(_strategyYtmStrict)) {
      ytm.add(_strategyYtmStrict);
    }
    if (_isSearchStrategyAvailable(_strategyYtmRelaxed)) {
      ytm.add(_strategyYtmRelaxed);
    }

    if (ytm.length == 2) {
      final strictScore = _searchStrategyScore(_strategyYtmStrict);
      final relaxedScore = _searchStrategyScore(_strategyYtmRelaxed);
      if (relaxedScore > strictScore + 0.1) {
        ytm
          ..clear()
          ..add(_strategyYtmRelaxed)
          ..add(_strategyYtmStrict);
      }
    }

    final plan = <String>[...ytm];
    final explodeAvailable = _isSearchStrategyAvailable(_strategyYtExplode);
    if (explodeAvailable || plan.isNotEmpty) {
      plan.add(_strategyYtExplode);
    }

    if (plan.isEmpty) {
      return const <String>[
        _strategyYtmStrict,
        _strategyYtmRelaxed,
        _strategyYtExplode,
      ];
    }
    return plan;
  }

  static bool _isSearchStrategyAvailable(String strategy) {
    final health = _searchStrategyHealth[strategy];
    if (health == null) return true;
    return !health.isCoolingDown;
  }

  static double _searchStrategyScore(String strategy) {
    final health = _searchStrategyHealth[strategy];
    if (health == null) return 0.65;
    return health.score;
  }

  static void _recordSearchStrategySuccess(String strategy) {
    final health = _searchStrategyHealth.putIfAbsent(
      strategy,
      _StrategyHealth.new,
    );
    health.recordSuccess();
  }

  static void _recordSearchStrategyFailure(String strategy, Object error) {
    final health = _searchStrategyHealth.putIfAbsent(
      strategy,
      _StrategyHealth.new,
    );
    health.recordFailure(retryable: _isRetryableStrategyError(error));
  }

  static bool _isRetryableStrategyError(Object error) {
    if (error is TimeoutException) return true;
    final lower = error.toString().toLowerCase();
    if (lower.isEmpty) return false;

    const retryableTokens = <String>[
      'timeout',
      'timed out',
      'socketexception',
      'failed host lookup',
      'connection reset',
      'connection aborted',
      '429',
      'too many requests',
      '503',
      'temporarily unavailable',
      'network',
    ];
    return retryableTokens.any(lower.contains);
  }

  static Future<_PersistedSearchEntry?> _readPersistedSearchEntry(
    String cacheKey,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_searchPersistKey);
      if (raw == null || raw.trim().isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;

      for (final item in decoded) {
        final map = _asMap(item);
        if (map == null) continue;
        final entry = _PersistedSearchEntry.fromJson(map);
        if (entry == null) continue;
        if (entry.key == cacheKey) return entry;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static Future<void> _writePersistedSearchEntry(
    String cacheKey,
    List<SaavnSong> songs,
  ) async {
    if (songs.isEmpty) return;

    _searchPersistWriteQueue = _searchPersistWriteQueue.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_searchPersistKey);

        final entries = <String, _PersistedSearchEntry>{};
        if (raw != null && raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            for (final item in decoded) {
              final map = _asMap(item);
              if (map == null) continue;
              final entry = _PersistedSearchEntry.fromJson(map);
              if (entry == null) continue;
              if (entry.age > const Duration(days: 3)) continue;
              entries[entry.key] = entry;
            }
          }
        }

        entries[cacheKey] = _PersistedSearchEntry(
          key: cacheKey,
          timestamp: DateTime.now(),
          songs: songs.take(50).toList(growable: false),
        );

        final sorted = entries.values.toList(growable: false)
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        final trimmed = sorted
            .take(_searchPersistMaxEntries)
            .toList(growable: false);

        final encoded = jsonEncode(
          trimmed.map((e) => e.toJson()).toList(growable: false),
        );
        await prefs.setString(_searchPersistKey, encoded);
      } catch (_) {
        // Ignore persistence errors.
      }
    });

    return _searchPersistWriteQueue;
  }

  static Future<List<SaavnSong>> _searchViaYtm({
    required String query,
    required int take,
    bool useSongsParams = true,
    bool requireSongsShelf = true,
  }) async {
    final bootstrap = await _getYtmBootstrap();
    final out = <SaavnSong>[];
    final seen = <String>{};

    Map<String, dynamic>? payload = await _postYtmSearch(
      bootstrap: bootstrap,
      query: query,
      useSongsParams: useSongsParams,
      timeout: _ytmSearchTimeout,
    );
    var continuation = '';
    var pageIndex = 0;

    while (payload != null && out.length < take && pageIndex < _maxYtmPages) {
      final page = _extractYtmSongsPage(
        payload,
        initialPage: pageIndex == 0,
        requireSongsShelf: requireSongsShelf,
      );
      for (final song in page.songs) {
        if (!seen.add(song.id)) continue;
        out.add(song);
        if (out.length >= take) break;
      }

      continuation = page.continuation ?? '';
      if (continuation.isEmpty || out.length >= take) break;

      payload = await _postYtmSearch(
        bootstrap: bootstrap,
        query: query,
        continuation: continuation,
        useSongsParams: useSongsParams,
        timeout: _ytmContinuationTimeout,
      );
      pageIndex++;
    }

    return out.take(take).toList(growable: false);
  }

  static String _cleanYtmArtist(String raw) {
    if (raw.isEmpty) return raw;
    // take only what's before the first bullet
    final bulletIndex = raw.indexOf('\u2022'); // •
    final cleaned = bulletIndex >= 0 ? raw.substring(0, bulletIndex) : raw;
    return cleaned.trim().replaceAll(RegExp(r',\s*$'), '').trim();
  }

  static Future<Map<String, dynamic>> _postYtmSearch({
    required _YtmBootstrapCache bootstrap,
    required String query,
    String? continuation,
    required bool useSongsParams,
    required Duration timeout,
  }) async {
    final apiKey = bootstrap.apiKey.isNotEmpty
        ? bootstrap.apiKey
        : _fallbackYtmApiKey;
    final clientVersion = bootstrap.clientVersion.isNotEmpty
        ? bootstrap.clientVersion
        : _fallbackYtmClientVersion;

    final uri = Uri.parse(
      'https://music.youtube.com/youtubei/v1/search?prettyPrint=false&key=$apiKey',
    );

    final client = <String, dynamic>{
      'clientName': _ytmClientNameBody,
      'clientVersion': clientVersion,
      'hl': bootstrap.hl.isNotEmpty ? bootstrap.hl : 'en',
      'gl': bootstrap.gl.isNotEmpty ? bootstrap.gl : 'US',
    };
    if (bootstrap.visitorData.isNotEmpty) {
      client['visitorData'] = bootstrap.visitorData;
    }

    final body = <String, dynamic>{
      'context': <String, dynamic>{'client': client},
    };
    if (continuation != null && continuation.isNotEmpty) {
      body['continuation'] = continuation;
    } else if (useSongsParams) {
      body['query'] = query;
      body['params'] = _ytmSongsParams;
    } else {
      body['query'] = query;
    }

    final headers = <String, String>{
      'Accept': '*/*',
      'Content-Type': 'application/json',
      'Origin': 'https://music.youtube.com',
      'Referer': 'https://music.youtube.com/',
      'User-Agent': _ytmUserAgent,
      'X-Youtube-Client-Name': _ytmClientNameHeader,
      'X-Youtube-Client-Version': clientVersion,
    };
    if (bootstrap.visitorData.isNotEmpty) {
      headers['X-Goog-Visitor-Id'] = bootstrap.visitorData;
    }

    final response = await http
        .post(uri, headers: headers, body: jsonEncode(body))
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw StateError('YTM search failed with HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw StateError('YTM search returned invalid payload');
    }

    return decoded;
  }

  static Future<Map<String, dynamic>> _postYtmBrowse({
    required _YtmBootstrapCache bootstrap,
    required String browseId,
    required Duration timeout,
  }) async {
    final apiKey = bootstrap.apiKey.isNotEmpty
        ? bootstrap.apiKey
        : _fallbackYtmApiKey;
    final clientVersion = bootstrap.clientVersion.isNotEmpty
        ? bootstrap.clientVersion
        : _fallbackYtmClientVersion;

    final uri = Uri.parse(
      'https://music.youtube.com/youtubei/v1/browse?prettyPrint=false&key=$apiKey',
    );

    final client = <String, dynamic>{
      'clientName': _ytmClientNameBody,
      'clientVersion': clientVersion,
      'hl': bootstrap.hl.isNotEmpty ? bootstrap.hl : 'en',
      'gl': bootstrap.gl.isNotEmpty ? bootstrap.gl : 'US',
    };
    if (bootstrap.visitorData.isNotEmpty) {
      client['visitorData'] = bootstrap.visitorData;
    }

    final body = <String, dynamic>{
      'context': <String, dynamic>{'client': client},
      'browseId': browseId,
    };

    final headers = <String, String>{
      'Accept': '*/*',
      'Content-Type': 'application/json',
      'Origin': 'https://music.youtube.com',
      'Referer': 'https://music.youtube.com/',
      'User-Agent': _ytmUserAgent,
      'X-Youtube-Client-Name': _ytmClientNameHeader,
      'X-Youtube-Client-Version': clientVersion,
    };
    if (bootstrap.visitorData.isNotEmpty) {
      headers['X-Goog-Visitor-Id'] = bootstrap.visitorData;
    }

    final response = await http
        .post(uri, headers: headers, body: jsonEncode(body))
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw StateError('YTM browse failed with HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw StateError('YTM browse returned invalid payload');
    }

    return decoded;
  }

  static _YtmSongsPage _extractYtmSongsPage(
    Map<String, dynamic> payload, {
    required bool initialPage,
    required bool requireSongsShelf,
  }) {
    if (!initialPage) {
      final continuationContents = _asMap(payload['continuationContents']);
      final shelfContinuation = _asMap(
        continuationContents?['musicShelfContinuation'],
      );
      if (shelfContinuation == null) return const _YtmSongsPage.empty();

      return _YtmSongsPage(
        songs: _parseYtmSongs(_asList(shelfContinuation['contents'])),
        continuation: _extractContinuationToken(
          _asList(shelfContinuation['continuations']),
        ),
      );
    }

    final tabbed = _asMap(
      _asMap(payload['contents'])?['tabbedSearchResultsRenderer'],
    );
    final tabs = _asList(tabbed?['tabs']);

    Map<String, dynamic>? sectionListRenderer;
    for (final tab in tabs) {
      final tabRenderer = _asMap(_asMap(tab)?['tabRenderer']);
      if (tabRenderer == null) continue;

      final content = _asMap(tabRenderer['content']);
      final sectionList = _asMap(content?['sectionListRenderer']);
      if (sectionList == null) continue;

      if (tabRenderer['selected'] == true) {
        sectionListRenderer = sectionList;
        break;
      }
      sectionListRenderer ??= sectionList;
    }

    if (sectionListRenderer == null) {
      return const _YtmSongsPage.empty();
    }

    final sections = _asList(sectionListRenderer['contents']);
    Map<String, dynamic>? songsShelf;

    for (final section in sections) {
      final shelf = _asMap(_asMap(section)?['musicShelfRenderer']);
      if (shelf == null) continue;

      final title = _textFromRuns(_asMap(shelf['title'])).toLowerCase();
      if (title.contains('songs')) {
        songsShelf = shelf;
        break;
      }
      if (!requireSongsShelf) {
        songsShelf ??= shelf;
      }
    }

    if (songsShelf == null) {
      return const _YtmSongsPage.empty();
    }

    return _YtmSongsPage(
      songs: _parseYtmSongs(_asList(songsShelf['contents'])),
      continuation: _extractContinuationToken(
        _asList(songsShelf['continuations']),
      ),
    );
  }

  static List<SaavnSong> _parseYtmSongs(List<dynamic> contents) {
    final out = <SaavnSong>[];
    for (final item in contents) {
      final renderer = _asMap(_asMap(item)?['musicResponsiveListItemRenderer']);
      if (renderer == null) continue;

      final mapped = _mapYtmRendererToSong(renderer);
      if (mapped != null) out.add(mapped);
    }
    return out;
  }

  static SaavnSong? _mapYtmRendererToSong(Map<String, dynamic> renderer) {
    final videoId = _extractYtmVideoId(renderer);
    if (videoId == null || videoId.isEmpty) return null;

    final title = _extractYtmTitle(renderer);
    if (title.isEmpty) return null;

    final artist = _cleanYtmArtist(_extractYtmArtist(renderer));
    final duration = _extractYtmDurationSeconds(renderer);
    if (!_isLikelyYtmSong(title: title, artist: artist, duration: duration)) {
      return null;
    }

    final preferredThumb = _extractYtmThumbnail(renderer);
    final imageUrl = YoutubeThumbnailUtils.isYtmArtworkUrl(preferredThumb)
        ? (() {
            final candidates = YoutubeThumbnailUtils.candidateUrls(
              imageUrl: preferredThumb,
            );
            if (candidates.isNotEmpty) return candidates.first;
            return preferredThumb!.trim();
          })()
        : YoutubeThumbnailUtils.bestInitialUrl(
            videoId: videoId,
            preferredUrl: preferredThumb,
          );

    return SaavnSong(
      id: 'yt:$videoId',
      name: title,
      artists: artist,
      imageUrl: imageUrl,
      duration: duration,
      downloadUrls: const [],
    );
  }

  static bool _isLikelyYtmSong({
    required String title,
    required String artist,
    required int? duration,
  }) {
    final t = title.toLowerCase();
    final a = artist.toLowerCase();

    const blocked = <String>[
      'full movie',
      'episode',
      'podcast',
      'reaction',
      'review',
      'interview',
      'trailer',
      'teaser',
      'shorts',
      'tutorial',
      'vlog',
      'prank',
    ];
    if (blocked.any(t.contains)) return false;
    if (a.contains('podcast') || a.contains('news')) return false;

    if (duration != null) {
      if (duration < 50) return false;
      if (duration > 15 * 60) return false;
    }

    return true;
  }

  static String? _extractYtmVideoId(Map<String, dynamic> renderer) {
    final direct = _asMap(
      renderer['playlistItemData'],
    )?['videoId']?.toString().trim();
    if (_isValidVideoId(direct)) return direct;

    final overlayWatch = _asMap(
      _asMap(
        _asMap(
          _asMap(
            _asMap(renderer['overlay'])?['musicItemThumbnailOverlayRenderer'],
          )?['content'],
        )?['musicPlayButtonRenderer'],
      )?['playNavigationEndpoint'],
    );
    final overlayId = _asMap(
      overlayWatch?['watchEndpoint'],
    )?['videoId']?.toString().trim();
    if (_isValidVideoId(overlayId)) return overlayId;

    for (final column in _asList(renderer['flexColumns'])) {
      final runs = _asList(
        _asMap(
          _asMap(
            _asMap(column)?['musicResponsiveListItemFlexColumnRenderer'],
          )?['text'],
        )?['runs'],
      );
      for (final run in runs) {
        final endpoint = _asMap(_asMap(run)?['navigationEndpoint']);
        final watch = _asMap(endpoint?['watchEndpoint']);
        final id = watch?['videoId']?.toString().trim();
        if (_isValidVideoId(id)) return id;
      }
    }

    return null;
  }

  static String _extractYtmTitle(Map<String, dynamic> renderer) {
    final columns = _asList(renderer['flexColumns']);
    if (columns.isEmpty) return '';

    final firstColumn = _asMap(
      _asMap(columns.first)?['musicResponsiveListItemFlexColumnRenderer'],
    );
    return _textFromRuns(_asMap(firstColumn?['text'])).trim();
  }

  static String _extractYtmArtist(Map<String, dynamic> renderer) {
    final columns = _asList(renderer['flexColumns']);
    if (columns.length < 2) return 'Unknown';

    final secondColumn = _asMap(
      _asMap(columns[1])?['musicResponsiveListItemFlexColumnRenderer'],
    );
    final textContainer = _asMap(secondColumn?['text']);
    final runs = _asList(textContainer?['runs']);
    final rawLine = _textFromRuns(textContainer).trim();
    if (runs.isEmpty && rawLine.isEmpty) return 'Unknown';

    final artists = <String>{};
    for (final run in runs) {
      final runMap = _asMap(run);
      if (runMap == null) continue;

      final text = (runMap['text'] ?? '').toString().trim();
      if (text.isEmpty || text == '•' || _looksLikeDurationText(text)) {
        continue;
      }

      final browse = _asMap(
        _asMap(runMap['navigationEndpoint'])?['browseEndpoint'],
      );
      final pageType =
          _asMap(
            _asMap(
              browse?['browseEndpointContextSupportedConfigs'],
            )?['browseEndpointContextMusicConfig'],
          )?['pageType']?.toString().toUpperCase() ??
          '';
      final browseId = (browse?['browseId'] ?? '').toString().toUpperCase();
      final isArtist = pageType.contains('ARTIST') || browseId.startsWith('UC');

      if (isArtist) {
        artists.add(text);
      }
    }

    if (artists.isNotEmpty) return artists.join(', ');

    final fallbackFromRuns = <String>{};
    for (final run in runs) {
      final text = (_asMap(run)?['text'] ?? '').toString().trim();
      if (text.isEmpty || text == '•' || _looksLikeDurationText(text)) {
        continue;
      }
      if (_isLikelyNonArtistMetaText(text)) continue;
      fallbackFromRuns.add(text);
    }
    if (fallbackFromRuns.isNotEmpty) return fallbackFromRuns.join(', ');

    if (rawLine.isNotEmpty) {
      final pieces = rawLine
          .split(RegExp(r'\s*[•\u2022\|]\s*'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .where((s) => !_looksLikeDurationText(s))
          .where((s) => !_isLikelyNonArtistMetaText(s))
          .toList(growable: false);
      if (pieces.isNotEmpty) return pieces.join(', ');
    }

    for (final run in runs) {
      final text = (_asMap(run)?['text'] ?? '').toString().trim();
      if (text.isEmpty || text == '•' || _looksLikeDurationText(text)) {
        continue;
      }
      return text;
    }

    if (rawLine.isNotEmpty && !_isLikelyNonArtistMetaText(rawLine)) {
      return rawLine;
    }

    return 'Unknown';
  }

  static bool _isLikelyNonArtistMetaText(String text) {
    final normalized = text.toLowerCase().trim();
    if (normalized.isEmpty) return true;
    if (RegExp(r'^\d{4}$').hasMatch(normalized)) return true;
    if (RegExp(r'^\d+\s*(songs?|tracks?)$').hasMatch(normalized)) return true;
    if (RegExp(r'^\d+(\.\d+)?[mk]?\s*views$').hasMatch(normalized)) {
      return true;
    }

    const blocked = <String>{
      'single',
      'album',
      'ep',
      'song',
      'songs',
      'track',
      'tracks',
      'music',
      'unknown',
      'official',
      'official audio',
      'official video',
      'video',
      'audio',
      'lyrics',
      'lyric',
      'new release',
      'new releases',
    };
    return blocked.contains(normalized);
  }

  static int? _extractYtmDurationSeconds(Map<String, dynamic> renderer) {
    for (final column in _asList(renderer['flexColumns'])) {
      final runs = _asList(
        _asMap(
          _asMap(
            _asMap(column)?['musicResponsiveListItemFlexColumnRenderer'],
          )?['text'],
        )?['runs'],
      );
      for (final run in runs) {
        final text = (_asMap(run)?['text'] ?? '').toString().trim();
        final parsed = _parseDurationText(text);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static String? _extractYtmThumbnail(Map<String, dynamic> renderer) {
    final thumbs = _asList(
      _asMap(
        _asMap(
          _asMap(renderer['thumbnail'])?['musicThumbnailRenderer'],
        )?['thumbnail'],
      )?['thumbnails'],
    );
    if (thumbs.isEmpty) return null;

    String? bestUrl;
    var bestArea = -1;
    for (final thumb in thumbs) {
      final map = _asMap(thumb);
      if (map == null) continue;

      final url = (map['url'] ?? '').toString().trim();
      if (url.isEmpty) continue;

      final w = (map['width'] is num) ? (map['width'] as num).toInt() : 0;
      final h = (map['height'] is num) ? (map['height'] as num).toInt() : 0;
      final area = w * h;
      if (area >= bestArea) {
        bestArea = area;
        bestUrl = url;
      }
    }

    return bestUrl;
  }

  static bool _looksLikeDurationText(String text) {
    final normalized = text.trim();
    return RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$').hasMatch(normalized);
  }

  static int? _parseDurationText(String text) {
    if (!_looksLikeDurationText(text)) return null;
    final parts = text.trim().split(':').map(int.parse).toList(growable: false);
    if (parts.length == 2) {
      return parts[0] * 60 + parts[1];
    }
    if (parts.length == 3) {
      return parts[0] * 3600 + parts[1] * 60 + parts[2];
    }
    return null;
  }

  static bool _isValidVideoId(String? value) {
    return value != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(value);
  }

  static String? _extractContinuationToken(List<dynamic> continuations) {
    for (final continuation in continuations) {
      final token = _asMap(
        _asMap(continuation)?['nextContinuationData'],
      )?['continuation']?.toString().trim();
      if (token != null && token.isNotEmpty) return token;
    }
    return null;
  }

  static List<YtmChart> _parseYtmCharts(
    Map<String, dynamic> payload, {
    required int take,
  }) {
    final renderers = <Map<String, dynamic>>[];
    _collectMapsByKey(payload, 'musicTwoRowItemRenderer', renderers);

    final charts = <YtmChart>[];
    final seenChartKeys = <String>{};

    for (final renderer in renderers) {
      final title = _textFromRuns(_asMap(renderer['title'])).trim();
      if (title.isEmpty) continue;

      final endpoint =
          _extractChartNavigationEndpoint(renderer) ??
          _asMap(renderer['navigationEndpoint']);
      final watch = _asMap(endpoint?['watchEndpoint']);
      final watchPlaylist = _asMap(endpoint?['watchPlaylistEndpoint']);
      final browse = _asMap(endpoint?['browseEndpoint']);

      String playlistId =
          (watch?['playlistId'] ?? watchPlaylist?['playlistId'] ?? '')
              .toString()
              .trim();
      String browseId = (browse?['browseId'] ?? '').toString().trim();
      if (playlistId.isEmpty &&
          browseId.startsWith('VL') &&
          browseId.length > 2) {
        playlistId = browseId.substring(2);
      } else if (playlistId.isEmpty && browseId.isNotEmpty) {
        // Some charts come with browse-only IDs (no explicit playlistId).
        playlistId = browseId;
      }
      if (playlistId.isEmpty) continue;
      if (browseId.isEmpty) browseId = _toYtmBrowseId(playlistId);

      // Keep chart variants with different titles, even if they reuse playlist IDs.
      final idKey = '${browseId.toLowerCase()}::${title.toLowerCase()}';
      if (!seenChartKeys.add(idKey)) continue;

      final subtitle = _textFromRuns(_asMap(renderer['subtitle'])).trim();
      final artworkUrl =
          _extractLargestThumbnail(
            _asList(
              _asMap(
                _asMap(
                  _asMap(
                    renderer['thumbnailRenderer'],
                  )?['musicThumbnailRenderer'],
                )?['thumbnail'],
              )?['thumbnails'],
            ),
          ) ??
          '';

      final chart = YtmChart(
        playlistId: playlistId,
        browseId: browseId,
        title: title,
        subtitle: subtitle.isEmpty ? 'Chart - YouTube Music' : subtitle,
        imageUrl: artworkUrl,
        songCount: _extractSongCountFromText(subtitle),
      );

      charts.add(chart);

      if (charts.length >= take) break;
    }

    return charts.take(take).toList(growable: false);
  }

  static List<YtmAlbum> _parseYtmAlbumsFromShelves(
    Map<String, dynamic> payload, {
    required int take,
    bool preferredOnly = true,
  }) {
    final shelfRenderers = <Map<String, dynamic>>[];
    _collectMapsByKey(payload, 'musicCarouselShelfRenderer', shelfRenderers);

    final preferred = <YtmAlbum>[];
    final seen = <String>{};
    final candidateShelves = <Map<String, dynamic>>[];

    for (final shelf in shelfRenderers) {
      final shelfTitle = _extractCarouselShelfTitle(shelf);
      final normalizedTitle = _normalizeShelfTitleForMatching(shelfTitle);
      final priority = _albumShelfPriority(shelfTitle);
      final looksLikeAlbumShelf =
          normalizedTitle.contains('album') ||
          normalizedTitle.contains('release') ||
          priority < 100;

      if (preferredOnly) {
        // "Albums for you" is the highest-priority shelf.
        if (priority != 0) continue;
      } else {
        if (!looksLikeAlbumShelf) continue;
      }
      candidateShelves.add(shelf);
    }

    candidateShelves.sort((a, b) {
      final aPriority = _albumShelfPriority(_extractCarouselShelfTitle(a));
      final bPriority = _albumShelfPriority(_extractCarouselShelfTitle(b));
      return aPriority.compareTo(bPriority);
    });

    for (final shelf in candidateShelves) {
      final twoRows = <Map<String, dynamic>>[];
      final responsiveRows = <Map<String, dynamic>>[];
      _collectMapsByKey(shelf, 'musicTwoRowItemRenderer', twoRows);
      _collectMapsByKey(
        shelf,
        'musicResponsiveListItemRenderer',
        responsiveRows,
      );

      for (final renderer in twoRows) {
        final mapped = _mapTwoRowRendererToAlbum(renderer);
        if (mapped == null) continue;
        if (!seen.add(mapped.browseId.toLowerCase())) continue;
        preferred.add(mapped);
        if (preferred.length >= take) break;
      }
      if (preferred.length >= take) break;

      for (final renderer in responsiveRows) {
        final mapped = _mapResponsiveRendererToAlbum(renderer);
        if (mapped == null) continue;
        if (!seen.add(mapped.browseId.toLowerCase())) continue;
        preferred.add(mapped);
        if (preferred.length >= take) break;
      }
      if (preferred.length >= take) break;
    }

    return preferred.take(take).toList(growable: false);
  }

  static String _normalizeShelfTitleForMatching(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9]+"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static int _albumShelfPriority(String shelfTitle) {
    final normalized = _normalizeShelfTitleForMatching(shelfTitle);
    if (normalized.isEmpty) return 100;

    if (normalized.contains('albums for you') ||
        (normalized.contains('for you') && normalized.contains('album'))) {
      return 0;
    }
    if (normalized.contains('easy mornings')) return 1;
    if (normalized.contains('today s global hits') ||
        normalized.contains('todays global hits')) {
      return 2;
    }
    if (normalized.contains('india s biggest hits') ||
        normalized.contains('indias biggest hits')) {
      return 3;
    }
    if (normalized.contains('new releases') ||
        normalized.contains('new release')) {
      return 4;
    }
    if (normalized.contains('album')) return 20;
    return 100;
  }

  static Future<List<YtmAlbum>> _searchAlbumsViaYtm({
    required _YtmBootstrapCache bootstrap,
    required String query,
    required int take,
  }) async {
    final payload = await _postYtmSearch(
      bootstrap: bootstrap,
      query: query,
      useSongsParams: false,
      timeout: _ytmSearchTimeout,
    );

    final twoRows = <Map<String, dynamic>>[];
    final responsiveRows = <Map<String, dynamic>>[];
    _collectMapsByKey(payload, 'musicTwoRowItemRenderer', twoRows);
    _collectMapsByKey(
      payload,
      'musicResponsiveListItemRenderer',
      responsiveRows,
    );

    final out = <YtmAlbum>[];
    final seen = <String>{};

    for (final renderer in twoRows) {
      final mapped = _mapTwoRowRendererToAlbum(renderer);
      if (mapped == null) continue;
      if (!seen.add(mapped.browseId.toLowerCase())) continue;
      out.add(mapped);
      if (out.length >= take) return out;
    }

    for (final renderer in responsiveRows) {
      final mapped = _mapResponsiveRendererToAlbum(renderer);
      if (mapped == null) continue;
      if (!seen.add(mapped.browseId.toLowerCase())) continue;
      out.add(mapped);
      if (out.length >= take) break;
    }

    return out.take(take).toList(growable: false);
  }

  static Future<List<YtmAlbum>> _searchAlbumsViaYoutubePlaylists({
    required String query,
    required int take,
  }) async {
    final out = <YtmAlbum>[];
    final seen = <String>{};

    final queries = <String>[
      query,
      '$query album',
      '$query full album',
      '$query soundtrack',
    ];
    final seenQueries = <String>{};

    for (final q in queries) {
      if (out.length >= take) break;
      final normalizedQuery = q.trim();
      if (normalizedQuery.isEmpty) continue;
      if (!seenQueries.add(normalizedQuery.toLowerCase())) continue;

      SearchList? page;
      try {
        page = await _yt.search
            .searchContent(normalizedQuery, filter: TypeFilters.playlist)
            .timeout(_searchTimeout);
      } catch (_) {
        continue;
      }

      var pageGuard = 0;
      while (page != null && pageGuard < 3 && out.length < take) {
        for (final item in page) {
          if (item is! SearchPlaylist) continue;

          final playlistId = item.id.value.trim();
          if (playlistId.isEmpty) continue;

          final browseId = _toYtmBrowseId(playlistId);
          final subtitle = item.videoCount > 0
              ? '${item.videoCount} songs'
              : 'Album - YouTube Music';

          if (!_isLikelyAlbumResult(
            pageType: '',
            browseId: browseId,
            playlistId: playlistId,
            title: item.title.trim(),
            subtitle: subtitle,
          )) {
            continue;
          }

          final dedupKey = browseId.toLowerCase();
          if (!seen.add(dedupKey)) continue;

          final title = item.title.trim();
          if (title.isEmpty) continue;

          out.add(
            YtmAlbum(
              browseId: browseId,
              title: title,
              subtitle: subtitle,
              imageUrl: _extractSearchPlaylistArtwork(item.thumbnails),
            ),
          );
          if (out.length >= take) break;
        }

        if (out.length >= take) break;
        try {
          page = await page.nextPage().timeout(_searchFallbackTimeout);
        } catch (_) {
          break;
        }
        pageGuard++;
      }
    }

    return out.take(take).toList(growable: false);
  }

  static String _extractSearchPlaylistArtwork(List<Thumbnail> thumbnails) {
    if (thumbnails.isEmpty) return '';

    Thumbnail? best;
    var bestArea = -1;
    for (final thumb in thumbnails) {
      final area = thumb.width * thumb.height;
      if (area > bestArea) {
        bestArea = area;
        best = thumb;
      }
    }
    return best?.url.toString() ?? '';
  }

  static YtmAlbum? _mapTwoRowRendererToAlbum(Map<String, dynamic> renderer) {
    final title = _textFromRuns(_asMap(renderer['title'])).trim();
    if (title.isEmpty) return null;

    final endpoint =
        _extractAlbumNavigationEndpoint(renderer) ??
        _asMap(renderer['navigationEndpoint']);
    final endpointInfo = _extractAlbumEndpointInfo(endpoint);
    final browseId = endpointInfo.browseId;
    if (browseId.isEmpty) return null;

    final subtitle = _textFromRuns(_asMap(renderer['subtitle'])).trim();
    if (!_isLikelyAlbumResult(
      pageType: endpointInfo.pageType,
      browseId: browseId,
      playlistId: endpointInfo.playlistId,
      title: title,
      subtitle: subtitle,
    )) {
      return null;
    }

    final artworkUrl =
        _extractPreferredAlbumThumbnail(
          _asList(
            _asMap(
              _asMap(
                _asMap(
                  renderer['thumbnailRenderer'],
                )?['musicThumbnailRenderer'],
              )?['thumbnail'],
            )?['thumbnails'],
          ),
        ) ??
        '';

    return YtmAlbum(
      browseId: browseId,
      title: title,
      subtitle: subtitle.isEmpty ? 'Album - YouTube Music' : subtitle,
      imageUrl: artworkUrl,
    );
  }

  static YtmAlbum? _mapResponsiveRendererToAlbum(
    Map<String, dynamic> renderer,
  ) {
    final columns = _asList(renderer['flexColumns']);
    if (columns.isEmpty) return null;

    final firstColumn = _asMap(
      _asMap(columns.first)?['musicResponsiveListItemFlexColumnRenderer'],
    );
    final firstText = _asMap(firstColumn?['text']);
    final title = _textFromRuns(firstText).trim();
    if (title.isEmpty) return null;

    Map<String, dynamic>? endpoint = _asMap(renderer['navigationEndpoint']);
    if (endpoint == null) {
      for (final run in _asList(firstText?['runs'])) {
        endpoint = _asMap(_asMap(run)?['navigationEndpoint']);
        if (endpoint != null) break;
      }
    }

    final endpointInfo = _extractAlbumEndpointInfo(endpoint);
    final browseId = endpointInfo.browseId;
    if (browseId.isEmpty) return null;

    final secondColumn = columns.length > 1
        ? _asMap(
            _asMap(columns[1])?['musicResponsiveListItemFlexColumnRenderer'],
          )
        : null;
    final subtitle = _textFromRuns(_asMap(secondColumn?['text'])).trim();
    if (!_isLikelyAlbumResult(
      pageType: endpointInfo.pageType,
      browseId: browseId,
      playlistId: endpointInfo.playlistId,
      title: title,
      subtitle: subtitle,
    )) {
      return null;
    }

    final artworkUrl =
        _extractPreferredAlbumThumbnail(
          _asList(
            _asMap(
              _asMap(
                _asMap(renderer['thumbnail'])?['musicThumbnailRenderer'],
              )?['thumbnail'],
            )?['thumbnails'],
          ),
        ) ??
        '';

    return YtmAlbum(
      browseId: browseId,
      title: title,
      subtitle: subtitle.isEmpty ? 'Album - YouTube Music' : subtitle,
      imageUrl: artworkUrl,
    );
  }

  static String _extractCarouselShelfTitle(Map<String, dynamic> shelf) {
    final header = _asMap(shelf['header']);
    final basic = _asMap(header?['musicCarouselShelfBasicHeaderRenderer']);
    final title = _textFromRuns(_asMap(basic?['title'])).trim();
    if (title.isNotEmpty) return title;
    return _textFromRuns(_asMap(basic?['strapline'])).trim();
  }

  static List<YtmArtist> _parseYtmArtistsFromShelves(
    Map<String, dynamic> payload, {
    required int take,
    bool preferredOnly = true,
  }) {
    final shelfRenderers = <Map<String, dynamic>>[];
    _collectMapsByKey(payload, 'musicCarouselShelfRenderer', shelfRenderers);

    final out = <YtmArtist>[];
    final seen = <String>{};

    for (final shelf in shelfRenderers) {
      final shelfTitle = _extractCarouselShelfTitle(shelf).toLowerCase();
      if (shelfTitle.contains('new release')) continue;

      final isPreferred =
          shelfTitle.contains('artists for you') ||
          (shelfTitle.contains('for you') && shelfTitle.contains('artist'));
      if (preferredOnly) {
        if (!isPreferred) continue;
      } else {
        final looksLikeArtistShelf = shelfTitle.contains('artist');
        if (!looksLikeArtistShelf) continue;
      }

      final twoRows = <Map<String, dynamic>>[];
      final responsiveRows = <Map<String, dynamic>>[];
      _collectMapsByKey(shelf, 'musicTwoRowItemRenderer', twoRows);
      _collectMapsByKey(
        shelf,
        'musicResponsiveListItemRenderer',
        responsiveRows,
      );

      for (final renderer in twoRows) {
        final artist = _mapTwoRowRendererToArtist(renderer);
        if (artist == null) continue;
        if (!seen.add(artist.browseId.toLowerCase())) continue;
        out.add(artist);
        if (out.length >= take) break;
      }
      if (out.length >= take) break;

      for (final renderer in responsiveRows) {
        final artist = _mapResponsiveRendererToArtist(renderer);
        if (artist == null) continue;
        if (!seen.add(artist.browseId.toLowerCase())) continue;
        out.add(artist);
        if (out.length >= take) break;
      }
      if (out.length >= take) break;
    }

    return out.take(take).toList(growable: false);
  }

  static List<YtmArtist> _parseYtmArtistsFromSearchResults(
    Map<String, dynamic> payload, {
    required int take,
  }) {
    final twoRows = <Map<String, dynamic>>[];
    final responsiveRows = <Map<String, dynamic>>[];
    _collectMapsByKey(payload, 'musicTwoRowItemRenderer', twoRows);
    _collectMapsByKey(
      payload,
      'musicResponsiveListItemRenderer',
      responsiveRows,
    );

    final out = <YtmArtist>[];
    final seen = <String>{};

    for (final renderer in twoRows) {
      final artist = _mapTwoRowRendererToArtist(renderer);
      if (artist == null) continue;
      if (!seen.add(artist.browseId.toLowerCase())) continue;
      out.add(artist);
      if (out.length >= take) return out;
    }

    for (final renderer in responsiveRows) {
      final artist = _mapResponsiveRendererToArtist(renderer);
      if (artist == null) continue;
      if (!seen.add(artist.browseId.toLowerCase())) continue;
      out.add(artist);
      if (out.length >= take) break;
    }

    return out.take(take).toList(growable: false);
  }

  static YtmArtist? _mapTwoRowRendererToArtist(Map<String, dynamic> renderer) {
    final name = _textFromRuns(_asMap(renderer['title'])).trim();
    if (name.isEmpty) return null;

    final endpoint =
        _asMap(renderer['navigationEndpoint']) ??
        _extractAlbumNavigationEndpoint(renderer);
    final browse = _asMap(endpoint?['browseEndpoint']);
    final browseId = (browse?['browseId'] ?? '').toString().trim();
    if (browseId.isEmpty) return null;

    final pageType = _extractBrowsePageType(browse);
    final subtitle = _textFromRuns(_asMap(renderer['subtitle'])).trim();
    final looksLikeArtist =
        pageType.contains('ARTIST') ||
        browseId.toUpperCase().startsWith('UC') ||
        subtitle.toLowerCase().contains('artist');
    if (!looksLikeArtist) return null;

    final imageUrl =
        _extractPreferredArtistThumbnail(
          _asList(
            _asMap(
              _asMap(
                _asMap(
                  renderer['thumbnailRenderer'],
                )?['musicThumbnailRenderer'],
              )?['thumbnail'],
            )?['thumbnails'],
          ),
        ) ??
        '';

    return YtmArtist(
      browseId: browseId,
      name: name,
      subtitle: subtitle.isEmpty ? 'Artist' : subtitle,
      imageUrl: imageUrl,
    );
  }

  static YtmArtist? _mapResponsiveRendererToArtist(
    Map<String, dynamic> renderer,
  ) {
    final columns = _asList(renderer['flexColumns']);
    if (columns.isEmpty) return null;

    final firstColumn = _asMap(
      _asMap(columns.first)?['musicResponsiveListItemFlexColumnRenderer'],
    );
    final firstText = _asMap(firstColumn?['text']);
    final name = _textFromRuns(firstText).trim();
    if (name.isEmpty) return null;

    String browseId = '';
    String pageType = '';
    for (final run in _asList(firstText?['runs'])) {
      final browse = _asMap(
        _asMap(_asMap(run)?['navigationEndpoint'])?['browseEndpoint'],
      );
      final candidate = (browse?['browseId'] ?? '').toString().trim();
      if (candidate.isEmpty) continue;
      browseId = candidate;
      pageType = _extractBrowsePageType(browse);
      break;
    }
    if (browseId.isEmpty) return null;

    final secondColumn = columns.length > 1
        ? _asMap(
            _asMap(columns[1])?['musicResponsiveListItemFlexColumnRenderer'],
          )
        : null;
    final subtitle = _textFromRuns(_asMap(secondColumn?['text'])).trim();
    final looksLikeArtist =
        pageType.contains('ARTIST') ||
        browseId.toUpperCase().startsWith('UC') ||
        subtitle.toLowerCase().contains('artist');
    if (!looksLikeArtist) return null;

    final imageUrl =
        _extractPreferredArtistThumbnail(
          _asList(
            _asMap(
              _asMap(
                _asMap(renderer['thumbnail'])?['musicThumbnailRenderer'],
              )?['thumbnail'],
            )?['thumbnails'],
          ),
        ) ??
        '';

    return YtmArtist(
      browseId: browseId,
      name: name,
      subtitle: subtitle.isEmpty ? 'Artist' : subtitle,
      imageUrl: imageUrl,
    );
  }

  static _ArtistHeaderResult _parseArtistHeader(
    Map<String, dynamic> payload, {
    String fallbackName = '',
  }) {
    final headerMaps = <Map<String, dynamic>>[];
    _collectMapsByKey(payload, 'musicImmersiveHeaderRenderer', headerMaps);
    _collectMapsByKey(payload, 'musicDetailHeaderRenderer', headerMaps);

    var name = '';
    var imageUrl = '';
    final monthlyCandidates = <String>[];
    final bioCandidates = <String>[];

    void addCandidate(List<String> target, String value) {
      final normalized = value.trim();
      if (normalized.isEmpty) return;
      target.add(normalized);
    }

    for (final header in headerMaps) {
      final title = _textFromRuns(_asMap(header['title'])).trim();
      final subtitle = _textFromRuns(_asMap(header['subtitle'])).trim();
      final strapline = _textFromRuns(_asMap(header['strapline'])).trim();
      final description = _textFromRuns(_asMap(header['description'])).trim();
      final secondSubtitle = _textFromRuns(
        _asMap(header['secondSubtitle']),
      ).trim();

      if (name.isEmpty && title.isNotEmpty) name = title;
      if (imageUrl.isEmpty) {
        imageUrl = _extractArtistHeaderImage(header);
      }

      addCandidate(monthlyCandidates, subtitle);
      addCandidate(monthlyCandidates, strapline);
      addCandidate(monthlyCandidates, secondSubtitle);
      addCandidate(monthlyCandidates, description);
      addCandidate(bioCandidates, description);
    }

    final descriptionShelves = <Map<String, dynamic>>[];
    _collectMapsByKey(
      payload,
      'musicDescriptionShelfRenderer',
      descriptionShelves,
    );
    for (final shelf in descriptionShelves) {
      addCandidate(bioCandidates, _textFromRuns(_asMap(shelf['description'])));
      addCandidate(
        monthlyCandidates,
        _textFromRuns(_asMap(shelf['description'])),
      );
      addCandidate(
        monthlyCandidates,
        _textFromRuns(_asMap(shelf['subheader'])),
      );
    }

    final monthlyAudience = _extractMonthlyAudienceText(monthlyCandidates);
    final bio = bioCandidates
        .map((e) => e.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((e) => e.isNotEmpty)
        .fold<String>(
          '',
          (best, current) => current.length > best.length ? current : best,
        );

    if (name.isEmpty) {
      name = fallbackName.trim();
    }

    return _ArtistHeaderResult(
      name: name,
      imageUrl: imageUrl,
      bio: bio,
      monthlyAudience: monthlyAudience,
    );
  }

  static String _extractMonthlyAudienceText(List<String> candidates) {
    if (candidates.isEmpty) return '';

    final monthlyPattern = RegExp(
      r'([0-9][0-9\.,]*\s*[KMB]?)\s+monthly\s+(audience|listeners?)',
      caseSensitive: false,
    );
    for (final candidate in candidates) {
      final match = monthlyPattern.firstMatch(candidate);
      if (match == null) continue;
      final value = match.group(1)?.trim() ?? '';
      final unit = match.group(2)?.trim().toLowerCase() ?? 'audience';
      if (value.isEmpty) continue;
      return '$value monthly $unit';
    }

    for (final candidate in candidates) {
      final normalized = candidate.toLowerCase();
      if (normalized.contains('monthly audience') ||
          normalized.contains('monthly listeners')) {
        return candidate.trim();
      }
    }

    return '';
  }

  static String _extractArtistHeaderImage(Map<String, dynamic> header) {
    final thumbsCandidates = <List<dynamic>>[
      _asList(
        _asMap(
          _asMap(
            _asMap(header['thumbnail'])?['musicThumbnailRenderer'],
          )?['thumbnail'],
        )?['thumbnails'],
      ),
      _asList(_asMap(header['thumbnail'])?['thumbnails']),
      _asList(
        _asMap(
          _asMap(
            _asMap(header['foregroundThumbnail'])?['musicThumbnailRenderer'],
          )?['thumbnail'],
        )?['thumbnails'],
      ),
      _asList(
        _asMap(
          _asMap(
            _asMap(header['backgroundThumbnail'])?['musicThumbnailRenderer'],
          )?['thumbnail'],
        )?['thumbnails'],
      ),
    ];

    for (final thumbs in thumbsCandidates) {
      if (thumbs.isEmpty) continue;
      final resolved = _extractPreferredArtistThumbnail(thumbs);
      if (resolved != null && resolved.trim().isNotEmpty) {
        return resolved.trim();
      }
    }
    return '';
  }

  static List<SaavnSong> _extractSongsFromPayload(
    Map<String, dynamic> payload, {
    required int take,
  }) {
    if (take <= 0) return const <SaavnSong>[];

    final renderers = <Map<String, dynamic>>[];
    _collectMapsByKey(payload, 'musicResponsiveListItemRenderer', renderers);

    final songs = <SaavnSong>[];
    final seen = <String>{};
    for (final renderer in renderers) {
      final mapped = _mapYtmRendererToSong(renderer);
      if (mapped == null) continue;
      if (!seen.add(mapped.id)) continue;
      songs.add(mapped);
      if (songs.length >= take) break;
    }
    return songs.take(take).toList(growable: false);
  }

  static List<YtmAlbum> _parseArtistReleasesFromShelves(
    Map<String, dynamic> payload, {
    required int take,
    required _ArtistReleaseSection section,
  }) {
    if (take <= 0) return const <YtmAlbum>[];

    final shelfRenderers = <Map<String, dynamic>>[];
    _collectMapsByKey(payload, 'musicCarouselShelfRenderer', shelfRenderers);

    final out = <YtmAlbum>[];
    final seen = <String>{};
    for (final shelf in shelfRenderers) {
      final shelfTitle = _extractCarouselShelfTitle(shelf);
      if (!_isMatchingArtistReleaseShelf(shelfTitle, section)) {
        continue;
      }

      final twoRows = <Map<String, dynamic>>[];
      final responsiveRows = <Map<String, dynamic>>[];
      _collectMapsByKey(shelf, 'musicTwoRowItemRenderer', twoRows);
      _collectMapsByKey(
        shelf,
        'musicResponsiveListItemRenderer',
        responsiveRows,
      );

      for (final renderer in twoRows) {
        final release = _mapTwoRowRendererToRelease(renderer);
        if (release == null) continue;
        if (!seen.add(release.browseId.toLowerCase())) continue;
        out.add(release);
        if (out.length >= take) return out.take(take).toList(growable: false);
      }

      for (final renderer in responsiveRows) {
        final release = _mapResponsiveRendererToRelease(renderer);
        if (release == null) continue;
        if (!seen.add(release.browseId.toLowerCase())) continue;
        out.add(release);
        if (out.length >= take) return out.take(take).toList(growable: false);
      }
    }

    return out.take(take).toList(growable: false);
  }

  static bool _isMatchingArtistReleaseShelf(
    String shelfTitle,
    _ArtistReleaseSection section,
  ) {
    final normalized = _normalizeShelfTitleForMatching(shelfTitle);
    if (normalized.isEmpty) return false;

    final hasAlbum = normalized.contains('album');
    final hasSingle = normalized.contains('single');
    final hasEp = RegExp(r'(^|\s)eps?($|\s)').hasMatch(normalized);

    if (section == _ArtistReleaseSection.albums) {
      if (!hasAlbum) return false;
      return !hasSingle && !hasEp;
    }

    return hasSingle || hasEp;
  }

  static YtmAlbum? _mapTwoRowRendererToRelease(Map<String, dynamic> renderer) {
    final title = _textFromRuns(_asMap(renderer['title'])).trim();
    if (title.isEmpty) return null;

    final endpoint =
        _extractAlbumNavigationEndpoint(renderer) ??
        _asMap(renderer['navigationEndpoint']);
    final endpointInfo = _extractAlbumEndpointInfo(endpoint);
    final browseId = endpointInfo.browseId.trim();
    if (browseId.isEmpty) return null;
    if (browseId.toUpperCase().startsWith('UC')) return null;

    final subtitle = _textFromRuns(_asMap(renderer['subtitle'])).trim();
    final artworkUrl =
        _extractPreferredAlbumThumbnail(
          _asList(
            _asMap(
              _asMap(
                _asMap(
                  renderer['thumbnailRenderer'],
                )?['musicThumbnailRenderer'],
              )?['thumbnail'],
            )?['thumbnails'],
          ),
        ) ??
        '';

    return YtmAlbum(
      browseId: browseId,
      title: title,
      subtitle: subtitle.isEmpty ? 'Release - YouTube Music' : subtitle,
      imageUrl: artworkUrl,
    );
  }

  static YtmAlbum? _mapResponsiveRendererToRelease(
    Map<String, dynamic> renderer,
  ) {
    final columns = _asList(renderer['flexColumns']);
    if (columns.isEmpty) return null;

    final firstColumn = _asMap(
      _asMap(columns.first)?['musicResponsiveListItemFlexColumnRenderer'],
    );
    final firstText = _asMap(firstColumn?['text']);
    final title = _textFromRuns(firstText).trim();
    if (title.isEmpty) return null;

    Map<String, dynamic>? endpoint = _asMap(renderer['navigationEndpoint']);
    if (endpoint == null) {
      for (final run in _asList(firstText?['runs'])) {
        endpoint = _asMap(_asMap(run)?['navigationEndpoint']);
        if (endpoint != null) break;
      }
    }

    final endpointInfo = _extractAlbumEndpointInfo(endpoint);
    final browseId = endpointInfo.browseId.trim();
    if (browseId.isEmpty) return null;
    if (browseId.toUpperCase().startsWith('UC')) return null;

    final secondColumn = columns.length > 1
        ? _asMap(
            _asMap(columns[1])?['musicResponsiveListItemFlexColumnRenderer'],
          )
        : null;
    final subtitle = _textFromRuns(_asMap(secondColumn?['text'])).trim();

    final artworkUrl =
        _extractPreferredAlbumThumbnail(
          _asList(
            _asMap(
              _asMap(
                _asMap(renderer['thumbnail'])?['musicThumbnailRenderer'],
              )?['thumbnail'],
            )?['thumbnails'],
          ),
        ) ??
        '';

    return YtmAlbum(
      browseId: browseId,
      title: title,
      subtitle: subtitle.isEmpty ? 'Release - YouTube Music' : subtitle,
      imageUrl: artworkUrl,
    );
  }

  static String? _extractPreferredArtistThumbnail(List<dynamic> thumbs) {
    if (thumbs.isEmpty) return null;

    String? bestSquareYtmUrl;
    var bestSquareYtmArea = -1;
    String? bestSquareUrl;
    var bestSquareArea = -1;

    for (final thumb in thumbs) {
      final map = _asMap(thumb);
      if (map == null) continue;

      final url = (map['url'] ?? '').toString().trim();
      if (url.isEmpty) continue;

      final width = (map['width'] is num) ? (map['width'] as num).toInt() : 0;
      final height = (map['height'] is num)
          ? (map['height'] as num).toInt()
          : 0;
      if (width <= 0 || height <= 0) continue;

      final area = width * height;
      final ratio = width / height;
      final isSquareish = ratio >= 0.8 && ratio <= 1.25;
      if (!isSquareish) continue;

      final isYtm = YoutubeThumbnailUtils.isYtmArtworkUrl(url);
      if (isYtm && area > bestSquareYtmArea) {
        bestSquareYtmArea = area;
        bestSquareYtmUrl = url;
      }
      if (area > bestSquareArea) {
        bestSquareArea = area;
        bestSquareUrl = url;
      }
    }

    return bestSquareYtmUrl ??
        bestSquareUrl ??
        _extractLargestThumbnail(thumbs);
  }

  static String _extractBrowsePageType(Map<String, dynamic>? browse) {
    return _asMap(
          _asMap(
            browse?['browseEndpointContextSupportedConfigs'],
          )?['browseEndpointContextMusicConfig'],
        )?['pageType']?.toString().toUpperCase() ??
        '';
  }

  static Map<String, dynamic>? _extractChartNavigationEndpoint(
    Map<String, dynamic> renderer,
  ) {
    final direct = _asMap(renderer['navigationEndpoint']);
    if (direct != null) return direct;

    final titleRuns = _asList(_asMap(_asMap(renderer['title'])?['runs']));
    for (final run in titleRuns) {
      final endpoint = _asMap(_asMap(run)?['navigationEndpoint']);
      if (endpoint != null) return endpoint;
    }

    final subtitleRuns = _asList(_asMap(_asMap(renderer['subtitle'])?['runs']));
    for (final run in subtitleRuns) {
      final endpoint = _asMap(_asMap(run)?['navigationEndpoint']);
      if (endpoint != null) return endpoint;
    }

    return null;
  }

  static Map<String, dynamic>? _extractAlbumNavigationEndpoint(
    Map<String, dynamic> renderer,
  ) {
    final direct = _asMap(renderer['navigationEndpoint']);
    if (direct != null) return direct;

    final titleRuns = _asList(_asMap(_asMap(renderer['title'])?['runs']));
    for (final run in titleRuns) {
      final endpoint = _asMap(_asMap(run)?['navigationEndpoint']);
      if (endpoint != null) return endpoint;
    }

    final subtitleRuns = _asList(_asMap(_asMap(renderer['subtitle'])?['runs']));
    for (final run in subtitleRuns) {
      final endpoint = _asMap(_asMap(run)?['navigationEndpoint']);
      if (endpoint != null) return endpoint;
    }

    return null;
  }

  static ({String browseId, String playlistId, String pageType})
  _extractAlbumEndpointInfo(Map<String, dynamic>? endpoint) {
    final browse = _asMap(endpoint?['browseEndpoint']);
    final watch = _asMap(endpoint?['watchEndpoint']);
    final watchPlaylist = _asMap(endpoint?['watchPlaylistEndpoint']);

    var browseId = (browse?['browseId'] ?? '').toString().trim();
    final playlistId =
        (watch?['playlistId'] ?? watchPlaylist?['playlistId'] ?? '')
            .toString()
            .trim();
    final pageType = _extractBrowsePageType(browse);

    if (browseId.isEmpty && playlistId.isNotEmpty) {
      browseId = _toYtmBrowseId(playlistId);
    }

    return (browseId: browseId, playlistId: playlistId, pageType: pageType);
  }

  static bool _isLikelyAlbumResult({
    required String pageType,
    required String browseId,
    required String playlistId,
    required String title,
    required String subtitle,
  }) {
    if (_isExcludedAlbumLikeResult(title) ||
        _isExcludedAlbumLikeResult(subtitle)) {
      return false;
    }

    final normalizedPageType = pageType.toUpperCase();
    if (normalizedPageType.contains('ARTIST') ||
        normalizedPageType.contains('CHANNEL')) {
      return false;
    }
    if (normalizedPageType.contains('ALBUM')) return true;

    if (_looksLikeAlbumId(browseId) || _looksLikeAlbumId(playlistId)) {
      return true;
    }

    return _looksLikeAlbumSubtitle(subtitle);
  }

  static bool _looksLikeAlbumId(String value) {
    final raw = value.trim().toUpperCase();
    if (raw.isEmpty) return false;
    return raw.startsWith('MPRE') ||
        raw.startsWith('VLMPR') ||
        raw.startsWith('OLAK5') ||
        raw.startsWith('VLOLAK5');
  }

  static bool _looksLikeAlbumSubtitle(String subtitle) {
    final normalized = subtitle.toLowerCase().trim();
    if (normalized.isEmpty) return false;
    if (normalized.contains('album')) {
      return true;
    }

    // Album rows often look like: "Artist • 2024".
    final hasYear = RegExp(r'\b(19|20)\d{2}\b').hasMatch(normalized);
    final hasBulletSeparator =
        normalized.contains('\u2022') || normalized.contains('\u00b7');
    if (hasYear && hasBulletSeparator) return true;

    return false;
  }

  static bool _isExcludedAlbumLikeResult(String text) {
    final normalized = text.toLowerCase().trim();
    if (normalized.isEmpty) return false;

    if (RegExp(r'\bepisodes?\b').hasMatch(normalized)) return true;
    if (RegExp(r'\bpodcast\b').hasMatch(normalized)) return true;
    if (RegExp(r'\bsingles?\b').hasMatch(normalized)) return true;
    if (RegExp(r'(^|[^\w])ep([^\w]|$)').hasMatch(normalized)) return true;

    return false;
  }

  static String _toYtmBrowseId(String idOrBrowseId) {
    final raw = idOrBrowseId.trim();
    if (raw.isEmpty) return raw;
    if (raw.startsWith('VL') ||
        raw.startsWith('MPLY') ||
        raw.startsWith('MPRE') ||
        raw.startsWith('FEmusic')) {
      return raw;
    }
    return 'VL$raw';
  }

  static String _toPlaylistIdForFallback(String idOrBrowseId) {
    final raw = idOrBrowseId.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('VL') && raw.length > 2) {
      return raw.substring(2);
    }
    if (raw.startsWith('MPLY') ||
        raw.startsWith('MPRE') ||
        raw.startsWith('FEmusic')) {
      return '';
    }
    return raw;
  }

  static void _collectMapsByKey(
    dynamic node,
    String targetKey,
    List<Map<String, dynamic>> out,
  ) {
    if (node is List) {
      for (final item in node) {
        _collectMapsByKey(item, targetKey, out);
      }
      return;
    }

    if (node is! Map) return;
    final map = _asMap(node);
    if (map == null) return;

    for (final entry in map.entries) {
      if (entry.key == targetKey) {
        final matched = _asMap(entry.value);
        if (matched != null) out.add(matched);
      }
      _collectMapsByKey(entry.value, targetKey, out);
    }
  }

  static int? _extractSongCountFromText(String text) {
    if (text.trim().isEmpty) return null;
    final match = RegExp(
      r'(\d{1,4})\s*(?:songs?|tracks?)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  static String? _extractLargestThumbnail(List<dynamic> thumbs) {
    if (thumbs.isEmpty) return null;
    String? bestUrl;
    var bestArea = -1;

    for (final thumb in thumbs) {
      final map = _asMap(thumb);
      if (map == null) continue;
      final url = (map['url'] ?? '').toString().trim();
      if (url.isEmpty) continue;

      final width = (map['width'] is num) ? (map['width'] as num).toInt() : 0;
      final height = (map['height'] is num)
          ? (map['height'] as num).toInt()
          : 0;
      final area = width * height;
      if (area >= bestArea) {
        bestArea = area;
        bestUrl = url;
      }
    }

    return bestUrl;
  }

  static String? _extractPreferredAlbumThumbnail(List<dynamic> thumbs) {
    if (thumbs.isEmpty) return null;

    String? bestSquareYtmUrl;
    var bestSquareYtmArea = -1;
    String? bestSquareUrl;
    var bestSquareArea = -1;
    String? bestYtmUrl;
    var bestYtmArea = -1;

    for (final thumb in thumbs) {
      final map = _asMap(thumb);
      if (map == null) continue;

      final url = (map['url'] ?? '').toString().trim();
      if (url.isEmpty) continue;

      final width = (map['width'] is num) ? (map['width'] as num).toInt() : 0;
      final height = (map['height'] is num)
          ? (map['height'] as num).toInt()
          : 0;
      final area = width * height;
      final ratio = (width > 0 && height > 0) ? (width / height) : 1.0;
      final isSquareish = ratio >= 0.85 && ratio <= 1.15;
      final isYtm = YoutubeThumbnailUtils.isYtmArtworkUrl(url);

      if (isYtm && isSquareish && area > bestSquareYtmArea) {
        bestSquareYtmArea = area;
        bestSquareYtmUrl = url;
      }
      if (isSquareish && area > bestSquareArea) {
        bestSquareArea = area;
        bestSquareUrl = url;
      }
      if (isYtm && area > bestYtmArea) {
        bestYtmArea = area;
        bestYtmUrl = url;
      }
    }

    return bestSquareYtmUrl ??
        bestSquareUrl ??
        bestYtmUrl ??
        _extractLargestThumbnail(thumbs);
  }

  static String _textFromRuns(Map<String, dynamic>? textContainer) {
    if (textContainer == null) return '';

    final runs = _asList(textContainer['runs']);
    if (runs.isEmpty) {
      return (textContainer['simpleText'] ?? '').toString();
    }

    final buffer = StringBuffer();
    for (final run in runs) {
      final text = (_asMap(run)?['text'] ?? '').toString();
      if (text.isNotEmpty) buffer.write(text);
    }
    return buffer.toString();
  }

  static List<dynamic> _asList(dynamic value) {
    return value is List ? value : const [];
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, val) => MapEntry('$key', val));
    }
    return null;
  }

  static Future<_YtmBootstrapCache> _getYtmBootstrap() async {
    final cached = _ytmBootstrapCache;
    if (cached != null && !cached.isExpired(_ytmBootstrapTtl)) {
      return cached;
    }

    final inFlight = _ytmBootstrapInFlight;
    if (inFlight != null) return inFlight;

    final future = _fetchYtmBootstrap();
    _ytmBootstrapInFlight = future;

    try {
      final fresh = await future;
      _ytmBootstrapCache = fresh;
      return fresh;
    } finally {
      if (identical(_ytmBootstrapInFlight, future)) {
        _ytmBootstrapInFlight = null;
      }
    }
  }

  static Future<_YtmBootstrapCache> _fetchYtmBootstrap() async {
    final response = await http
        .get(
          Uri.parse('https://music.youtube.com/'),
          headers: const {
            'Accept': 'text/html,application/xhtml+xml',
            'Accept-Language': 'en-US,en;q=0.9',
            'User-Agent': _ytmUserAgent,
          },
        )
        .timeout(_ytmBootstrapTimeout);

    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      return _YtmBootstrapCache.fallback();
    }

    final html = utf8.decode(response.bodyBytes);
    final apiKey =
        _firstRegexGroup(html, RegExp(r'"INNERTUBE_API_KEY":"([^"]+)"')) ??
        _fallbackYtmApiKey;
    final clientVersion =
        _firstRegexGroup(
          html,
          RegExp(r'"INNERTUBE_CLIENT_VERSION":"([^"]+)"'),
        ) ??
        _fallbackYtmClientVersion;
    final visitorData =
        _firstRegexGroup(html, RegExp(r'"VISITOR_DATA":"([^"]+)"')) ?? '';
    final hl = _firstRegexGroup(html, RegExp(r'"HL":"([^"]+)"')) ?? 'en';
    final gl = _firstRegexGroup(html, RegExp(r'"GL":"([^"]+)"')) ?? 'US';

    return _YtmBootstrapCache(
      apiKey: apiKey,
      clientVersion: clientVersion,
      visitorData: visitorData,
      hl: hl,
      gl: gl,
      timestamp: DateTime.now(),
    );
  }

  static String? _firstRegexGroup(String input, RegExp pattern) {
    final match = pattern.firstMatch(input);
    if (match == null || match.groupCount < 1) return null;
    return match.group(1);
  }

  static Future<List<SaavnSong>> _searchViaYoutubeExplodeWithFallback({
    required String query,
    required String originalQuery,
    required bool artistQuery,
    required int take,
  }) async {
    try {
      return await _search(
        query: query,
        originalQuery: originalQuery,
        artistQuery: artistQuery,
        take: take,
        timeout: _searchTimeout,
      );
    } catch (_) {
      final fallbackTake = take >= 24 ? 22 : take;
      return _search(
        query: query,
        originalQuery: originalQuery,
        artistQuery: artistQuery,
        take: fallbackTake,
        timeout: _searchFallbackTimeout,
      );
    }
  }

  static Future<List<SaavnSong>> relatedSongs(
    String videoId, {
    int take = 10,
  }) async {
    final normalized = videoId.trim();
    if (normalized.isEmpty) return const [];

    final safeTake = take.clamp(1, 50);
    final cacheKey = '${normalized.toLowerCase()}::$safeTake';

    final cached = _relatedCache[cacheKey];
    if (cached != null && !cached.isExpired(const Duration(minutes: 5))) {
      return cached.songs;
    }

    List<SaavnSong> songs;
    try {
      songs = await _related(
        videoId: normalized,
        take: safeTake,
        timeout: _relatedTimeout,
      );
    } catch (_) {
      final fallbackTake = (safeTake - 2).clamp(1, safeTake);
      songs = await _related(
        videoId: normalized,
        take: fallbackTake,
        timeout: _relatedFallbackTimeout,
      );
    }

    final normalizedSongs = List<SaavnSong>.unmodifiable(songs);
    _relatedCache[cacheKey] = _TimedSongsCache(normalizedSongs);
    _trimCache(_relatedCache, maxEntries: 100);
    return normalizedSongs;
  }

  static Future<List<YtmChart>> charts({
    int take = 10,
    bool forceRefresh = false,
  }) async {
    final safeTake = take.clamp(1, 20);
    final cacheKey = 'ytm_charts::$safeTake';

    if (!forceRefresh) {
      final cached = _chartsCache[cacheKey];
      if (cached != null && !cached.isExpired(const Duration(minutes: 45))) {
        return cached.charts;
      }
    }

    final bootstrap = await _getYtmBootstrap();
    final payload = await _postYtmBrowse(
      bootstrap: bootstrap,
      browseId: 'FEmusic_charts',
      timeout: _chartsTimeout,
    );

    final parsed = _parseYtmCharts(payload, take: safeTake);
    final immutable = List<YtmChart>.unmodifiable(parsed);
    _chartsCache[cacheKey] = _TimedChartsCache(immutable);
    _trimChartsCache(maxEntries: 16);
    return immutable;
  }

  static Future<List<YtmAlbum>> trendingAlbums({
    int take = 10,
    bool forceRefresh = false,
  }) async {
    final safeTake = take.clamp(1, 20);
    final cacheKey = 'ytm_trending_albums::$safeTake';

    if (!forceRefresh) {
      final cached = _albumsCache[cacheKey];
      if (cached != null && !cached.isExpired(_trendingAlbumsCacheTtl)) {
        return cached.albums;
      }
    }

    final collected = <YtmAlbum>[];
    final seen = <String>{};
    _YtmBootstrapCache? bootstrap;

    try {
      bootstrap = await _getYtmBootstrap();
    } catch (_) {
      bootstrap = null;
    }

    void appendAlbums(List<YtmAlbum> albums) {
      for (final album in albums) {
        final dedupKey = album.browseId.toLowerCase();
        if (!seen.add(dedupKey)) continue;
        collected.add(album);
        if (collected.length >= safeTake) break;
      }
    }

    if (bootstrap != null) {
      try {
        final homePayload = await _postYtmBrowse(
          bootstrap: bootstrap,
          browseId: 'FEmusic_home',
          timeout: _chartsTimeout,
        );

        // 1) Main priority: "Albums for you".
        appendAlbums(
          _parseYtmAlbumsFromShelves(
            homePayload,
            take: safeTake * 3,
            preferredOnly: true,
          ),
        );

        // 2) Same payload, now include other ranked shelves too.
        if (collected.length < safeTake) {
          appendAlbums(
            _parseYtmAlbumsFromShelves(
              homePayload,
              take: safeTake * 4,
              preferredOnly: false,
            ),
          );
        }
      } catch (_) {
        // Continue to next fallback.
      }
    }

    if (collected.length < safeTake && bootstrap != null) {
      try {
        final explorePayload = await _postYtmBrowse(
          bootstrap: bootstrap,
          browseId: 'FEmusic_explore',
          timeout: _chartsTimeout,
        );
        appendAlbums(
          _parseYtmAlbumsFromShelves(
            explorePayload,
            take: safeTake * 4,
            preferredOnly: false,
          ),
        );
      } catch (_) {
        // Continue to search fallbacks.
      }
    }

    if (collected.length < safeTake && bootstrap != null) {
      const fallbackQueries = <String>[
        'Albums For You',
        'Easy Mornings',
        "Today's Global Hits",
        "India's Biggest Hits",
        'New Releases',
        'popular music albums',
        'top albums',
      ];

      for (final query in fallbackQueries) {
        if (collected.length >= safeTake) break;
        try {
          final searched = await _searchAlbumsViaYtm(
            bootstrap: bootstrap,
            query: query,
            take: safeTake * 2,
          );
          appendAlbums(searched);
        } catch (_) {
          // Try next query.
        }
      }
    }

    // Last-resort fallback: convert charts into album entries to avoid empty UI.
    if (collected.isEmpty) {
      try {
        final chartFallback = await charts(
          take: safeTake,
          forceRefresh: forceRefresh,
        );
        appendAlbums(
          chartFallback
              .map(
                (c) => YtmAlbum(
                  browseId: c.browseId,
                  title: c.title,
                  subtitle: c.subtitle,
                  imageUrl: c.imageUrl,
                ),
              )
              .toList(growable: false),
        );
      } catch (_) {
        // Keep empty only if all fallbacks fail.
      }
    }

    final immutable = List<YtmAlbum>.unmodifiable(
      collected.take(safeTake).toList(growable: false),
    );
    if (immutable.isNotEmpty) {
      _albumsCache[cacheKey] = _TimedAlbumsCache(immutable);
      _trimAlbumsCache(maxEntries: 16);
    } else {
      _albumsCache.remove(cacheKey);
    }
    return immutable;
  }

  static Future<List<YtmArtist>> trendingArtists({
    int take = 12,
    bool forceRefresh = false,
  }) async {
    final safeTake = take.clamp(1, 30);
    final cacheKey = 'ytm_trending_artists::$safeTake';

    if (!forceRefresh) {
      final cached = _artistsCache[cacheKey];
      if (cached != null && !cached.isExpired(const Duration(minutes: 45))) {
        return cached.artists;
      }
    }

    final collected = <YtmArtist>[];
    final seen = <String>{};
    _YtmBootstrapCache? bootstrap;

    try {
      bootstrap = await _getYtmBootstrap();
    } catch (_) {
      bootstrap = null;
    }

    Future<void> collectFromPayload(
      Map<String, dynamic> payload, {
      required bool preferredOnly,
      required int takeMultiplier,
    }) async {
      final parsed = _parseYtmArtistsFromShelves(
        payload,
        take: safeTake * takeMultiplier,
        preferredOnly: preferredOnly,
      );
      for (final artist in parsed) {
        final dedupKey = artist.browseId.toLowerCase();
        if (!seen.add(dedupKey)) continue;
        collected.add(artist);
        if (collected.length >= safeTake) break;
      }
    }

    if (bootstrap != null) {
      try {
        final homePayload = await _postYtmBrowse(
          bootstrap: bootstrap,
          browseId: 'FEmusic_home',
          timeout: _chartsTimeout,
        );
        await collectFromPayload(
          homePayload,
          preferredOnly: true,
          takeMultiplier: 3,
        );
        if (collected.isEmpty) {
          await collectFromPayload(
            homePayload,
            preferredOnly: false,
            takeMultiplier: 3,
          );
        }
      } catch (_) {
        // Continue to fallbacks.
      }
    }

    if (collected.isEmpty && bootstrap != null) {
      try {
        final explorePayload = await _postYtmBrowse(
          bootstrap: bootstrap,
          browseId: 'FEmusic_explore',
          timeout: _chartsTimeout,
        );
        await collectFromPayload(
          explorePayload,
          preferredOnly: false,
          takeMultiplier: 3,
        );
      } catch (_) {
        // Continue to search fallback.
      }
    }

    if (collected.isEmpty && bootstrap != null) {
      try {
        final searchPayload = await _postYtmSearch(
          bootstrap: bootstrap,
          query: 'popular artists',
          useSongsParams: false,
          timeout: _ytmSearchTimeout,
        );
        final parsed = _parseYtmArtistsFromSearchResults(
          searchPayload,
          take: safeTake * 2,
        );
        for (final artist in parsed) {
          final dedupKey = artist.browseId.toLowerCase();
          if (!seen.add(dedupKey)) continue;
          collected.add(artist);
          if (collected.length >= safeTake) break;
        }
      } catch (_) {
        // Keep empty on failure.
      }
    }

    if (collected.isEmpty) {
      try {
        final explodeArtists = await _trendingArtistsViaYoutubeExplode(
          take: safeTake,
        );
        for (final artist in explodeArtists) {
          final dedupKey = artist.browseId.toLowerCase();
          if (!seen.add(dedupKey)) continue;
          collected.add(artist);
          if (collected.length >= safeTake) break;
        }
      } catch (_) {
        // Keep empty if explode fallback fails.
      }
    }

    final immutable = List<YtmArtist>.unmodifiable(
      collected.take(safeTake).toList(growable: false),
    );
    if (immutable.isNotEmpty) {
      _artistsCache[cacheKey] = _TimedArtistsCache(immutable);
      _trimArtistsCache(maxEntries: 16);
    } else {
      _artistsCache.remove(cacheKey);
    }
    return immutable;
  }

  static Future<List<SaavnSong>> artistSongs(
    String artistBrowseId, {
    String? artistName,
    int take = 120,
    bool forceRefresh = false,
  }) async {
    final normalized = artistBrowseId.trim();
    if (normalized.isEmpty) return const [];

    final safeTake = take.clamp(10, 300);
    final cacheKey = '${normalized.toLowerCase()}::$safeTake';
    if (!forceRefresh) {
      final cached = _artistSongsCache[cacheKey];
      if (cached != null && !cached.isExpired(const Duration(minutes: 20))) {
        return cached.songs;
      }
    }

    List<SaavnSong> songs;
    try {
      songs = await _artistSongsViaYtm(
        artistBrowseId: normalized,
        take: safeTake,
      );
    } catch (_) {
      songs = const [];
    }
    if (songs.isEmpty && artistName != null && artistName.trim().isNotEmpty) {
      try {
        final fallback = await _searchViaYtm(
          query: artistName.trim(),
          take: safeTake,
        );
        final filtered = fallback
            .where((song) => _artistNameMatchesSong(song, artistName))
            .toList(growable: false);
        songs = filtered.isNotEmpty
            ? filtered.take(safeTake).toList(growable: false)
            : fallback.take(safeTake).toList(growable: false);
      } catch (_) {
        // Keep empty result if fallback search fails.
      }
    }
    final immutable = List<SaavnSong>.unmodifiable(songs);
    _artistSongsCache[cacheKey] = _TimedSongsCache(immutable);
    _trimCache(_artistSongsCache, maxEntries: 100);
    return immutable;
  }

  static Future<List<SaavnSong>> _artistSongsViaYtm({
    required String artistBrowseId,
    required int take,
  }) async {
    final bootstrap = await _getYtmBootstrap();
    final payload = await _postYtmBrowse(
      bootstrap: bootstrap,
      browseId: artistBrowseId,
      timeout: _chartSongsTimeout,
    );

    final renderers = <Map<String, dynamic>>[];
    _collectMapsByKey(payload, 'musicResponsiveListItemRenderer', renderers);

    final songs = <SaavnSong>[];
    final seen = <String>{};
    for (final renderer in renderers) {
      final mapped = _mapYtmRendererToSong(renderer);
      if (mapped == null) continue;
      if (!seen.add(mapped.id)) continue;
      songs.add(mapped);
      if (songs.length >= take) break;
    }
    return songs.take(take).toList(growable: false);
  }

  static bool _artistNameMatchesSong(SaavnSong song, String artistName) {
    final artistTokens = artistName
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.length >= 3)
        .toList(growable: false);
    if (artistTokens.isEmpty) return true;

    final songArtists = song.artists.toLowerCase();
    for (final token in artistTokens) {
      if (songArtists.contains(token)) return true;
    }
    return false;
  }

  static Future<List<YtmArtist>> _searchArtistsViaYoutubeExplode({
    required String query,
    required int take,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];

    final out = <YtmArtist>[];
    final seen = <String>{};
    final queries = <String>[
      normalized,
      '$normalized artist',
      '$normalized topic',
    ];
    final seenQueries = <String>{};

    for (final q in queries) {
      if (out.length >= take) break;
      final effectiveQuery = q.trim();
      if (effectiveQuery.isEmpty) continue;
      if (!seenQueries.add(effectiveQuery.toLowerCase())) continue;

      try {
        final firstPage = await _yt.search
            .searchContent(effectiveQuery, filter: TypeFilters.channel)
            .timeout(_searchFallbackTimeout);
        final channels = <SearchChannel>[
          ...firstPage.whereType<SearchChannel>(),
        ];
        var currentPage = firstPage;
        var pageGuard = 0;

        while (channels.length < take * 3 && pageGuard < 1) {
          final nextPage = await currentPage.nextPage().timeout(
            _searchFallbackTimeout,
          );
          if (nextPage == null || nextPage.isEmpty) break;
          channels.addAll(nextPage.whereType<SearchChannel>());
          currentPage = nextPage;
          pageGuard++;
        }

        for (final item in channels) {
          final id = item.id.value.trim();
          final name = item.name.trim();
          if (id.isEmpty || name.isEmpty) continue;
          if (!seen.add(id.toLowerCase())) continue;

          out.add(
            YtmArtist(
              browseId: id,
              name: name,
              subtitle: 'Artist',
              imageUrl: _bestExplodeChannelThumbnail(item.thumbnails),
            ),
          );
          if (out.length >= take) break;
        }
      } catch (_) {
        continue;
      }
    }

    return out.take(take).toList(growable: false);
  }

  static YtmArtist _pickBestArtistCandidate(
    List<YtmArtist> candidates,
    String artistName,
  ) {
    if (candidates.isEmpty) {
      return const YtmArtist(
        browseId: '',
        name: '',
        subtitle: 'Artist',
        imageUrl: '',
      );
    }

    final target = artistName.toLowerCase().trim();
    if (target.isEmpty) return candidates.first;

    int score(YtmArtist artist) {
      final name = artist.name.toLowerCase().trim();
      var value = 0;
      if (name == target) value += 100;
      if (name.contains(target)) value += 40;
      if (target.contains(name) && name.isNotEmpty) value += 25;
      if (name.startsWith(target)) value += 18;
      if (artist.subtitle.toLowerCase().contains('artist')) value += 10;
      if (artist.browseId.toUpperCase().startsWith('UC')) value += 6;
      return value;
    }

    final sorted = [...candidates]
      ..sort((a, b) => score(b).compareTo(score(a)));
    return sorted.first;
  }

  static Future<List<YtmArtist>> _trendingArtistsViaYoutubeExplode({
    required int take,
  }) async {
    final queries = <String>[
      'popular music artists official channels',
      'top singers official artist channels',
      'music artists topic channels',
    ];
    final out = <YtmArtist>[];
    final seen = <String>{};

    for (final query in queries) {
      try {
        final firstPage = await _yt.search
            .searchContent(query, filter: TypeFilters.channel)
            .timeout(_searchFallbackTimeout);
        final channels = <SearchChannel>[
          ...firstPage.whereType<SearchChannel>(),
        ];
        var currentPage = firstPage;
        var pageGuard = 0;

        while (channels.length < take * 3 && pageGuard < 1) {
          final nextPage = await currentPage.nextPage().timeout(
            _searchFallbackTimeout,
          );
          if (nextPage == null || nextPage.isEmpty) break;
          channels.addAll(nextPage.whereType<SearchChannel>());
          currentPage = nextPage;
          pageGuard++;
        }

        for (final item in channels) {
          final id = item.id.value.trim();
          final name = item.name.trim();
          if (id.isEmpty || name.isEmpty) continue;
          if (!seen.add(id.toLowerCase())) continue;

          final imageUrl = _bestExplodeChannelThumbnail(item.thumbnails);
          out.add(
            YtmArtist(
              browseId: id,
              name: name,
              subtitle: 'Artist',
              imageUrl: imageUrl,
            ),
          );
          if (out.length >= take) {
            return out.take(take).toList(growable: false);
          }
        }
      } catch (_) {
        // Continue with the next query.
      }
    }

    return out.take(take).toList(growable: false);
  }

  static String _bestExplodeChannelThumbnail(List<Thumbnail> thumbs) {
    if (thumbs.isEmpty) return '';

    Thumbnail? bestSquare;
    var bestSquareArea = -1;
    Thumbnail? bestAny;
    var bestAnyArea = -1;

    for (final thumb in thumbs) {
      final width = thumb.width;
      final height = thumb.height;
      if (width <= 0 || height <= 0) continue;

      final area = width * height;
      final ratio = width / height;
      final isSquareish = ratio >= 0.8 && ratio <= 1.25;

      if (isSquareish && area > bestSquareArea) {
        bestSquare = thumb;
        bestSquareArea = area;
      }
      if (area > bestAnyArea) {
        bestAny = thumb;
        bestAnyArea = area;
      }
    }

    return (bestSquare ?? bestAny)?.url.toString() ?? '';
  }

  static Future<List<SaavnSong>> chartSongs(
    String chartId, {
    int take = 120,
    bool forceRefresh = false,
    bool resolveArtworkFallback = true,
  }) async {
    final normalized = chartId.trim();
    if (normalized.isEmpty) return const [];

    final safeTake = take.clamp(10, 300);
    final cacheKey =
        '${normalized.toLowerCase()}::$safeTake::${resolveArtworkFallback ? "art" : "raw"}';

    if (!forceRefresh) {
      final cached = _chartSongsCache[cacheKey];
      if (cached != null && !cached.isExpired(const Duration(minutes: 20))) {
        return cached.songs;
      }
    }

    List<SaavnSong> ytmSongs = const [];
    try {
      ytmSongs = await _chartSongsViaYtm(chartId: normalized, take: safeTake);
    } catch (_) {
      ytmSongs = const [];
    }

    List<SaavnSong> fallbackSongs = const [];
    if (ytmSongs.isEmpty) {
      try {
        final playlistFallbackId = _toPlaylistIdForFallback(normalized);
        if (playlistFallbackId.isNotEmpty) {
          fallbackSongs = await _chartSongsViaPlaylistVideos(
            playlistId: playlistFallbackId,
            take: safeTake,
          );
        }
      } catch (_) {
        if (ytmSongs.isEmpty) rethrow;
      }
    }

    var songs = _mergeWithDedup(ytmSongs, fallbackSongs, safeTake);
    songs = _applySessionArtworkOverrides(songs);
    if (resolveArtworkFallback && songs.isNotEmpty) {
      try {
        songs = await _withSearchArtworkFallback(songs);
      } catch (_) {
        // Keep base songs if artwork fallback fails.
      }
    }

    final immutable = List<SaavnSong>.unmodifiable(songs);
    _chartSongsCache[cacheKey] = _TimedSongsCache(immutable);
    _trimCache(_chartSongsCache, maxEntries: 100);
    return immutable;
  }

  static Future<List<SaavnSong>> _chartSongsViaYtm({
    required String chartId,
    required int take,
  }) async {
    final browseId = _toYtmBrowseId(chartId);
    final bootstrap = await _getYtmBootstrap();
    final payload = await _postYtmBrowse(
      bootstrap: bootstrap,
      browseId: browseId,
      timeout: _chartSongsTimeout,
    );

    final renderers = <Map<String, dynamic>>[];
    _collectMapsByKey(payload, 'musicResponsiveListItemRenderer', renderers);

    final songs = <SaavnSong>[];
    final seen = <String>{};
    for (final renderer in renderers) {
      final mapped = _mapYtmRendererToSong(renderer);
      if (mapped == null) continue;
      if (!seen.add(mapped.id)) continue;
      songs.add(mapped);
      if (songs.length >= take) break;
    }

    return songs.take(take).toList(growable: false);
  }

  static Future<List<SaavnSong>> resolveSongArtworkFallback(
    List<SaavnSong> songs,
  ) async {
    if (songs.isEmpty) return const [];
    return _withSearchArtworkFallback(List<SaavnSong>.from(songs));
  }

  static Future<SaavnSong> resolveSingleSongArtworkFallback(
    SaavnSong song,
  ) async {
    final cacheKey = _sessionArtworkKeyForSong(song);
    final cachedUrl = _sessionSongArtworkOverrides[cacheKey];
    if (cachedUrl != null && cachedUrl.trim().isNotEmpty) {
      if (cachedUrl.trim() == song.imageUrl.trim()) return song;
      return SaavnSong(
        id: song.id,
        name: song.name,
        artists: song.artists,
        imageUrl: cachedUrl,
        duration: song.duration,
        downloadUrls: song.downloadUrls,
      );
    }

    if (!_needsSearchArtworkFallback(song.imageUrl)) return song;

    final query = '${song.name} ${song.artists}'.trim();
    if (query.isEmpty) return song;

    final matches = await _searchViaYtm(query: query, take: 6);
    final picked = _pickArtworkFallbackSong(seed: song, matches: matches);
    if (picked == null) return song;
    if (picked.imageUrl.trim().isEmpty) return song;
    if (_needsSearchArtworkFallback(picked.imageUrl)) return song;

    _rememberSessionArtworkOverride(cacheKey, picked.imageUrl.trim());
    return SaavnSong(
      id: song.id,
      name: song.name,
      artists: song.artists,
      imageUrl: picked.imageUrl,
      duration: song.duration,
      downloadUrls: song.downloadUrls,
    );
  }

  static Future<List<SaavnSong>> _withSearchArtworkFallback(
    List<SaavnSong> songs,
  ) async {
    if (songs.isEmpty) return const [];

    final upgraded = List<SaavnSong>.from(songs);
    var lookups = 0;

    for (var i = 0; i < upgraded.length; i++) {
      final seed = upgraded[i];
      if (!_needsSearchArtworkFallback(seed.imageUrl)) continue;
      if (lookups >= _maxChartArtworkFallbackLookups) break;
      lookups++;

      try {
        upgraded[i] = await resolveSingleSongArtworkFallback(seed);
      } catch (_) {
        // Keep original artwork when fallback lookup fails.
      }
    }

    return upgraded;
  }

  static bool _needsSearchArtworkFallback(String imageUrl) {
    return YoutubeThumbnailUtils.isLikelyLowQualityArtwork(imageUrl);
  }

  static List<SaavnSong> _applySessionArtworkOverrides(List<SaavnSong> songs) {
    if (songs.isEmpty || _sessionSongArtworkOverrides.isEmpty) return songs;

    final out = <SaavnSong>[];
    for (final song in songs) {
      final key = _sessionArtworkKeyForSong(song);
      final cachedUrl = _sessionSongArtworkOverrides[key];
      if (cachedUrl == null || cachedUrl.trim().isEmpty) {
        out.add(song);
        continue;
      }
      if (cachedUrl.trim() == song.imageUrl.trim()) {
        out.add(song);
        continue;
      }
      out.add(
        SaavnSong(
          id: song.id,
          name: song.name,
          artists: song.artists,
          imageUrl: cachedUrl,
          duration: song.duration,
          downloadUrls: song.downloadUrls,
        ),
      );
    }
    return out;
  }

  static String _sessionArtworkKeyForSong(SaavnSong song) {
    final id = song.id.trim().toLowerCase();
    if (id.isNotEmpty) return id;
    final title = song.name.trim().toLowerCase();
    final artist = song.artists.trim().toLowerCase();
    return '$title::$artist';
  }

  static void _rememberSessionArtworkOverride(String key, String imageUrl) {
    if (key.trim().isEmpty || imageUrl.trim().isEmpty) return;
    _sessionSongArtworkOverrides[key] = imageUrl;
    if (_sessionSongArtworkOverrides.length <=
        _maxSessionSongArtworkOverrides) {
      return;
    }

    final overflow =
        _sessionSongArtworkOverrides.length - _maxSessionSongArtworkOverrides;
    if (overflow <= 0) return;

    final keys = _sessionSongArtworkOverrides.keys.toList(growable: false);
    for (var i = 0; i < overflow && i < keys.length; i++) {
      _sessionSongArtworkOverrides.remove(keys[i]);
    }
  }

  static SaavnSong? _pickArtworkFallbackSong({
    required SaavnSong seed,
    required List<SaavnSong> matches,
  }) {
    if (matches.isEmpty) return null;

    final seedTitleTokens = _tokenizeForArtwork(seed.name);
    final seedArtistTokens = _tokenizeForArtwork(seed.artists);

    SaavnSong? best;
    var bestScore = -1;

    for (final candidate in matches) {
      final art = candidate.imageUrl.trim();
      if (art.isEmpty) continue;

      var score = 0;
      if (YoutubeThumbnailUtils.isYtmArtworkUrl(art)) score += 8;
      if (!_needsSearchArtworkFallback(art)) score += 6;

      final candidateTitleTokens = _tokenizeForArtwork(candidate.name);
      final candidateArtistTokens = _tokenizeForArtwork(candidate.artists);
      score += _tokenOverlap(seedTitleTokens, candidateTitleTokens) * 4;
      score += _tokenOverlap(seedArtistTokens, candidateArtistTokens) * 3;

      if (candidate.id == seed.id) score += 3;
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }

    return best;
  }

  static List<String> _tokenizeForArtwork(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where((token) => token.length >= 3)
        .where(
          (token) => !{
            'feat',
            'from',
            'with',
            'official',
            'audio',
            'video',
            'song',
            'music',
            'the',
            'and',
          }.contains(token),
        )
        .toList(growable: false);
  }

  static int _tokenOverlap(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final setB = b.toSet();
    var count = 0;
    for (final token in a) {
      if (setB.contains(token)) count++;
    }
    return count;
  }

  static Future<List<SaavnSong>> _chartSongsViaPlaylistVideos({
    required String playlistId,
    required int take,
  }) async {
    final videos = await _yt.playlists
        .getVideos(playlistId)
        .take(take * 2)
        .toList()
        .timeout(_chartSongsTimeout);

    final strict = <SaavnSong>[];
    final strictSeen = <String>{};
    final relaxed = <SaavnSong>[];
    final relaxedSeen = <String>{};

    for (final video in videos) {
      final strictMapped = _mapVideoToSong(video, query: '', strictMode: true);
      if (strictMapped != null) {
        if (strictSeen.add(strictMapped.id)) {
          strict.add(strictMapped);
        }
        if (strict.length >= take) break;
        continue;
      }

      final relaxedMapped = _mapVideoToSong(
        video,
        query: '',
        strictMode: false,
      );
      if (relaxedMapped == null) continue;
      if (strictSeen.contains(relaxedMapped.id)) continue;
      if (relaxedSeen.add(relaxedMapped.id)) {
        relaxed.add(relaxedMapped);
      }
    }

    return _mergeWithDedup(strict, relaxed, take);
  }

  static Future<List<SaavnSong>> _search({
    required String query,
    required String originalQuery,
    required bool artistQuery,
    required int take,
    required Duration timeout,
  }) async {
    final fetchTarget = (take * 2).clamp(take, 40);
    final videos = await _collectSearchVideos(
      query: query,
      targetCount: fetchTarget,
      timeout: timeout,
    );

    final strict = <SaavnSong>[];
    final relaxed = <SaavnSong>[];
    for (final video in videos) {
      final strictMapped = _mapVideoToSong(
        video,
        query: originalQuery,
        strictMode: !artistQuery,
      );
      if (strictMapped != null) {
        if (artistQuery) {
          if (_isArtistChannelMatch(video.author, originalQuery)) {
            strict.add(strictMapped);
          } else {
            relaxed.add(strictMapped);
          }
        } else {
          strict.add(strictMapped);
        }
        continue;
      }

      if (!artistQuery) {
        final relaxedMapped = _mapVideoToSong(
          video,
          query: originalQuery,
          strictMode: false,
        );
        if (relaxedMapped != null) relaxed.add(relaxedMapped);
      }
    }

    return _mergeWithDedup(strict, relaxed, take);
  }

  static Future<List<SaavnSong>> _related({
    required String videoId,
    required int take,
    required Duration timeout,
  }) async {
    final video = await _yt.videos.get(videoId).timeout(timeout);
    var related = await _yt.videos.getRelatedVideos(video).timeout(timeout);
    if (related == null || related.isEmpty) return const [];

    final strict = <SaavnSong>[];
    final strictSeen = <String>{};
    final relaxed = <SaavnSong>[];
    final relaxedSeen = <String>{};
    RelatedVideosList? current = related;
    var pageGuard = 0;

    while (current != null && strict.length < take && pageGuard < 3) {
      final page = current;
      for (final item in page) {
        final strictMapped = _mapVideoToSong(item, query: '', strictMode: true);
        if (strictMapped != null) {
          if (strictSeen.add(strictMapped.id)) {
            strict.add(strictMapped);
          }
          if (strict.length >= take) break;
          continue;
        }

        final relaxedMapped = _mapVideoToSong(
          item,
          query: '',
          strictMode: false,
        );
        if (relaxedMapped == null) continue;
        if (strictSeen.contains(relaxedMapped.id)) continue;
        if (relaxedSeen.add(relaxedMapped.id)) {
          relaxed.add(relaxedMapped);
        }
      }
      if (strict.length >= take) break;
      current = await page.nextPage().timeout(timeout);
      pageGuard++;
    }

    return _mergeWithDedup(strict, relaxed, take);
  }

  static Future<List<Video>> _collectSearchVideos({
    required String query,
    required int targetCount,
    required Duration timeout,
  }) async {
    final firstPage = await _yt.search
        .search(query, filter: TypeFilters.video)
        .timeout(timeout);
    final collected = <Video>[...firstPage];
    var currentPage = firstPage;
    var pageGuard = 0;

    while (collected.length < targetCount && pageGuard < 2) {
      final nextPage = await currentPage.nextPage().timeout(timeout);
      if (nextPage == null || nextPage.isEmpty) break;
      collected.addAll(nextPage);
      currentPage = nextPage;
      pageGuard++;
    }

    return collected;
  }

  static List<SaavnSong> _mergeWithDedup(
    List<SaavnSong> strict,
    List<SaavnSong> relaxed,
    int take,
  ) {
    final out = <SaavnSong>[];
    final seen = <String>{};

    for (final song in strict) {
      if (seen.add(song.id)) out.add(song);
      if (out.length >= take) return out;
    }

    for (final song in relaxed) {
      if (seen.add(song.id)) out.add(song);
      if (out.length >= take) return out;
    }

    return out;
  }

  static SaavnSong? _mapVideoToSong(
    Video video, {
    required String query,
    required bool strictMode,
  }) {
    final idRaw = video.id.value.trim();
    final title = video.title.trim();
    final artist = video.author.trim();

    if (idRaw.isEmpty || title.isEmpty) return null;

    if (!_isLikelyMusicResult(
      title: title,
      author: artist,
      duration: video.duration,
      query: query,
      strictMode: strictMode,
      isLive: video.isLive,
    )) {
      return null;
    }

    final imageUrl = YoutubeThumbnailUtils.bestInitialUrl(
      videoId: idRaw,
      preferredUrl: video.thumbnails.highResUrl,
    );

    return SaavnSong(
      id: 'yt:$idRaw',
      name: title,
      artists: artist.isEmpty ? 'Unknown' : artist,
      imageUrl: imageUrl,
      duration: video.duration?.inSeconds,
      downloadUrls: const [],
    );
  }

  static String _buildMusicSearchQuery(String query) {
    final q = query.trim();
    if (q.isEmpty) return q;
    if (_isLikelyArtistQuery(q)) return '$q topic';

    final lower = q.toLowerCase();
    const musicHints = <String>[
      'song',
      'songs',
      'music',
      'lyrics',
      'lyric',
      'audio',
      'album',
      'track',
      'remix',
      'cover',
      'ost',
      'soundtrack',
      'instrumental',
      'live',
    ];
    final hasHint = musicHints.any(lower.contains);
    return hasHint ? q : '$q song';
  }

  static bool _isLikelyArtistQuery(String query) {
    final q = query.trim();
    if (q.isEmpty) return false;

    final lower = q.toLowerCase();
    const musicHint = <String>[
      'song',
      'songs',
      'music',
      'lyrics',
      'lyric',
      'audio',
      'album',
      'track',
      'playlist',
      'mix',
      'remix',
      'cover',
      'ost',
      'soundtrack',
      'live',
    ];
    if (musicHint.any(lower.contains)) return false;

    final words = q.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (words.length < 2 || words.length > 4) return false;
    if (q.contains(RegExp(r'\d'))) return false;
    return q.contains(RegExp(r"^[A-Za-z'&.\- ]+$"));
  }

  static bool _isArtistChannelMatch(String author, String query) {
    final a = author.toLowerCase();
    final tokens = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.length >= 3)
        .toList();
    if (tokens.isEmpty) return false;

    final matches = tokens.where(a.contains).length;
    if (matches >= 2) return true;
    if (matches >= 1 &&
        (a.contains('- topic') ||
            a.contains('vevo') ||
            a.contains('official'))) {
      return true;
    }
    return false;
  }

  static bool _isLikelyMusicResult({
    required String title,
    required String author,
    required Duration? duration,
    required String query,
    required bool strictMode,
    required bool isLive,
  }) {
    final t = title.toLowerCase();
    final a = author.toLowerCase();
    final q = query.toLowerCase();

    const blockedTokens = <String>[
      'full movie',
      'episode',
      'podcast',
      'reaction',
      'review',
      'interview',
      'news',
      'trailer',
      'teaser',
      'shorts',
      'gameplay',
      'walkthrough',
      'tutorial',
      'how to',
      'lecture',
      'speech',
      'sermon',
      'comedy',
      'prank',
      'vlog',
    ];
    if (blockedTokens.any(t.contains)) return false;
    if (strictMode && isLive && !q.contains('live')) return false;

    final seconds = duration?.inSeconds;
    if (seconds != null) {
      if (seconds <= 59) return false;
      if (seconds > 15 * 60) return false;
      if (strictMode &&
          seconds > 10 * 60 &&
          !q.contains('live') &&
          !q.contains('mix')) {
        return false;
      }
    } else if (strictMode) {
      return false;
    }

    const likelyNonMusicChannels = <String>[
      'news',
      'podcast',
      'tv',
      'interview',
    ];
    if (strictMode && likelyNonMusicChannels.any(a.contains)) return false;

    final queryTokens = q
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.length >= 3)
        .where(
          (e) => !{
            'the',
            'and',
            'for',
            'song',
            'music',
            'video',
            'audio',
          }.contains(e),
        )
        .toList();
    if (strictMode && queryTokens.isNotEmpty) {
      final matches = queryTokens
          .where((token) => t.contains(token) || a.contains(token))
          .length;
      if (matches == 0) return false;
    }

    const musicSignals = <String>[
      'official audio',
      'audio',
      'lyrics',
      'lyric',
      'music video',
      'visualizer',
      'remix',
      'cover',
      'ost',
      'soundtrack',
      'topic',
    ];
    final hasMusicSignal =
        musicSignals.any(t.contains) ||
        a.contains('- topic') ||
        a.contains('vevo');

    if (strictMode &&
        !hasMusicSignal &&
        seconds != null &&
        (seconds < 90 || seconds > 480)) {
      return false;
    }

    return true;
  }

  static void _trimCache(
    Map<String, _TimedSongsCache> cache, {
    required int maxEntries,
  }) {
    if (cache.length <= maxEntries) return;
    final keys = cache.keys.toList(growable: false);
    final removeCount = cache.length - maxEntries;
    for (var i = 0; i < removeCount; i++) {
      cache.remove(keys[i]);
    }
  }

  static void _trimChartsCache({required int maxEntries}) {
    if (_chartsCache.length <= maxEntries) return;
    final keys = _chartsCache.keys.toList(growable: false);
    final removeCount = _chartsCache.length - maxEntries;
    for (var i = 0; i < removeCount; i++) {
      _chartsCache.remove(keys[i]);
    }
  }

  static void _trimAlbumsCache({required int maxEntries}) {
    if (_albumsCache.length <= maxEntries) return;
    final keys = _albumsCache.keys.toList(growable: false);
    final removeCount = _albumsCache.length - maxEntries;
    for (var i = 0; i < removeCount; i++) {
      _albumsCache.remove(keys[i]);
    }
  }

  static void _trimArtistsCache({required int maxEntries}) {
    if (_artistsCache.length <= maxEntries) return;
    final keys = _artistsCache.keys.toList(growable: false);
    final removeCount = _artistsCache.length - maxEntries;
    for (var i = 0; i < removeCount; i++) {
      _artistsCache.remove(keys[i]);
    }
  }

  static void _trimArtistProfileCache({required int maxEntries}) {
    if (_artistProfileCache.length <= maxEntries) return;
    final keys = _artistProfileCache.keys.toList(growable: false);
    final removeCount = _artistProfileCache.length - maxEntries;
    for (var i = 0; i < removeCount; i++) {
      _artistProfileCache.remove(keys[i]);
    }
  }
}

class _TimedSongsCache {
  final DateTime timestamp;
  final List<SaavnSong> songs;

  _TimedSongsCache(this.songs) : timestamp = DateTime.now();

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(timestamp) > ttl;
  }
}

class _TimedChartsCache {
  final DateTime timestamp;
  final List<YtmChart> charts;

  _TimedChartsCache(this.charts) : timestamp = DateTime.now();

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(timestamp) > ttl;
  }
}

class _TimedAlbumsCache {
  final DateTime timestamp;
  final List<YtmAlbum> albums;

  _TimedAlbumsCache(this.albums) : timestamp = DateTime.now();

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(timestamp) > ttl;
  }
}

class _TimedArtistsCache {
  final DateTime timestamp;
  final List<YtmArtist> artists;

  _TimedArtistsCache(this.artists) : timestamp = DateTime.now();

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(timestamp) > ttl;
  }
}

class _TimedArtistProfileCache {
  final DateTime timestamp;
  final YtmArtistProfile profile;

  _TimedArtistProfileCache(this.profile) : timestamp = DateTime.now();

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(timestamp) > ttl;
  }
}

class _YtmSongsPage {
  final List<SaavnSong> songs;
  final String? continuation;

  const _YtmSongsPage({required this.songs, this.continuation});
  const _YtmSongsPage.empty() : songs = const [], continuation = null;
}

class _YtmBootstrapCache {
  final String apiKey;
  final String clientVersion;
  final String visitorData;
  final String hl;
  final String gl;
  final DateTime timestamp;

  const _YtmBootstrapCache({
    required this.apiKey,
    required this.clientVersion,
    required this.visitorData,
    required this.hl,
    required this.gl,
    required this.timestamp,
  });

  factory _YtmBootstrapCache.fallback() {
    return _YtmBootstrapCache(
      apiKey: YoutubeApi._fallbackYtmApiKey,
      clientVersion: YoutubeApi._fallbackYtmClientVersion,
      visitorData: '',
      hl: 'en',
      gl: 'US',
      timestamp: DateTime.now(),
    );
  }

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(timestamp) > ttl;
  }
}

class YtmChart {
  final String playlistId;
  final String browseId;
  final String title;
  final String subtitle;
  final String imageUrl;
  final int? songCount;

  const YtmChart({
    required this.playlistId,
    required this.browseId,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    this.songCount,
  });
}

class YtmAlbum {
  final String browseId;
  final String title;
  final String subtitle;
  final String imageUrl;

  const YtmAlbum({
    required this.browseId,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
  });
}

class YtmArtist {
  final String browseId;
  final String name;
  final String subtitle;
  final String imageUrl;

  const YtmArtist({
    required this.browseId,
    required this.name,
    required this.subtitle,
    required this.imageUrl,
  });
}

class YtmArtistProfile {
  final String browseId;
  final String name;
  final String imageUrl;
  final String bio;
  final String monthlyAudience;
  final List<SaavnSong> topSongs;
  final List<YtmAlbum> albums;
  final List<YtmAlbum> singlesAndEps;

  const YtmArtistProfile({
    required this.browseId,
    required this.name,
    required this.imageUrl,
    required this.bio,
    required this.monthlyAudience,
    required this.topSongs,
    required this.albums,
    required this.singlesAndEps,
  });
}

class _ArtistHeaderResult {
  final String name;
  final String imageUrl;
  final String bio;
  final String monthlyAudience;

  const _ArtistHeaderResult({
    required this.name,
    required this.imageUrl,
    required this.bio,
    required this.monthlyAudience,
  });
}

enum _ArtistReleaseSection { albums, singlesAndEps }

class _PersistedSearchEntry {
  final String key;
  final DateTime timestamp;
  final List<SaavnSong> songs;

  const _PersistedSearchEntry({
    required this.key,
    required this.timestamp,
    required this.songs,
  });

  Duration get age => DateTime.now().difference(timestamp);

  List<SaavnSong> limitedSongs(int take) {
    return songs.take(take).toList(growable: false);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'key': key,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'songs': songs.map(_songToJson).toList(growable: false),
    };
  }

  static _PersistedSearchEntry? fromJson(Map<String, dynamic> json) {
    final key = (json['key'] ?? '').toString().trim();
    if (key.isEmpty) return null;

    final timestampMs = (json['timestamp'] as num?)?.toInt();
    if (timestampMs == null || timestampMs <= 0) return null;

    final songsRaw = json['songs'];
    if (songsRaw is! List) return null;

    final songs = <SaavnSong>[];
    for (final item in songsRaw) {
      final map = YoutubeApi._asMap(item);
      if (map == null) continue;
      final song = _songFromJson(map);
      if (song != null) songs.add(song);
    }
    if (songs.isEmpty) return null;

    return _PersistedSearchEntry(
      key: key,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
      songs: List<SaavnSong>.unmodifiable(songs),
    );
  }

  static Map<String, dynamic> _songToJson(SaavnSong song) {
    return <String, dynamic>{
      'id': song.id,
      'name': song.name,
      'artists': song.artists,
      'imageUrl': song.imageUrl,
      'duration': song.duration,
      'downloadUrls': song.downloadUrls,
    };
  }

  static SaavnSong? _songFromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? '').toString().trim();
    final name = (json['name'] ?? '').toString().trim();
    final artists = (json['artists'] ?? '').toString().trim();
    if (id.isEmpty || name.isEmpty) return null;

    final imageUrl = (json['imageUrl'] ?? '').toString().trim();
    final duration = (json['duration'] as num?)?.toInt();

    final downloadUrls = <Map<String, String>>[];
    final rawDownloadUrls = json['downloadUrls'];
    if (rawDownloadUrls is List) {
      for (final entry in rawDownloadUrls) {
        final map = YoutubeApi._asMap(entry);
        if (map == null) continue;
        downloadUrls.add(<String, String>{
          'quality': (map['quality'] ?? '').toString(),
          'url': (map['url'] ?? '').toString(),
        });
      }
    }

    return SaavnSong(
      id: id,
      name: name,
      artists: artists.isEmpty ? 'Unknown' : artists,
      imageUrl: imageUrl,
      duration: duration,
      downloadUrls: downloadUrls,
    );
  }
}

class _StrategyHealth {
  static const int _maxCounter = 800;

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
