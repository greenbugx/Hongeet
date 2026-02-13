import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hongit/core/theme/app_theme.dart';
import 'package:hongit/core/utils/audio_player_service.dart';
import 'package:hongit/data/api/saavn_api.dart';
import 'package:hongit/data/api/youtube_api.dart';
import 'package:hongit/data/models/saavn_song.dart';
import 'package:hongit/features/search/widgets/song_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/utils/app_logger.dart';
import '../../core/utils/glass_container.dart';
import '../../core/utils/glass_page.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
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

  bool get isSearching => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _searchFuture = _performSearch(_quickPicksQuery);
  }

  Future<void> _refreshSearch() async {
    final query = _controller.text.trim();
    setState(() {
      if (query.isEmpty) {
        _lastQuery = '';
        _searchFuture = _performSearch(_quickPicksQuery, forceRefresh: true);
      } else if (query.length < minSearchLength) {
        _searchFuture = null;
      } else {
        _lastQuery = query;
        _searchFuture = _performSearch(query, forceRefresh: true);
      }
    });
    await _searchFuture?.catchError((_) => <SaavnSong>[]);
  }

  Future<List<SaavnSong>> _performSearch(
    String query, {
    bool forceRefresh = false,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return [];

    final prefs = await SharedPreferences.getInstance();
    final useYoutube = prefs.getBool('use_youtube_service') ?? true;
    final isQuickPicksQuery = normalizedQuery.toLowerCase() == _quickPicksQuery;
    final cacheKey =
        '${useYoutube ? "yt" : "saavn"}:${normalizedQuery.toLowerCase()}';

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
      } else {
        AppLogger.info('Using Saavn service for search: "$normalizedQuery"');
        songs = await SaavnApi.searchSongs(normalizedQuery);
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

    final scored = baseSongs
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
      // broad emoji ranges & dingbats or symbol blocks commonly used in spam titles
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

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    final trimmed = query.trim();

    if (trimmed.isEmpty) {
      setState(() {
        _lastQuery = '';
        _searchFuture = _performSearch(_quickPicksQuery);
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
      setState(() {
        _lastQuery = trimmed;
        _searchFuture = _performSearch(trimmed);
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final perfMode = themeProvider.resolvedUiPerformanceMode(context);
    final animateSectionHeader = perfMode == UiPerformanceMode.full;

    return GlassPage(
      child: RefreshIndicator(
        onRefresh: _refreshSearch,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          cacheExtent: 720,
          children: [
            const Text(
              'Welcome to\nHongeet',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 20),

            // Search Bar
            GlassContainer(
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
                    hintText: 'Search songs, artists...',
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

            const SizedBox(height: 28),

            animateSectionHeader
                ? AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      isSearching ? 'Search Results' : 'Quick Picks',
                      key: ValueKey(isSearching),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                : Text(
                    isSearching ? 'Search Results' : 'Quick Picks',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
            const SizedBox(height: 16),

            // Results
            _buildSearchResults(context),

            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults(BuildContext context) {
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

    final perfMode = Provider.of<ThemeProvider>(
      context,
      listen: false,
    ).resolvedUiPerformanceMode(context);
    final smoothMode = perfMode == UiPerformanceMode.smooth;

    return FutureBuilder<List<SaavnSong>>(
      future: _searchFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
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
                  Text(
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
          );
        }

        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No results',
                style: TextStyle(color: Colors.white70),
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

        return GridView.builder(
          padding: const EdgeInsets.only(bottom: 16),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          cacheExtent: 900,
          addAutomaticKeepAlives: !smoothMode,
          addRepaintBoundaries: true,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.68,
          ),
          itemCount: songs.length,
          itemBuilder: (_, i) {
            final song = songs[i];

            return RepaintBoundary(
              child: SongCard(
                song: song,
                onTap: () async {
                  if (i < 0 || i >= queuedSongs.length) return;

                  await AudioPlayerService().playFromList(
                    songs: queuedSongs,
                    startIndex: i,
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _SessionSearchCacheEntry {
  final List<SaavnSong> songs;

  const _SessionSearchCacheEntry({required this.songs});
}

class _ScoredSong {
  final SaavnSong song;
  final int score;

  const _ScoredSong({required this.song, required this.score});
}
