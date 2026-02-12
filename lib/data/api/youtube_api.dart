import 'dart:async';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/saavn_song.dart';

class YoutubeApi {
  static final YoutubeExplode _yt = YoutubeExplode();

  static const Duration _searchTimeout = Duration(seconds: 10);
  static const Duration _searchFallbackTimeout = Duration(seconds: 7);
  static const Duration _relatedTimeout = Duration(seconds: 10);
  static const Duration _relatedFallbackTimeout = Duration(seconds: 8);

  static final Map<String, _TimedSongsCache> _searchCache = {};
  static final Map<String, _TimedSongsCache> _relatedCache = {};

  static Future<List<SaavnSong>> searchSongs(
    String query, {
    int take = 24,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];

    final safeTake = take.clamp(2, 50);
    final cacheKey = '${normalized.toLowerCase()}::$safeTake';
    final artistQuery = _isLikelyArtistQuery(normalized);
    final effectiveQuery = _buildMusicSearchQuery(normalized);

    final cached = _searchCache[cacheKey];
    if (cached != null && !cached.isExpired(const Duration(minutes: 2))) {
      return cached.songs;
    }

    List<SaavnSong> songs;
    try {
      songs = await _search(
        query: effectiveQuery,
        originalQuery: normalized,
        artistQuery: artistQuery,
        take: safeTake,
        timeout: _searchTimeout,
      );
    } catch (_) {
      final fallbackTake = safeTake >= 24 ? 22 : safeTake;
      songs = await _search(
        query: effectiveQuery,
        originalQuery: normalized,
        artistQuery: artistQuery,
        take: fallbackTake,
        timeout: _searchFallbackTimeout,
      );
    }

    final normalizedSongs = List<SaavnSong>.unmodifiable(songs);
    _searchCache[cacheKey] = _TimedSongsCache(normalizedSongs);
    _trimCache(_searchCache, maxEntries: 60);
    return normalizedSongs;
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

    final out = <SaavnSong>[];
    final seen = <String>{};
    RelatedVideosList? current = related;
    var pageGuard = 0;

    while (current != null && out.length < take && pageGuard < 3) {
      final page = current;
      for (final item in page) {
        final mapped = _mapVideoToSong(item, query: '', strictMode: false);
        if (mapped == null) continue;
        if (!seen.add(mapped.id)) continue;
        out.add(mapped);
        if (out.length >= take) break;
      }
      if (out.length >= take) break;
      current = await page.nextPage().timeout(timeout);
      pageGuard++;
    }

    return out;
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

    final imageUrl = video.thumbnails.highResUrl;

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
}

class _TimedSongsCache {
  final DateTime timestamp;
  final List<SaavnSong> songs;

  _TimedSongsCache(this.songs) : timestamp = DateTime.now();

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(timestamp) > ttl;
  }
}
