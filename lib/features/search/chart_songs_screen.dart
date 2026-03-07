import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/responsive.dart';
import '../../core/utils/audio_player_service.dart';
import '../../core/utils/app_messenger.dart';
import '../../core/utils/themed_container.dart';
import '../../core/utils/themed_page.dart';
import '../../core/utils/youtube_thumbnail_utils.dart';
import '../../core/widgets/fallback_network_image.dart';
import '../../data/api/youtube_api.dart';
import '../../data/models/saavn_song.dart';
import '../library/playlist_manager.dart';
import '../player/mini_player.dart';

class ChartSongsScreen extends StatefulWidget {
  final YtmChart chart;
  final String headerTitle;
  final String? fallbackArtistName;

  const ChartSongsScreen({
    super.key,
    required this.chart,
    this.headerTitle = 'Charts',
    this.fallbackArtistName,
  });

  @override
  State<ChartSongsScreen> createState() => _ChartSongsScreenState();
}

class _ChartSongsScreenState extends State<ChartSongsScreen> {
  late Future<List<SaavnSong>> _songsFuture;
  List<SaavnSong>? _enhancedSongs;
  bool _isEnhancingArtwork = false;
  int _loadToken = 0;
  Set<int> _pendingArtworkIndexes = <int>{};
  int _enhancedCount = 0;
  int _enhanceTargetCount = 0;

  bool _isUnknownArtistValue(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    const blocked = <String>{
      'unknown',
      'unknown artist',
      'artist',
      'single',
      'album',
      'ep',
      'song',
      'songs',
      'track',
      'tracks',
    };
    if (blocked.contains(normalized)) return true;
    if (RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$').hasMatch(normalized)) {
      return true;
    }
    return false;
  }

  bool _isLikelyMetaSubtitlePart(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    const blocked = <String>{
      'single',
      'album',
      'ep',
      'song',
      'songs',
      'track',
      'tracks',
      'chart',
      'charts',
      'youtube music',
      'new release',
      'new releases',
      'unknown',
    };
    if (blocked.contains(normalized)) return true;
    if (RegExp(r'^\d{4}$').hasMatch(normalized)) return true;
    if (RegExp(r'^\d+\s*(songs?|tracks?)$').hasMatch(normalized)) return true;
    return false;
  }

  String _fallbackArtistFromChartSubtitle() {
    final explicit = widget.fallbackArtistName?.trim() ?? '';
    if (explicit.isNotEmpty && !_isUnknownArtistValue(explicit)) {
      return explicit;
    }

    final subtitle = widget.chart.subtitle.trim();
    if (subtitle.isEmpty) return '';
    final parts = subtitle
        .split(RegExp(r'\s*(?:\u2022|\u00b7|\|)\s*'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return '';

    for (final part in parts) {
      if (_isLikelyMetaSubtitlePart(part)) continue;
      return part;
    }
    return '';
  }

  List<SaavnSong> _applyFallbackArtistToSongs(List<SaavnSong> songs) {
    if (songs.isEmpty) return songs;
    final fallbackArtist = _fallbackArtistFromChartSubtitle();
    if (fallbackArtist.isEmpty) return songs;

    var changed = false;
    final out = songs
        .map((song) {
          if (!_isUnknownArtistValue(song.artists)) return song;
          changed = true;
          return SaavnSong(
            id: song.id,
            name: song.name,
            artists: fallbackArtist,
            imageUrl: song.imageUrl,
            duration: song.duration,
            downloadUrls: song.downloadUrls,
          );
        })
        .toList(growable: false);

    return changed ? out : songs;
  }

  String _preferredPlaybackArtUrl(SaavnSong song) {
    final candidates = YoutubeThumbnailUtils.candidateUrls(
      songId: song.id,
      imageUrl: song.imageUrl,
    );
    if (candidates.isEmpty) return song.imageUrl;

    for (final url in candidates) {
      if (YoutubeThumbnailUtils.isYtmArtworkUrl(url) &&
          url.contains('w1024-h1024-l90-rj')) {
        return url;
      }
    }
    for (final url in candidates) {
      if (YoutubeThumbnailUtils.isYtmArtworkUrl(url) &&
          url.contains('w720-h720-l90-rj')) {
        return url;
      }
    }
    for (final url in candidates) {
      if (YoutubeThumbnailUtils.isYtmArtworkUrl(url) &&
          url.contains('w544-h544-l90-rj')) {
        return url;
      }
    }

    String pick(String token) {
      for (final url in candidates) {
        if (url.contains(token)) return url;
      }
      return '';
    }

    final sd = pick('/sddefault.jpg');
    if (sd.isNotEmpty) return sd;
    final hq720 = pick('/hq720.jpg');
    if (hq720.isNotEmpty) return hq720;
    final hq = pick('/hqdefault.jpg');
    if (hq.isNotEmpty) return hq;

    return candidates.first;
  }

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  void _loadSongs({bool forceRefresh = false}) {
    final token = ++_loadToken;
    _enhancedSongs = null;
    _isEnhancingArtwork = false;
    _pendingArtworkIndexes = <int>{};
    _enhancedCount = 0;
    _enhanceTargetCount = 0;
    _songsFuture = YoutubeApi.chartSongs(
      widget.chart.browseId,
      forceRefresh: forceRefresh,
      resolveArtworkFallback: false,
    );
    _songsFuture
        .then((songs) {
          if (!mounted || token != _loadToken) return;
          _startArtworkEnhancement(songs, token);
        })
        .catchError((_) {
          if (!mounted || token != _loadToken) return;
          setState(() {
            _isEnhancingArtwork = false;
          });
        });
  }

  Future<void> _startArtworkEnhancement(
    List<SaavnSong> songs,
    int token,
  ) async {
    if (songs.isEmpty) return;
    final targetIndexes = <int>[];
    for (var i = 0; i < songs.length; i++) {
      if (!YoutubeThumbnailUtils.isLikelyLowQualityArtwork(songs[i].imageUrl)) {
        continue;
      }
      targetIndexes.add(i);
    }
    if (targetIndexes.isEmpty) return;

    setState(() {
      _isEnhancingArtwork = true;
      _enhancedSongs = List<SaavnSong>.from(songs);
      _pendingArtworkIndexes = targetIndexes.toSet();
      _enhanceTargetCount = targetIndexes.length;
      _enhancedCount = 0;
    });

    for (final index in targetIndexes) {
      if (!mounted || token != _loadToken) return;
      final current = _enhancedSongs![index];
      SaavnSong updated = current;
      try {
        updated = await YoutubeApi.resolveSingleSongArtworkFallback(current);
      } catch (_) {
        updated = current;
      }
      if (!mounted || token != _loadToken) return;
      setState(() {
        _enhancedSongs![index] = updated;
        _pendingArtworkIndexes.remove(index);
        _enhancedCount++;
      });
    }

    if (!mounted || token != _loadToken) return;
    setState(() {
      _isEnhancingArtwork = false;
      _pendingArtworkIndexes = <int>{};
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _loadSongs(forceRefresh: true);
    });
    await _songsFuture.catchError((_) => <SaavnSong>[]);
  }

  IconData _playlistIcon(bool useGlassTheme) {
    return useGlassTheme
        ? CupertinoIcons.music_note_list
        : Icons.playlist_add_rounded;
  }

  IconData _addedToPlaylistIcon(bool useGlassTheme) {
    return useGlassTheme
        ? CupertinoIcons.check_mark_circled_solid
        : Icons.check_circle;
  }

  IconData _favouriteIcon(bool useGlassTheme, bool isFavourite) {
    if (useGlassTheme) {
      return isFavourite ? CupertinoIcons.heart_fill : CupertinoIcons.heart;
    }
    return isFavourite ? Icons.favorite : Icons.favorite_border;
  }

  IconData _chartFallbackIcon(bool useGlassTheme) {
    return useGlassTheme ? CupertinoIcons.waveform : Icons.equalizer_rounded;
  }

  IconData _songFallbackIcon(bool useGlassTheme) {
    return useGlassTheme
        ? CupertinoIcons.music_note_2
        : Icons.music_note_rounded;
  }

  Map<String, dynamic> _songAsPlaylistEntry(SaavnSong song) {
    return <String, dynamic>{
      'id': song.id,
      'title': song.name,
      'artist': song.artists,
      'imageUrl': _preferredPlaybackArtUrl(song),
    };
  }

  Future<void> _toggleFavourite(SaavnSong song) async {
    final scheme = Theme.of(context).colorScheme;
    final wasFavourite = PlaylistManager.isFavourite(song.id);
    await PlaylistManager.toggleFavourite(_songAsPlaylistEntry(song));
    AppMessenger.show(
      wasFavourite ? 'Removed from favorites' : 'Added to favorites',
      color: wasFavourite ? scheme.secondary : scheme.primary,
    );
    if (mounted) setState(() {});
  }

  void _showAddToPlaylistSheet(SaavnSong song) {
    final useGlassTheme = Provider.of<ThemeProvider>(
      context,
      listen: false,
    ).useGlassTheme;
    final uiTheme = Theme.of(context);
    final scheme = uiTheme.colorScheme;
    final textTheme = uiTheme.textTheme;
    final addedInSheet = <String>{};

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return StreamBuilder<Map<String, List<Map<String, dynamic>>>>(
              stream: PlaylistManager.stream,
              builder: (context, snapshot) {
                final playlists =
                    snapshot.data ??
                    const <String, List<Map<String, dynamic>>>{};
                final names = playlists.keys
                    .where((name) => name != PlaylistManager.systemFavourites)
                    .toList(growable: false);

                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Add to Playlist',
                        style: textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (names.isEmpty)
                        Text(
                          'No playlists yet',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ...names.map((name) {
                        final playlistSongs = playlists[name] ?? const [];
                        final exists = playlistSongs.any(
                          (entry) =>
                              (entry['id'] ?? '').toString().trim() == song.id,
                        );
                        final added = exists || addedInSheet.contains(name);

                        return ListTile(
                          leading: Icon(
                            added
                                ? _addedToPlaylistIcon(useGlassTheme)
                                : _playlistIcon(useGlassTheme),
                            color: added ? scheme.primary : null,
                          ),
                          title: Text(name),
                          onTap: () async {
                            if (added) {
                              AppMessenger.show('Already in "$name"');
                              return;
                            }

                            final success = await PlaylistManager.addSong(
                              name,
                              _songAsPlaylistEntry(song),
                            );
                            if (!context.mounted) return;

                            if (success) {
                              setModalState(() => addedInSheet.add(name));
                              AppMessenger.show('Added to "$name"');
                            } else {
                              AppMessenger.show('Already in "$name"');
                            }
                          },
                        );
                      }),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Provider.of<ThemeProvider>(context);
    final uiTheme = Theme.of(context);
    final textTheme = uiTheme.textTheme;
    final scheme = uiTheme.colorScheme;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final headerArtSize = screenWidth >= 1024 ? 280.0 : 210.0;
    final artCandidates = YoutubeThumbnailUtils.candidateUrls(
      imageUrl: widget.chart.imageUrl,
    );

    return ThemedPage(
      child: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refresh,
            child: FutureBuilder<List<SaavnSong>>(
              future: _songsFuture,
              builder: (context, snapshot) {
                final baseSongs = snapshot.data ?? const <SaavnSong>[];
                final songs = _applyFallbackArtistToSongs(
                  _enhancedSongs ?? baseSongs,
                );
                final queuedSongs = songs
                    .map(
                      (s) => QueuedSong(
                        id: s.id,
                        meta: NowPlaying(
                          title: s.name,
                          artist: s.artists,
                          imageUrl: _preferredPlaybackArtUrl(s),
                        ),
                      ),
                    )
                    .toList(growable: false);
                final resolvedSongCount =
                    widget.chart.songCount ?? songs.length;

                return ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 140),
                  children: [
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            theme.useGlassTheme
                                ? CupertinoIcons.back
                                : Icons.arrow_back,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          widget.headerTitle,
                          style: textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: FallbackNetworkImage(
                              urls: artCandidates,
                              width: headerArtSize,
                              height: headerArtSize,
                              cacheWidth: 1024,
                              cacheHeight: 1024,
                              fit: BoxFit.cover,
                              filterQuality: FilterQuality.medium,
                              fallback: Container(
                                width: headerArtSize,
                                height: headerArtSize,
                                color: scheme.surfaceContainerHighest,
                                child: Icon(
                                  _chartFallbackIcon(theme.useGlassTheme),
                                  size: 48,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            widget.chart.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            widget.chart.subtitle,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '$resolvedSongCount songs',
                            textAlign: TextAlign.center,
                            style: textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (_isEnhancingArtwork)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Center(
                          child: Text(
                            _enhanceTargetCount > 0
                                ? 'Fetching songs arts... $_enhancedCount/$_enhanceTargetCount'
                                : 'Fetching songs arts...',
                            style: textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    if (snapshot.connectionState == ConnectionState.waiting)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (snapshot.hasError)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Failed to load chart songs',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 10),
                              OutlinedButton(
                                onPressed: _refresh,
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (songs.isEmpty)
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 36),
                        child: Center(
                          child: Text(
                            'No songs found in this chart',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      )
                    else
                      ...songs.asMap().entries.map((entry) {
                        final index = entry.key;
                        final song = entry.value;
                        final imageScale =
                            YoutubeThumbnailUtils.preferredArtworkScale(
                              songId: song.id,
                              imageUrl: song.imageUrl,
                              youtubeVideoScale: 1.0,
                              normalScale: 1.0,
                            );
                        final shouldShowPlaceholder =
                            _isEnhancingArtwork &&
                            _pendingArtworkIndexes.contains(index) &&
                            YoutubeThumbnailUtils.isLikelyLowQualityArtwork(
                              song.imageUrl,
                            );
                        final imageCandidates = shouldShowPlaceholder
                            ? const <String>[]
                            : YoutubeThumbnailUtils.candidateUrls(
                                songId: song.id,
                                imageUrl: song.imageUrl,
                              );

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: ThemedContainer(
                            child: ListTile(
                              leading: SizedBox(
                                width: 50,
                                height: 50,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Transform.scale(
                                    scale: imageScale,
                                    child: FallbackNetworkImage(
                                      urls: imageCandidates,
                                      width: 50,
                                      height: 50,
                                      cacheWidth: 320,
                                      cacheHeight: 320,
                                      fit: BoxFit.cover,
                                      filterQuality: FilterQuality.medium,
                                      fallback: Container(
                                        color: scheme.surfaceContainerHighest,
                                        child: Icon(
                                          _songFallbackIcon(
                                            theme.useGlassTheme,
                                          ),
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              title: Text(
                                song.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                song.artists,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: SizedBox(
                                width: 86,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    IconButton(
                                      tooltip:
                                          PlaylistManager.isFavourite(song.id)
                                          ? 'Remove from favorites'
                                          : 'Add to favorites',
                                      visualDensity: VisualDensity.compact,
                                      isSelected: PlaylistManager.isFavourite(
                                        song.id,
                                      ),
                                      icon: Icon(
                                        _favouriteIcon(
                                          theme.useGlassTheme,
                                          PlaylistManager.isFavourite(song.id),
                                        ),
                                        color:
                                            PlaylistManager.isFavourite(song.id)
                                            ? scheme.error
                                            : null,
                                      ),
                                      onPressed: () => _toggleFavourite(song),
                                    ),
                                    IconButton(
                                      tooltip: 'Add to playlist',
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        _playlistIcon(theme.useGlassTheme),
                                      ),
                                      onPressed: () =>
                                          _showAddToPlaylistSheet(song),
                                    ),
                                  ],
                                ),
                              ),
                              onTap: () async {
                                await AudioPlayerService().playFromList(
                                  songs: queuedSongs,
                                  startIndex: index,
                                );
                              },
                            ),
                          ),
                        );
                      }),
                  ],
                );
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: ResponsiveLayout.isExpanded(context)
                      ? 760
                      : double.infinity,
                ),
                child: const MiniPlayer(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
