import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:marquee/marquee.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:hongit/core/theme/app_theme.dart';
import 'package:hongit/core/utils/audio_player_service.dart';
import 'package:hongit/data/api/saavn_api.dart';
import 'package:hongit/data/api/youtube_api.dart';
import 'package:hongit/data/models/saavn_song.dart';
import 'package:hongit/features/search/widgets/song_card.dart';
import 'package:hongit/features/search/chart_songs_screen.dart';
import 'package:hongit/features/library/local_audio_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/utils/app_logger.dart';
import '../../core/utils/glass_container.dart';
import '../../core/utils/glass_page.dart';
import '../../core/utils/youtube_thumbnail_utils.dart';
import '../../core/widgets/fallback_network_image.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with AutomaticKeepAliveClientMixin<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _chartsScrollController = ScrollController();
  final ScrollController _albumsScrollController = ScrollController();
  Future<List<SaavnSong>>? _searchFuture;
  String _lastQuery = '';
  Timer? _debounce;
  static final Map<String, _SessionSearchCacheEntry> _sessionSearchCache = {};
  static const int _maxSessionCacheEntries = 80;
  static const String _quickPicksQuery = 'trending music';
  static const Duration _quickPicksCacheTtl = Duration(hours: 12);
  static const String _quickPicksCacheDataPrefix = 'quick_picks_cache_v2_';
  static const String _quickPicksCacheTsPrefix = 'quick_picks_cache_ts_v2_';
  static const int _quickPicksTargetCount = 24;
  static const int _chartsTargetCount = 10;
  static const int _albumsTargetCount = 10;
  static const int _trendingSongsTargetCount = 12;
  static const double _chartsSectionBodyHeight = 240;
  static const double _albumsSectionBodyHeight = 240;
  static const List<String> _trendingSongsQueries = <String>[
    'trending in shorts',
    'latest singles',
    'today\'s top songs',
    'viral songs',
    'top songs',
  ];
  static const List<String> _globallyBlockedTitleTokens = <String>[
    'trending',
    'new song',
    'new songs',
    'latest song',
    'new trending',
    'requested mix',
    'request mix',
    'mix songs',
    'instagram',
    'insta reel',
    'reels',
    'shorts',
    'yt shorts',
    'tik tok',
    'tiktok',
    'viral song',
    '#',
    '4k',
    '8k',
    'hd',
    'desi song',
    'desi songs',
    'indian song',
    'indian songs',
    'best song',
    'best songs',
    'top song',
    'top songs',
  ];
  static const List<String> _quickPicksFallbackBlockedTitleTokens = <String>[
    'requested mix',
    'request mix',
    'mix songs',
    'instagram',
    'insta reel',
    'reels',
    'shorts',
    'yt shorts',
    'tik tok',
    'tiktok',
  ];

  static const int minSearchLength = 2;

  late List<LocalAudioTrack> _localAudios = [];
  late Future<List<LocalAudioTrack>> _localAudiosFuture = Future.value([]);
  Future<_HomeSectionsData>? _homeSectionsFuture;
  bool _servicesReady = false;
  bool _useYoutubeService = false;
  bool _useSaavnService = false;

  bool get isSearching => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _initSearchMode();
  }

  Future<void> _initSearchMode() async {
    final prefs = await SharedPreferences.getInstance();
    final useYoutube = prefs.getBool('use_youtube_service') ?? false;
    final useSaavn = prefs.getBool('use_saavn_service') ?? false;
    if (!mounted) return;
    if (!useYoutube && !useSaavn) {
      setState(() {
        _servicesReady = true;
        _useYoutubeService = false;
        _useSaavnService = false;
        _homeSectionsFuture = null;
        _localAudiosFuture = _loadLocalAudiosWithPermission();
      });
      _localAudiosFuture.then((tracks) {
        if (!mounted) return;
        setState(() => _localAudios = tracks);
      });
    } else {
      setState(() {
        _servicesReady = true;
        _useYoutubeService = useYoutube;
        _useSaavnService = useSaavn;
        _searchFuture = _performSearch(_quickPicksQuery);
        _homeSectionsFuture = useYoutube ? _loadHomeSections() : null;
      });
    }
  }

  Future<bool> _ensureAudioPermission() async {
    if (!Platform.isAndroid) return true;

    var audioStatus = await Permission.audio.status;
    if (audioStatus.isGranted || audioStatus.isLimited) {
      return true;
    }

    audioStatus = await Permission.audio.request();
    if (audioStatus.isGranted || audioStatus.isLimited) {
      return true;
    }

    var storageStatus = await Permission.storage.status;
    if (storageStatus.isGranted) return true;
    storageStatus = await Permission.storage.request();
    return storageStatus.isGranted;
  }

  Future<List<LocalAudioTrack>> _loadLocalAudiosWithPermission() async {
    final granted = await _ensureAudioPermission();
    if (!granted) return const [];
    return LocalAudioProvider.load(maxItems: 500);
  }

  Future<void> _refreshSearch() async {
    final prefs = await SharedPreferences.getInstance();
    final useYoutube = prefs.getBool('use_youtube_service') ?? false;
    final useSaavn = prefs.getBool('use_saavn_service') ?? false;
    final query = _controller.text.trim();
    setState(() {
      _servicesReady = true;
      _useYoutubeService = useYoutube;
      _useSaavnService = useSaavn;
      if (query.isEmpty) {
        _lastQuery = '';
        if (!useYoutube && !useSaavn) {
          _homeSectionsFuture = null;
          _searchFuture = null;
          _localAudiosFuture = _loadLocalAudiosWithPermission();
          _localAudiosFuture.then((tracks) {
            if (!mounted) return;
            setState(() => _localAudios = tracks);
          });
        } else {
          _searchFuture = _performSearch(_quickPicksQuery, forceRefresh: true);
          _homeSectionsFuture = useYoutube
              ? _loadHomeSections(forceRefresh: true)
              : null;
        }
      } else if (query.length < minSearchLength) {
        _searchFuture = null;
      } else {
        _lastQuery = query;
        if (!useYoutube && !useSaavn) {
          setState(() {
            _searchFuture = _searchLocalAudios(query);
          });
        } else {
          _searchFuture = _performSearch(query, forceRefresh: true);
        }
      }
    });
    if (useYoutube || useSaavn) {
      await _searchFuture?.catchError((_) => <SaavnSong>[]);
    }
  }

  Future<List<SaavnSong>> _searchLocalAudios(String query) async {
    final normalized = query.toLowerCase();
    final results = _localAudios
        .where((track) => track.name.toLowerCase().contains(normalized))
        .map(
          (track) => SaavnSong(
            id: track.path,
            name: track.name,
            artists: 'Local Audio',
            imageUrl: '',
            duration: 0,
            downloadUrls: const [],
          ),
        )
        .toList();
    return results;
  }

  Future<List<SaavnSong>> _performSearch(
    String query, {
    bool forceRefresh = false,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return [];

    final prefs = await SharedPreferences.getInstance();
    final useYoutube = prefs.getBool('use_youtube_service') ?? false;
    final useSaavn = prefs.getBool('use_saavn_service') ?? false;

    if (!useYoutube && !useSaavn) return const [];
    final isQuickPicksQuery = normalizedQuery.toLowerCase() == _quickPicksQuery;
    final cacheKey =
        '${useYoutube
            ? "yt"
            : useSaavn
            ? "saavn"
            : "none"}:${normalizedQuery.toLowerCase()}';

    if (!forceRefresh) {
      final cached = _sessionSearchCache[cacheKey];
      if (cached != null) {
        final globallyFiltered = _applyGlobalResultFilter(cached.songs);
        if (isQuickPicksQuery) {
          final curated = _resolveQuickPicksSongs(cached.songs);
          _sessionSearchCache[cacheKey] = _SessionSearchCacheEntry(
            songs: curated,
          );
          return curated;
        }
        if (globallyFiltered.length != cached.songs.length) {
          _sessionSearchCache[cacheKey] = _SessionSearchCacheEntry(
            songs: globallyFiltered,
          );
        }
        return globallyFiltered;
      }

      if (isQuickPicksQuery) {
        final persisted = _readQuickPicksCache(prefs, useYoutube: useYoutube);
        if (persisted != null && persisted.isNotEmpty) {
          final curated = _resolveQuickPicksSongs(persisted);
          _sessionSearchCache[cacheKey] = _SessionSearchCacheEntry(
            songs: curated,
          );
          _trimSessionSearchCache();
          return curated;
        }
      }
    }

    try {
      final List<SaavnSong> songs;

      if (useYoutube) {
        AppLogger.info('Using YouTube service for search: "$normalizedQuery"');
        songs = await YoutubeApi.searchSongs(normalizedQuery);
      } else if (useSaavn) {
        AppLogger.info('Using Saavn service for search: "$normalizedQuery"');
        songs = await SaavnApi.searchSongs(normalizedQuery);
      } else {
        return const [];
      }

      final globallyFiltered = _applyGlobalResultFilter(songs);
      final resolvedSongs = isQuickPicksQuery
          ? _resolveQuickPicksSongs(songs)
          : globallyFiltered;
      _sessionSearchCache[cacheKey] = _SessionSearchCacheEntry(
        songs: List<SaavnSong>.unmodifiable(resolvedSongs),
      );
      _trimSessionSearchCache();

      if (isQuickPicksQuery && resolvedSongs.isNotEmpty) {
        await _writeQuickPicksCache(
          prefs,
          useYoutube: useYoutube,
          songs: resolvedSongs,
        );
      }

      return _sessionSearchCache[cacheKey]!.songs;
    } catch (_) {
      if (isQuickPicksQuery) {
        final staleFallback = _readQuickPicksCache(
          prefs,
          useYoutube: useYoutube,
          allowExpired: true,
        );
        if (staleFallback != null && staleFallback.isNotEmpty) {
          final curated = _resolveQuickPicksSongs(staleFallback);
          _sessionSearchCache[cacheKey] = _SessionSearchCacheEntry(
            songs: curated,
          );
          _trimSessionSearchCache();
          return curated;
        }
      }
      rethrow;
    }
  }

  List<SaavnSong> _resolveQuickPicksSongs(List<SaavnSong> songs) {
    final strict = _curateQuickPicks(songs);
    if (strict.isNotEmpty) return strict;

    final fallbackBase = _applyQuickPicksFallbackFilter(songs);
    if (fallbackBase.isEmpty) return const [];
    return _curateQuickPicks(fallbackBase, preFiltered: true);
  }

  List<SaavnSong> _curateQuickPicks(
    List<SaavnSong> songs, {
    bool preFiltered = false,
  }) {
    final baseSongs = preFiltered ? songs : _applyGlobalResultFilter(songs);
    if (baseSongs.isEmpty) return const [];

    final dedupedSongs = _dedupeSongsForQuickPicks(baseSongs);
    if (dedupedSongs.isEmpty) return const [];

    final scored = dedupedSongs
        .map((song) => _ScoredSong(song: song, score: _quickPickScore(song)))
        .toList(growable: false);

    final strict = scored.where((e) => e.score >= 0).toList(growable: false)
      ..sort((a, b) => b.score.compareTo(a.score));
    if (strict.length >= 12) {
      return strict
          .take(_quickPicksTargetCount)
          .map((e) => e.song)
          .toList(growable: false);
    }

    final relaxed = scored.where((e) => e.score >= -2).toList(growable: false)
      ..sort((a, b) => b.score.compareTo(a.score));
    if (relaxed.isNotEmpty) {
      return relaxed
          .take(_quickPicksTargetCount)
          .map((e) => e.song)
          .toList(growable: false);
    }

    final fallback = [...scored]..sort((a, b) => b.score.compareTo(a.score));
    return fallback
        .take(_quickPicksTargetCount)
        .map((e) => e.song)
        .toList(growable: false);
  }

  List<SaavnSong> _dedupeSongsForQuickPicks(List<SaavnSong> songs) {
    if (songs.isEmpty) return const [];

    final out = <SaavnSong>[];
    final seenIds = <String>{};
    final seenContent = <String>{};

    for (final song in songs) {
      final id = song.id.trim().toLowerCase();
      if (id.isNotEmpty && !seenIds.add(id)) continue;

      final key = _quickPickContentKey(song);
      if (key.isNotEmpty && !seenContent.add(key)) continue;

      out.add(song);
    }
    return out;
  }

  String _quickPickContentKey(SaavnSong song) {
    final title = _normalizeQuickPickTitle(song.name);
    if (title.isEmpty) return '';
    final artist = _normalizeQuickPickArtist(song.artists);
    return '$title::$artist';
  }

  String _normalizeQuickPickTitle(String raw) {
    var title = raw.toLowerCase().trim();
    if (title.isEmpty) return '';

    title = title.replaceAll(RegExp(r'[\(\[\{].*?[\)\]\}]'), ' ');
    title = title.replaceAll(
      RegExp(
        r'\b(official|audio|video|lyrics?|lyric|full\s*song|visualizer|4k|8k|hd)\b',
      ),
      ' ',
    );
    title = title.replaceAll(RegExp(r'\b(feat|ft)\.?\b.*$'), ' ');
    title = title.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    return title;
  }

  String _normalizeQuickPickArtist(String raw) {
    var text = raw.toLowerCase().trim();
    if (text.isEmpty || text == 'unknown') return '';

    text = text.replaceAll('&', ',');
    text = text.replaceAll(RegExp(r'\b(and|with|x)\b'), ',');
    text = text.replaceAll(RegExp(r'\b(feat|ft)\.?\b'), ',');

    final parts = text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .map((e) => e.replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ').trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    if (parts.isEmpty) return '';
    return parts.first.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  int _quickPickScore(SaavnSong song) {
    final title = song.name.toLowerCase();
    final artist = song.artists.toLowerCase();
    final combined = '$title $artist';

    const hardBlocked = <String>[
      'happy birthday',
      'birthday song',
      'nursery rhyme',
      'nursery rhymes',
      'kids song',
      'baby song',
      'lullaby',
      'cocomelon',
      'johny johny',
      'wheels on the bus',
      'podcast',
      'interview',
      'reaction',
      'prank',
      'vlog',
      'tutorial',
    ];
    if (hardBlocked.any(combined.contains)) return -100;

    var score = 0;
    final seconds = song.duration ?? 0;

    if (seconds >= 90 && seconds <= 6 * 60) {
      score += 3;
    } else if (seconds >= 60 && seconds <= 10 * 60) {
      score += 1;
    } else if (seconds > 0) {
      score -= 2;
    }

    if (artist.trim().isNotEmpty && artist != 'unknown') {
      score += 1;
    } else {
      score -= 1;
    }

    const goodSignals = <String>[
      'official',
      'audio',
      'lyrics',
      'lyric',
      'vevo',
      'topic',
      'soundtrack',
      'ost',
    ];
    if (goodSignals.any(combined.contains)) {
      score += 2;
    }

    const weakSignals = <String>[
      'cover',
      'karaoke',
      'instrumental',
      'slowed',
      'reverb',
      'nightcore',
      '8d',
      'sped up',
      'mashup',
    ];
    if (weakSignals.any(combined.contains)) {
      score -= 2;
    }

    return score;
  }

  List<SaavnSong> _applyGlobalResultFilter(List<SaavnSong> songs) {
    if (songs.isEmpty) return const [];
    return songs.where(_passesGlobalResultFilter).toList(growable: false);
  }

  List<SaavnSong> _applyQuickPicksFallbackFilter(List<SaavnSong> songs) {
    if (songs.isEmpty) return const [];

    return songs
        .where((song) {
          final title = song.name.trim();
          if (title.isEmpty) return false;
          if (_containsEmoji(title)) return false;
          final lowered = title.toLowerCase();
          if (_quickPicksFallbackBlockedTitleTokens.any(lowered.contains)) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  bool _passesGlobalResultFilter(SaavnSong song) {
    final title = song.name.trim();
    if (title.isEmpty) return false;

    if (_containsEmoji(title)) return false;

    final lowered = title.toLowerCase();
    if (_globallyBlockedTitleTokens.any(lowered.contains)) return false;

    return true;
  }

  bool _containsEmoji(String value) {
    for (final rune in value.runes) {
      final isEmoji =
          (rune >= 0x1F300 && rune <= 0x1FAFF) ||
          (rune >= 0x2600 && rune <= 0x27BF) ||
          (rune >= 0xFE00 && rune <= 0xFE0F);
      if (isEmoji) return true;
    }
    return false;
  }

  List<SaavnSong>? _readQuickPicksCache(
    SharedPreferences prefs, {
    required bool useYoutube,
    bool allowExpired = false,
  }) {
    final sourceKey = useYoutube ? 'yt' : 'saavn';
    final dataKey = '$_quickPicksCacheDataPrefix$sourceKey';
    final tsKey = '$_quickPicksCacheTsPrefix$sourceKey';

    final raw = prefs.getString(dataKey);
    if (raw == null || raw.trim().isEmpty) return null;

    final ts = prefs.getInt(tsKey);
    if (!allowExpired) {
      if (ts == null) return null;
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(ts),
      );
      if (age > _quickPicksCacheTtl) return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;

      final songs = <SaavnSong>[];
      for (final item in decoded) {
        final song = _songFromCache(item);
        if (song != null) songs.add(song);
      }

      if (songs.isEmpty) return null;
      return List<SaavnSong>.unmodifiable(songs);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeQuickPicksCache(
    SharedPreferences prefs, {
    required bool useYoutube,
    required List<SaavnSong> songs,
  }) async {
    final sourceKey = useYoutube ? 'yt' : 'saavn';
    final dataKey = '$_quickPicksCacheDataPrefix$sourceKey';
    final tsKey = '$_quickPicksCacheTsPrefix$sourceKey';

    final payload = songs.map(_songToCache).toList(growable: false);
    final encoded = jsonEncode(payload);

    await prefs.setString(dataKey, encoded);
    await prefs.setInt(tsKey, DateTime.now().millisecondsSinceEpoch);
  }

  Map<String, dynamic> _songToCache(SaavnSong song) {
    return <String, dynamic>{
      'id': song.id,
      'name': song.name,
      'artists': song.artists,
      'imageUrl': song.imageUrl,
      'duration': song.duration,
      'downloadUrls': song.downloadUrls
          .map(
            (entry) => <String, String>{
              'quality': entry['quality'] ?? '',
              'url': entry['url'] ?? '',
            },
          )
          .toList(growable: false),
    };
  }

  SaavnSong? _songFromCache(dynamic raw) {
    if (raw is! Map) return null;

    final id = (raw['id'] ?? '').toString().trim();
    final name = (raw['name'] ?? '').toString().trim();
    final artists = (raw['artists'] ?? 'Unknown').toString().trim();
    final imageUrl = (raw['imageUrl'] ?? '').toString().trim();

    if (id.isEmpty || name.isEmpty) return null;

    int? duration;
    final rawDuration = raw['duration'];
    if (rawDuration is int) {
      duration = rawDuration;
    } else if (rawDuration is String) {
      duration = int.tryParse(rawDuration);
    }

    final downloadUrls = <Map<String, String>>[];
    final rawDownloadUrls = raw['downloadUrls'];
    if (rawDownloadUrls is List) {
      for (final entry in rawDownloadUrls) {
        if (entry is! Map) continue;
        final quality = (entry['quality'] ?? '').toString().trim();
        final url = (entry['url'] ?? '').toString().trim();
        if (quality.isEmpty && url.isEmpty) continue;
        downloadUrls.add(<String, String>{'quality': quality, 'url': url});
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

  void _trimSessionSearchCache() {
    while (_sessionSearchCache.length > _maxSessionCacheEntries) {
      _sessionSearchCache.remove(_sessionSearchCache.keys.first);
    }
  }

  Future<List<SaavnSong>> _loadTrendingSongs({
    bool forceRefresh = false,
  }) async {
    final collected = <SaavnSong>[];
    final seenIds = <String>{};
    final seenKeys = <String>{};

    String contentKey(SaavnSong song) {
      final title = song.name.trim().toLowerCase();
      final artist = song.artists.trim().toLowerCase();
      return '$title::$artist';
    }

    bool looksLikeSingleSong(SaavnSong song) {
      final text = '${song.name} ${song.artists}'.toLowerCase();
      const blocked = <String>[
        'full album',
        'podcast',
        'episode',
        'interview',
        'reaction',
        'playlist',
      ];
      if (blocked.any(text.contains)) return false;
      final duration = song.duration ?? 0;
      if (duration > 0 && duration > 15 * 60) return false;
      return true;
    }

    for (final query in _trendingSongsQueries) {
      List<SaavnSong> batch = const <SaavnSong>[];
      try {
        batch = await _performSearch(query, forceRefresh: forceRefresh);
      } catch (_) {
        continue;
      }

      for (final song in batch) {
        if (!looksLikeSingleSong(song)) continue;
        final id = song.id.trim().toLowerCase();
        if (id.isNotEmpty && !seenIds.add(id)) continue;
        final key = contentKey(song);
        if (key.isNotEmpty && !seenKeys.add(key)) continue;
        collected.add(song);
        if (collected.length >= _trendingSongsTargetCount) {
          return collected;
        }
      }
    }

    if (collected.length < _trendingSongsTargetCount) {
      final fallbackQueries = <String>[
        _quickPicksQuery,
        'latest songs',
        'popular songs',
      ];
      for (final query in fallbackQueries) {
        List<SaavnSong> batch = const <SaavnSong>[];
        try {
          batch = await _performSearch(query, forceRefresh: forceRefresh);
        } catch (_) {
          continue;
        }
        for (final song in batch) {
          if (!looksLikeSingleSong(song)) continue;
          final id = song.id.trim().toLowerCase();
          if (id.isNotEmpty && !seenIds.add(id)) continue;
          final key = contentKey(song);
          if (key.isNotEmpty && !seenKeys.add(key)) continue;
          collected.add(song);
          if (collected.length >= _trendingSongsTargetCount) {
            return collected;
          }
        }
      }
    }

    if (collected.isNotEmpty) {
      return collected.take(_trendingSongsTargetCount).toList(growable: false);
    }

    try {
      final fallback = await _performSearch(
        _quickPicksQuery,
        forceRefresh: forceRefresh,
      );
      return fallback.take(_trendingSongsTargetCount).toList(growable: false);
    } catch (_) {
      return const <SaavnSong>[];
    }
  }

  Future<_HomeSectionsData> _loadHomeSections({
    bool forceRefresh = false,
  }) async {
    final chartsTask = YoutubeApi.charts(
      take: _chartsTargetCount,
      forceRefresh: forceRefresh,
    ).catchError((_) => const <YtmChart>[]);
    final albumsTask = YoutubeApi.trendingAlbums(
      take: _albumsTargetCount,
      forceRefresh: forceRefresh,
    ).catchError((_) => const <YtmAlbum>[]);
    final songsTask = _loadTrendingSongs(
      forceRefresh: forceRefresh,
    ).catchError((_) => const <SaavnSong>[]);

    final charts = await chartsTask;
    final albums = await albumsTask;
    final trendingSongs = await songsTask;

    return _HomeSectionsData(
      charts: charts,
      albums: albums,
      trendingSongs: trendingSongs,
    );
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    final trimmed = query.trim();

    if (trimmed.isEmpty) {
      SharedPreferences.getInstance().then((prefs) {
        final useYoutube = prefs.getBool('use_youtube_service') ?? false;
        final useSaavn = prefs.getBool('use_saavn_service') ?? false;
        setState(() {
          _servicesReady = true;
          _useYoutubeService = useYoutube;
          _useSaavnService = useSaavn;
          _lastQuery = '';
          if (!useYoutube && !useSaavn) {
            _homeSectionsFuture = null;
            _searchFuture = null;
            _localAudiosFuture = _loadLocalAudiosWithPermission();
            _localAudiosFuture.then((tracks) {
              if (!mounted) return;
              setState(() => _localAudios = tracks);
            });
          } else {
            _searchFuture = _performSearch(_quickPicksQuery);
            _homeSectionsFuture = useYoutube ? _loadHomeSections() : null;
          }
        });
      });
      return;
    }

    if (trimmed.length < minSearchLength) {
      setState(() {
        _lastQuery = '';
        _searchFuture = null;
      });
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (trimmed == _lastQuery) return;

      SharedPreferences.getInstance().then((prefs) {
        final useYoutube = prefs.getBool('use_youtube_service') ?? false;
        final useSaavn = prefs.getBool('use_saavn_service') ?? false;
        setState(() {
          _servicesReady = true;
          _useYoutubeService = useYoutube;
          _useSaavnService = useSaavn;
          _lastQuery = trimmed;
          if (!useYoutube && !useSaavn) {
            _searchFuture = _searchLocalAudios(trimmed);
          } else {
            _searchFuture = _performSearch(trimmed);
          }
        });
      });
    });
  }

  @override
  void dispose() {
    _chartsScrollController.dispose();
    _albumsScrollController.dispose();
    _scrollController.dispose();
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final perfMode = themeProvider.resolvedUiPerformanceMode(context);
    final animateSectionHeader = perfMode == UiPerformanceMode.full;

    if (!_servicesReady) {
      return const GlassPage(child: Center(child: CircularProgressIndicator()));
    }

    final useYoutube = _useYoutubeService;
    final useSaavn = _useSaavnService;
    final isLocalMode = !useYoutube && !useSaavn;
    final headerText = isSearching ? 'Search Results' : 'Quick Picks';

    return GlassPage(
      child: RefreshIndicator(
        onRefresh: _refreshSearch,
        child: CustomScrollView(
          key: const PageStorageKey<String>('search_screen_list'),
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          cacheExtent: 720,
          slivers: [
            const SliverToBoxAdapter(
              child: Text(
                'Welcome to\nHongeet',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 20)),
            SliverToBoxAdapter(
              child: GlassContainer(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _controller,
                    onChanged: _onSearchChanged,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      icon: Icon(
                        themeProvider.useGlassTheme
                            ? CupertinoIcons.search
                            : Icons.search,
                        color: Colors.white70,
                      ),
                      hintText: isLocalMode
                          ? 'Search local audio...'
                          : 'Search songs, artists...',
                      hintStyle: const TextStyle(color: Colors.white54),
                      border: InputBorder.none,
                      suffixIcon: _controller.text.isNotEmpty
                          ? IconButton(
                              icon: Icon(
                                themeProvider.useGlassTheme
                                    ? CupertinoIcons.clear_circled_solid
                                    : Icons.close,
                                color: Colors.white70,
                              ),
                              onPressed: () {
                                _controller.clear();
                                _onSearchChanged('');
                              },
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),

            if (!isLocalMode || isSearching) ...[
              SliverToBoxAdapter(
                child: animateSectionHeader
                    ? AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Text(
                          headerText,
                          key: ValueKey(headerText),
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    : Text(
                        headerText,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
            ],

            if (isLocalMode)
              SliverToBoxAdapter(child: _buildLocalSearchResults(context))
            else
              _buildSearchResultsSliver(context),

            if (!isLocalMode && !isSearching && useYoutube) ...[
              const SliverToBoxAdapter(child: SizedBox(height: 30)),
              _buildHomeSectionsSliver(context),
            ],

            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeSectionsSliver(BuildContext context) {
    _homeSectionsFuture ??= _loadHomeSections();
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    return FutureBuilder<_HomeSectionsData>(
      future: _homeSectionsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return SliverList(
            delegate: SliverChildListDelegate(<Widget>[
              _buildSectionLoadingPlaceholder(
                context,
                title: 'Charts',
                height: _chartsSectionBodyHeight,
                topPadding: 0,
              ),
              _buildSectionLoadingPlaceholder(
                context,
                title: 'Trending Albums',
                height: _albumsSectionBodyHeight,
                topPadding: 24,
              ),
              _buildSectionLoadingPlaceholder(
                context,
                title: 'Trending Songs',
                height: 900,
                topPadding: 24,
              ),
            ]),
          );
        }

        if (snapshot.hasError) {
          return SliverToBoxAdapter(
            child: GlassContainer(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      themeProvider.useGlassTheme
                          ? CupertinoIcons.exclamationmark_triangle
                          : Icons.error_outline,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Failed to load home sections',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: () {
                        setState(() {
                          _homeSectionsFuture = _loadHomeSections(
                            forceRefresh: true,
                          );
                        });
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final data = snapshot.data ?? const _HomeSectionsData.empty();
        return SliverList(
          delegate: SliverChildListDelegate(<Widget>[
            _buildChartsSection(context, data.charts),
            _buildTrendingAlbumsSection(context, data.albums),
            _buildTrendingSongsSection(context, data.trendingSongs),
          ]),
        );
      },
    );
  }

  Widget _buildSectionLoadingPlaceholder(
    BuildContext context, {
    required String title,
    required double? height,
    required double topPadding,
  }) {
    final perfMode = Provider.of<ThemeProvider>(
      context,
      listen: false,
    ).resolvedUiPerformanceMode(context);
    final fullMode = perfMode == UiPerformanceMode.full;
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Column(
        crossAxisAlignment: fullMode
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: Text(
              title,
              textAlign: fullMode ? TextAlign.center : TextAlign.start,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(height: 16),
          if (height == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            SizedBox(
              height: height,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _buildChartsSection(BuildContext context, List<YtmChart> charts) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final perfMode = themeProvider.resolvedUiPerformanceMode(context);
    final smoothMode = perfMode == UiPerformanceMode.smooth;
    final fullMode = perfMode == UiPerformanceMode.full;

    return Column(
      crossAxisAlignment: fullMode
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: fullMode
              ? AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: const Text(
                    'Charts',
                    key: ValueKey('charts_full'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                  ),
                )
              : const Text(
                  'Charts',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: _chartsSectionBodyHeight,
          child: charts.isEmpty
              ? const Center(
                  child: Text(
                    'No charts available right now',
                    style: TextStyle(color: Colors.white60),
                  ),
                )
              : ListView.separated(
                  key: const PageStorageKey<String>('search_screen_charts_row'),
                  controller: _chartsScrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(left: 2, right: 2, bottom: 8),
                  cacheExtent: 900,
                  addAutomaticKeepAlives: !smoothMode,
                  addRepaintBoundaries: true,
                  physics: smoothMode
                      ? const ClampingScrollPhysics()
                      : const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                  itemCount: charts.length,
                  separatorBuilder: (_, index) => const SizedBox(width: 14),
                  itemBuilder: (_, index) {
                    final chart = charts[index];
                    final imageCandidates = YoutubeThumbnailUtils.candidateUrls(
                      imageUrl: chart.imageUrl,
                    );

                    return SizedBox(
                      width: 170,
                      child: RepaintBoundary(
                        child: GlassContainer(
                          borderRadius: BorderRadius.circular(18),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      ChartSongsScreen(chart: chart),
                                ),
                              );
                            },
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AspectRatio(
                                  aspectRatio: 1,
                                  child: ClipRRect(
                                    clipBehavior: Clip.antiAlias,
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(18),
                                    ),
                                    child: FallbackNetworkImage(
                                      urls: imageCandidates,
                                      width: double.infinity,
                                      height: double.infinity,
                                      cacheWidth: 640,
                                      cacheHeight: 640,
                                      fit: BoxFit.cover,
                                      filterQuality: FilterQuality.medium,
                                      fallback: Container(
                                        color: Colors.black26,
                                        child: Icon(
                                          themeProvider.useGlassTheme
                                              ? CupertinoIcons.waveform
                                              : Icons.equalizer_rounded,
                                          size: 34,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Flexible(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      10,
                                      8,
                                      10,
                                      8,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          height: 20,
                                          child: _AutoMarqueeText(
                                            text: chart.title,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          chart.subtitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTrendingAlbumsSection(
    BuildContext context,
    List<YtmAlbum> albums,
  ) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final perfMode = themeProvider.resolvedUiPerformanceMode(context);
    final smoothMode = perfMode == UiPerformanceMode.smooth;
    final fullMode = perfMode == UiPerformanceMode.full;

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: fullMode
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: fullMode
                ? AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: const Text(
                      'Trending Albums',
                      key: ValueKey('albums_full'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                : const Text(
                    'Trending Albums',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                  ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: _albumsSectionBodyHeight,
            child: albums.isEmpty
                ? const Center(
                    child: Text(
                      'No trending albums right now',
                      style: TextStyle(color: Colors.white60),
                    ),
                  )
                : ListView.separated(
                    key: const PageStorageKey<String>(
                      'search_screen_albums_row',
                    ),
                    controller: _albumsScrollController,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(
                      left: 2,
                      right: 2,
                      bottom: 8,
                    ),
                    cacheExtent: 900,
                    addAutomaticKeepAlives: !smoothMode,
                    addRepaintBoundaries: true,
                    physics: smoothMode
                        ? const ClampingScrollPhysics()
                        : const BouncingScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics(),
                          ),
                    itemCount: albums.length,
                    separatorBuilder: (_, index) => const SizedBox(width: 14),
                    itemBuilder: (_, index) {
                      final album = albums[index];
                      final allImageCandidates =
                          YoutubeThumbnailUtils.candidateUrls(
                            imageUrl: album.imageUrl,
                          );
                      final ytmOnlyCandidates = allImageCandidates
                          .where(YoutubeThumbnailUtils.isYtmArtworkUrl)
                          .toList(growable: false);
                      final imageCandidates = ytmOnlyCandidates.isNotEmpty
                          ? ytmOnlyCandidates
                          : allImageCandidates;
                      final baseImageScale =
                          YoutubeThumbnailUtils.preferredArtworkScale(
                            imageUrl: album.imageUrl,
                            youtubeVideoScale: 2.0,
                            normalScale: 1.0,
                          );
                      final imageScale = ytmOnlyCandidates.isNotEmpty
                          ? (baseImageScale < 1.04 ? 1.04 : baseImageScale)
                          : (baseImageScale < 1.12 ? 1.12 : baseImageScale);
                      final albumAsChart = YtmChart(
                        playlistId: album.browseId,
                        browseId: album.browseId,
                        title: album.title,
                        subtitle: album.subtitle,
                        imageUrl: album.imageUrl,
                      );

                      return SizedBox(
                        width: 170,
                        child: RepaintBoundary(
                          child: GlassContainer(
                            borderRadius: BorderRadius.circular(18),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(18),
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => ChartSongsScreen(
                                      chart: albumAsChart,
                                      headerTitle: 'Albums',
                                    ),
                                  ),
                                );
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  AspectRatio(
                                    aspectRatio: 1,
                                    child: ClipRRect(
                                      clipBehavior: Clip.antiAlias,
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(18),
                                      ),
                                      child: Transform.scale(
                                        scale: imageScale,
                                        child: FallbackNetworkImage(
                                          urls: imageCandidates,
                                          width: double.infinity,
                                          height: double.infinity,
                                          cacheWidth: 768,
                                          cacheHeight: 768,
                                          fit: BoxFit.cover,
                                          alignment: Alignment.center,
                                          filterQuality: FilterQuality.medium,
                                          fallback: Container(
                                            color: Colors.black26,
                                            child: Icon(
                                              themeProvider.useGlassTheme
                                                  ? CupertinoIcons.music_albums
                                                  : Icons.album_rounded,
                                              size: 34,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Flexible(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        10,
                                        8,
                                        10,
                                        8,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            height: 20,
                                            child: _AutoMarqueeText(
                                              text: album.title,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            album.subtitle,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.white70,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrendingSongsSection(
    BuildContext context,
    List<SaavnSong> songs,
  ) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final perfMode = themeProvider.resolvedUiPerformanceMode(context);
    final fullMode = perfMode == UiPerformanceMode.full;
    final queuedSongs = songs
        .map(
          (s) => QueuedSong(
            id: s.id,
            meta: NowPlaying(
              title: s.name,
              artist: s.artists,
              imageUrl: s.imageUrl,
            ),
          ),
        )
        .toList(growable: false);

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: fullMode
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: fullMode
                ? AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: const Text(
                      'Trending Songs',
                      key: ValueKey('trending_songs_full'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                : const Text(
                    'Trending Songs',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                  ),
          ),
          const SizedBox(height: 16),
          if (songs.isEmpty)
            const Center(
              child: Text(
                'No trending songs right now',
                style: TextStyle(color: Colors.white60),
              ),
            )
          else
            Column(
              children: List<Widget>.generate(songs.length, (index) {
                final song = songs[index];
                final imageCandidates = YoutubeThumbnailUtils.candidateUrls(
                  songId: song.id,
                  imageUrl: song.imageUrl,
                );
                final imageScale = YoutubeThumbnailUtils.preferredArtworkScale(
                  songId: song.id,
                  imageUrl: song.imageUrl,
                  youtubeVideoScale: 1.0,
                  normalScale: 1.0,
                );

                return Padding(
                  padding: EdgeInsets.only(
                    bottom: index == songs.length - 1 ? 0 : 10,
                  ),
                  child: RepaintBoundary(
                    child: GlassContainer(
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () async {
                          if (index < 0 || index >= queuedSongs.length) return;
                          await AudioPlayerService().playFromList(
                            songs: queuedSongs,
                            startIndex: index,
                            autoExtendQueue: true,
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                clipBehavior: Clip.antiAlias,
                                borderRadius: BorderRadius.circular(10),
                                child: Transform.scale(
                                  scale: imageScale,
                                  child: FallbackNetworkImage(
                                    urls: imageCandidates,
                                    width: 56,
                                    height: 56,
                                    cacheWidth: 320,
                                    cacheHeight: 320,
                                    fit: BoxFit.cover,
                                    alignment: Alignment.center,
                                    filterQuality: FilterQuality.medium,
                                    fallback: Container(
                                      width: 56,
                                      height: 56,
                                      color: Colors.black26,
                                      child: Icon(
                                        themeProvider.useGlassTheme
                                            ? CupertinoIcons.music_note_2
                                            : Icons.music_note_rounded,
                                        size: 24,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      song.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      song.artists,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
        ],
      ),
    );
  }

  Widget _buildLocalSearchResults(BuildContext context) {
    final query = _controller.text.trim();
    if (query.isNotEmpty && query.length < minSearchLength) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Type at least $minSearchLength characters to search',
            style: const TextStyle(color: Colors.white54, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (query.isEmpty) {
      final results = _localAudios
          .map(
            (track) => SaavnSong(
              id: track.path,
              name: track.name,
              artists: 'Local Audio',
              imageUrl: '',
              duration: 0,
              downloadUrls: const [],
            ),
          )
          .toList(growable: false);

      if (results.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'No local audio files found on your device',
              style: const TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
        );
      }

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          children: results.asMap().entries.map((entry) {
            final index = entry.key;
            final song = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GlassContainer(
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () async {
                    await AudioPlayerService().playLocalFiles(
                      files: results
                          .map((s) => (path: s.id, name: s.name))
                          .toList(),
                      startIndex: index,
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                song.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Local Audio',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      );
    }

    return FutureBuilder<List<SaavnSong>>(
      future: _searchFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error loading local audio: ${snapshot.error}',
              style: const TextStyle(color: Colors.red),
            ),
          );
        }

        final results = snapshot.data ?? [];
        if (results.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'No matches found',
                style: const TextStyle(color: Colors.white54, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: results.asMap().entries.map((entry) {
              final index = entry.key;
              final song = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: GlassContainer(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () async {
                      await AudioPlayerService().playLocalFiles(
                        files: results
                            .map((s) => (path: s.id, name: s.name))
                            .toList(),
                        startIndex: index,
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  song.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Local Audio',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white54,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Widget _buildSearchResultsSliver(BuildContext context) {
    final query = _controller.text.trim();
    if (query.isNotEmpty && query.length < minSearchLength) {
      return SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'Type at least $minSearchLength characters to search',
              style: const TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final perfMode = Provider.of<ThemeProvider>(
      context,
      listen: false,
    ).resolvedUiPerformanceMode(context);
    final smoothMode = perfMode == UiPerformanceMode.smooth;

    return FutureBuilder<List<SaavnSong>>(
      future: _searchFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        if (snapshot.hasError) {
          return SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Provider.of<ThemeProvider>(context).useGlassTheme
                          ? CupertinoIcons.exclamationmark_triangle
                          : Icons.error_outline,
                      size: 48,
                      color: Colors.red.shade300,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Failed to load songs',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'API might be down or network issue',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton(
                      onPressed: _refreshSearch,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No results',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
          );
        }

        final songs = List<SaavnSong>.from(snapshot.data!);
        if (songs.length >= 2 && songs.length.isOdd) {
          songs.removeLast();
        }

        final queuedSongs = songs
            .map(
              (s) => QueuedSong(
                id: s.id,
                meta: NowPlaying(
                  title: s.name,
                  artist: s.artists,
                  imageUrl: s.imageUrl,
                ),
              ),
            )
            .toList();

        return SliverPadding(
          padding: const EdgeInsets.only(bottom: 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 0.68,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, i) {
                final song = songs[i];

                return RepaintBoundary(
                  child: SongCard(
                    song: song,
                    onTap: () async {
                      if (i < 0 || i >= queuedSongs.length) return;

                      await AudioPlayerService().playFromList(
                        songs: queuedSongs,
                        startIndex: i,
                        autoExtendQueue: true,
                      );
                    },
                  ),
                );
              },
              childCount: songs.length,
              addAutomaticKeepAlives: !smoothMode,
              addRepaintBoundaries: true,
            ),
          ),
        );
      },
    );
  }
}

class _SessionSearchCacheEntry {
  final List<SaavnSong> songs;

  const _SessionSearchCacheEntry({required this.songs});
}

class _HomeSectionsData {
  final List<YtmChart> charts;
  final List<YtmAlbum> albums;
  final List<SaavnSong> trendingSongs;

  const _HomeSectionsData({
    required this.charts,
    required this.albums,
    required this.trendingSongs,
  });

  const _HomeSectionsData.empty()
    : charts = const <YtmChart>[],
      albums = const <YtmAlbum>[],
      trendingSongs = const <SaavnSong>[];
}

class _ScoredSong {
  final SaavnSong song;
  final int score;

  const _ScoredSong({required this.song, required this.score});
}

class _AutoMarqueeText extends StatelessWidget {
  final String text;
  final TextStyle style;

  const _AutoMarqueeText({required this.text, required this.style});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);

        if (!painter.didExceedMaxLines) {
          return Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }

        return Marquee(
          text: text,
          style: style,
          blankSpace: 28,
          velocity: 22,
          pauseAfterRound: const Duration(milliseconds: 900),
          startPadding: 2,
          fadingEdgeStartFraction: 0.08,
          fadingEdgeEndFraction: 0.08,
          accelerationDuration: const Duration(milliseconds: 250),
          decelerationDuration: const Duration(milliseconds: 250),
        );
      },
    );
  }
}
