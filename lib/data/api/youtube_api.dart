import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/utils/youtube_thumbnail_utils.dart';
import '../models/saavn_song.dart';

class YoutubeApi {
  static final YoutubeExplode _yt = YoutubeExplode();

  static const Duration _searchTimeout = Duration(seconds: 10);
  static const Duration _searchFallbackTimeout = Duration(seconds: 7);
  static const Duration _relatedTimeout = Duration(seconds: 10);
  static const Duration _relatedFallbackTimeout = Duration(seconds: 8);
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

  static final Map<String, _TimedSongsCache> _searchCache = {};
  static final Map<String, _TimedSongsCache> _relatedCache = {};
  static _YtmBootstrapCache? _ytmBootstrapCache;
  static Future<_YtmBootstrapCache>? _ytmBootstrapInFlight;

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

    List<SaavnSong> ytmSongs = const [];
    Object? ytmError;
    try {
      ytmSongs = await _searchViaYtm(query: normalized, take: safeTake);
    } catch (e) {
      ytmError = e;
    }

    // Secondary YTM pass without fixed songs params so still prefer YTM before falling back to generic YouTube search.
    if (ytmSongs.isEmpty) {
      try {
        ytmSongs = await _searchViaYtm(
          query: normalized,
          take: safeTake,
          useSongsParams: false,
          requireSongsShelf: false,
        );
      } catch (e) {
        ytmError ??= e;
      }
    }

    List<SaavnSong> fallbackSongs = const [];
    if (ytmSongs.isEmpty) {
      try {
        fallbackSongs = await _searchViaYoutubeExplodeWithFallback(
          query: effectiveQuery,
          originalQuery: normalized,
          artistQuery: artistQuery,
          take: safeTake,
        );
      } catch (_) {
        if (ytmSongs.isEmpty && ytmError != null) {
          rethrow;
        }
      }
    }

    final songs = _mergeWithDedup(ytmSongs, fallbackSongs, safeTake);
    if (songs.isEmpty && ytmError != null) {
      throw ytmError;
    }

    final normalizedSongs = List<SaavnSong>.unmodifiable(songs);
    _searchCache[cacheKey] = _TimedSongsCache(normalizedSongs);
    _trimCache(_searchCache, maxEntries: 60);
    return normalizedSongs;
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

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('YTM search returned invalid payload');
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

    final artist = _extractYtmArtist(renderer);
    final duration = _extractYtmDurationSeconds(renderer);
    if (!_isLikelyYtmSong(title: title, artist: artist, duration: duration)) {
      return null;
    }

    final preferredThumb = _extractYtmThumbnail(renderer);
    final imageUrl = YoutubeThumbnailUtils.isYtmArtworkUrl(preferredThumb)
        ? preferredThumb!.trim()
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
    final runs = _asList(_asMap(secondColumn?['text'])?['runs']);
    if (runs.isEmpty) return 'Unknown';

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

    for (final run in runs) {
      final text = (_asMap(run)?['text'] ?? '').toString().trim();
      if (text.isEmpty || text == '•' || _looksLikeDurationText(text)) continue;
      return text;
    }

    return 'Unknown';
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

    if (response.statusCode != 200 || response.body.isEmpty) {
      return _YtmBootstrapCache.fallback();
    }

    final html = response.body;
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
}

class _TimedSongsCache {
  final DateTime timestamp;
  final List<SaavnSong> songs;

  _TimedSongsCache(this.songs) : timestamp = DateTime.now();

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
