import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:marquee/marquee.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../../core/utils/audio_player_service.dart';
import '../../core/utils/glass_container.dart';
import '../../data/api/local_backend_api.dart';
import '../../data/api/youtube_song_api.dart';
import '../../core/utils/app_messenger.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/youtube_thumbnail_utils.dart';
import '../../core/widgets/fallback_network_image.dart';
import 'widgets/player_progress_bar.dart';

import '../../features/library/playlist_manager.dart';

class FullPlayerSheet extends StatelessWidget {
  const FullPlayerSheet({super.key});

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _downloadSong(QueuedSong song) async {
    try {
      AppMessenger.show(
        'Download queued: ${song.meta.title}',
        color: Colors.blueGrey.shade800,
      );

      if (song.id.startsWith('yt:')) {
        final videoId = song.id.substring(3);
        final audioUrl = await YoutubeSongApi.fetchBestStreamUrl(videoId);
        await LocalBackendApi.downloadDirect(
          title: song.meta.title,
          url: audioUrl,
        );
      } else {
        await LocalBackendApi.downloadSaavn(
          title: song.meta.title,
          songId: song.id,
        );
      }

      AppMessenger.show('Download started', color: Colors.green.shade700);
    } catch (_) {
      AppMessenger.show('Download failed', color: Colors.red.shade700);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = AudioPlayerService();
    final theme = Provider.of<ThemeProvider>(context);
    final perfMode = theme.resolvedUiPerformanceMode(context);
    final fullVisuals = perfMode == UiPerformanceMode.full;
    final backdropBlur = fullVisuals ? 30.0 : 16.0;

    return StreamBuilder<NowPlaying?>(
      stream: player.nowPlayingStream,
      builder: (_, snap) {
        final now = snap.data;
        if (now == null) return const SizedBox.shrink();

        return StreamBuilder<int?>(
          stream: player.currentIndexStream,
          builder: (_, indexSnap) {
            final index = indexSnap.data ?? 0;
            final queue = player.queue;
            final currentSong = index >= 0 && index < queue.length
                ? queue[index]
                : null;
            final currentArtScale = YoutubeThumbnailUtils.preferredArtworkScale(
              songId: currentSong?.id,
              imageUrl: now.imageUrl,
              youtubeVideoScale: 1.9,
              normalScale: 1.0,
            );
            final currentArtCandidates = YoutubeThumbnailUtils.candidateUrls(
              songId: currentSong?.id,
              imageUrl: now.imageUrl,
            );

            final List<_UpcomingSong> upcomingWithIndices = [];
            for (
              int i = index + 1;
              i < queue.length && upcomingWithIndices.length < 10;
              i++
            ) {
              upcomingWithIndices.add(
                _UpcomingSong(song: queue[i], absoluteIndex: i),
              );
            }

            return Stack(
              children: [
                BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: backdropBlur,
                    sigmaY: backdropBlur,
                  ),
                  child: Container(color: Colors.black.withValues(alpha: 0.65)),
                ),

                DraggableScrollableSheet(
                  initialChildSize: 1,
                  maxChildSize: 1,
                  minChildSize: 0.3,
                  builder: (_, controller) {
                    return ListView(
                      controller: controller,
                      cacheExtent: 900,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        const SizedBox(height: 16),

                        RepaintBoundary(
                          child: GlassContainer(
                            borderRadius: BorderRadius.circular(32),
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                children: [
                                  /// Drag handle
                                  Container(
                                    width: 36,
                                    height: 4,
                                    margin: const EdgeInsets.only(bottom: 16),
                                    decoration: BoxDecoration(
                                      color: Colors.white30,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),

                                  AspectRatio(
                                    aspectRatio: 1,
                                    child: ClipRRect(
                                      clipBehavior: Clip.antiAlias,
                                      borderRadius: BorderRadius.circular(22),
                                      child: Transform.scale(
                                        scale: currentArtScale,
                                        child: FallbackNetworkImage(
                                          urls: currentArtCandidates,
                                          fit: BoxFit.cover,
                                          alignment: Alignment.center,
                                          cacheWidth: 768,
                                          cacheHeight: 768,
                                          filterQuality: FilterQuality.medium,
                                          fallback: Container(
                                            color: Colors.black26,
                                            child: const Icon(
                                              Icons.music_note_rounded,
                                              size: 56,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

                                  const SizedBox(height: 20),

                                  /// Title
                                  SizedBox(
                                    height: 26,
                                    child: _AutoMarqueeText(
                                      text: now.title,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),

                                  const SizedBox(height: 6),

                                  /// Artist
                                  SizedBox(
                                    height: 20,
                                    child: _AutoMarqueeText(
                                      text: now.artist,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ),

                                  const SizedBox(height: 20),

                                  /// Seek bar
                                  StreamBuilder<bool>(
                                    stream: player.trackLoadingStream,
                                    initialData: player.isTrackLoading,
                                    builder: (_, loadingSnap) {
                                      final isTrackLoading =
                                          loadingSnap.data ?? false;
                                      return StreamBuilder<Duration>(
                                        stream: player.positionStream,
                                        builder: (_, posSnap) {
                                          final livePos =
                                              posSnap.data ?? Duration.zero;
                                          return StreamBuilder<Duration?>(
                                            stream: player.durationStream,
                                            builder: (_, durSnap) {
                                              final liveDur =
                                                  durSnap.data ?? Duration.zero;
                                              final shownPos = isTrackLoading
                                                  ? Duration.zero
                                                  : livePos;
                                              final shownDur = isTrackLoading
                                                  ? Duration.zero
                                                  : liveDur;
                                              final max = shownDur.inSeconds > 0
                                                  ? shownDur.inSeconds
                                                        .toDouble()
                                                  : 1.0;

                                              return Column(
                                                children: [
                                                  PlayerProgressBar(
                                                    value: shownPos.inSeconds
                                                        .toDouble()
                                                        .clamp(0, max),
                                                    max: max,
                                                    style: theme
                                                        .effectiveProgressBarStyle,
                                                    useGlassTheme:
                                                        theme.useGlassTheme,
                                                    onChanged: isTrackLoading
                                                        ? (_) {}
                                                        : (v) => player.seek(
                                                            Duration(
                                                              seconds: v
                                                                  .toInt(),
                                                            ),
                                                          ),
                                                  ),
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 6,
                                                        ),
                                                    child: Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .spaceBetween,
                                                      children: [
                                                        Text(
                                                          _fmt(shownPos),
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 12,
                                                                color: Colors
                                                                    .white70,
                                                              ),
                                                        ),
                                                        Text(
                                                          _fmt(shownDur),
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 12,
                                                                color: Colors
                                                                    .white70,
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              );
                                            },
                                          );
                                        },
                                      );
                                    },
                                  ),

                                  const SizedBox(height: 12),

                                  // Controls
                                  Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceEvenly,
                                        children: [
                                          StreamBuilder<LoopMode>(
                                            stream: player.loopModeStream,
                                            builder: (_, snap) {
                                              final mode =
                                                  snap.data ?? LoopMode.off;
                                              return IconButton(
                                                icon: Icon(
                                                  mode == LoopMode.one
                                                      ? (theme.useGlassTheme
                                                            ? CupertinoIcons
                                                                  .repeat_1
                                                            : Icons.repeat_one)
                                                      : (theme.useGlassTheme
                                                            ? CupertinoIcons
                                                                  .repeat
                                                            : Icons.repeat),
                                                  color: mode == LoopMode.off
                                                      ? Colors.white54
                                                      : Colors.white,
                                                ),
                                                onPressed:
                                                    player.toggleLoopMode,
                                              );
                                            },
                                          ),
                                          IconButton(
                                            icon: Icon(
                                              theme.useGlassTheme
                                                  ? CupertinoIcons
                                                        .backward_end_fill
                                                  : Icons.skip_previous,
                                            ),
                                            iconSize: 30,
                                            onPressed: player.skipPrevious,
                                          ),
                                          StreamBuilder<bool>(
                                            stream: player.trackLoadingStream,
                                            initialData: player.isTrackLoading,
                                            builder: (_, loadingSnap) {
                                              final isLoading =
                                                  loadingSnap.data ?? false;
                                              return StreamBuilder(
                                                stream:
                                                    player.playerStateStream,
                                                builder: (_, snap) {
                                                  final playing =
                                                      snap.data?.playing ??
                                                      false;
                                                  return AnimatedSwitcher(
                                                    duration: const Duration(
                                                      milliseconds: 200,
                                                    ),
                                                    child: isLoading
                                                        ? SizedBox(
                                                            key: const ValueKey(
                                                              'loading',
                                                            ),
                                                            width: 56,
                                                            height: 56,
                                                            child: Center(
                                                              child: SizedBox(
                                                                width: 28,
                                                                height: 28,
                                                                child: CircularProgressIndicator(
                                                                  strokeWidth:
                                                                      2.8,
                                                                  valueColor:
                                                                      AlwaysStoppedAnimation<
                                                                        Color
                                                                      >(
                                                                        Colors
                                                                            .white,
                                                                      ),
                                                                ),
                                                              ),
                                                            ),
                                                          )
                                                        : IconButton(
                                                            key: ValueKey(
                                                              playing,
                                                            ),
                                                            iconSize: 56,
                                                            icon: Icon(
                                                              playing
                                                                  ? (theme.useGlassTheme
                                                                        ? CupertinoIcons
                                                                              .pause_circle_fill
                                                                        : Icons
                                                                              .pause_circle_filled)
                                                                  : (theme.useGlassTheme
                                                                        ? CupertinoIcons
                                                                              .play_circle_fill
                                                                        : Icons
                                                                              .play_circle_filled),
                                                            ),
                                                            onPressed: player
                                                                .togglePlayPause,
                                                          ),
                                                  );
                                                },
                                              );
                                            },
                                          ),
                                          IconButton(
                                            icon: Icon(
                                              theme.useGlassTheme
                                                  ? CupertinoIcons
                                                        .forward_end_fill
                                                  : Icons.skip_next,
                                            ),
                                            iconSize: 30,
                                            onPressed: player.skipNext,
                                          ),
                                          if (currentSong != null &&
                                              !currentSong.isLocal)
                                            IconButton(
                                              icon: Icon(
                                                theme.useGlassTheme
                                                    ? CupertinoIcons.arrow_down
                                                    : Icons.download,
                                              ),
                                              onPressed: () =>
                                                  _downloadSong(currentSong),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),

                                      // Secondary controls
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          StreamBuilder<
                                            Map<
                                              String,
                                              List<Map<String, dynamic>>
                                            >
                                          >(
                                            stream: PlaylistManager.stream,
                                            builder: (_, snap) {
                                              final playlists = snap.data ?? {};
                                              final favs =
                                                  playlists[PlaylistManager
                                                      .systemFavourites] ??
                                                  [];
                                              final isFav =
                                                  currentSong != null &&
                                                  favs.any(
                                                    (s) =>
                                                        s['id'] ==
                                                        currentSong.id,
                                                  );

                                              return IconButton(
                                                icon: Icon(
                                                  theme.useGlassTheme
                                                      ? (isFav
                                                            ? CupertinoIcons
                                                                  .heart_fill
                                                            : CupertinoIcons
                                                                  .heart)
                                                      : (isFav
                                                            ? Icons.favorite
                                                            : Icons
                                                                  .favorite_border),
                                                  color: isFav
                                                      ? Colors.redAccent
                                                      : Colors.white70,
                                                ),
                                                iconSize: 26,
                                                onPressed: currentSong == null
                                                    ? null
                                                    : () async =>
                                                          await PlaylistManager.toggleFavourite(
                                                            {
                                                              'id': currentSong
                                                                  .id,
                                                              'title':
                                                                  currentSong
                                                                      .meta
                                                                      .title,
                                                              'artist':
                                                                  currentSong
                                                                      .meta
                                                                      .artist,
                                                              'imageUrl':
                                                                  currentSong
                                                                      .meta
                                                                      .imageUrl,
                                                            },
                                                          ),
                                              );
                                            },
                                          ),
                                          const SizedBox(width: 24),
                                          IconButton(
                                            icon: Icon(
                                              theme.useGlassTheme
                                                  ? CupertinoIcons
                                                        .music_note_list
                                                  : Icons.playlist_add,
                                              color: Colors.white70,
                                            ),
                                            iconSize: 26,
                                            onPressed: currentSong == null
                                                ? null
                                                : () {
                                                    _showAddToPlaylistSheet(
                                                      context,
                                                      currentSong,
                                                    );
                                                  },
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        if (upcomingWithIndices.isNotEmpty) ...[
                          const SizedBox(height: 28),
                          const Text(
                            'Up Next',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ...upcomingWithIndices.map(
                            (upcomingSong) => RepaintBoundary(
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: GlassContainer(
                                  child: ListTile(
                                    leading: ClipRRect(
                                      clipBehavior: Clip.antiAlias,
                                      borderRadius: BorderRadius.circular(8),
                                      child: Transform.scale(
                                        scale:
                                            YoutubeThumbnailUtils.preferredArtworkScale(
                                              songId: upcomingSong.song.id,
                                              imageUrl: upcomingSong
                                                  .song
                                                  .meta
                                                  .imageUrl,
                                              youtubeVideoScale: 1.9,
                                              normalScale: 1.0,
                                            ),
                                        child: FallbackNetworkImage(
                                          urls:
                                              YoutubeThumbnailUtils.candidateUrls(
                                                songId: upcomingSong.song.id,
                                                imageUrl: upcomingSong
                                                    .song
                                                    .meta
                                                    .imageUrl,
                                              ),
                                          width: 48,
                                          height: 48,
                                          cacheWidth: 256,
                                          cacheHeight: 256,
                                          fit: BoxFit.cover,
                                          alignment: Alignment.center,
                                          filterQuality: FilterQuality.medium,
                                          fallback: Container(
                                            width: 48,
                                            height: 48,
                                            color: Colors.black26,
                                            child: const Icon(
                                              Icons.music_note_rounded,
                                              size: 22,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    title: Text(
                                      upcomingSong.song.meta.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      upcomingSong.song.meta.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing:
                                        StreamBuilder<
                                          Map<
                                            String,
                                            List<Map<String, dynamic>>
                                          >
                                        >(
                                          stream: PlaylistManager.stream,
                                          builder: (_, playlistSnap) {
                                            final playlists =
                                                playlistSnap.data ?? {};
                                            final favs =
                                                playlists[PlaylistManager
                                                    .systemFavourites] ??
                                                [];
                                            final isFav = favs.any(
                                              (s) =>
                                                  s['id'] ==
                                                  upcomingSong.song.id,
                                            );

                                            return Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                IconButton(
                                                  tooltip: isFav
                                                      ? 'Remove from favorites'
                                                      : 'Add to favorites',
                                                  iconSize: 20,
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  constraints:
                                                      const BoxConstraints.tightFor(
                                                        width: 32,
                                                        height: 32,
                                                      ),
                                                  icon: Icon(
                                                    theme.useGlassTheme
                                                        ? (isFav
                                                              ? CupertinoIcons
                                                                    .heart_fill
                                                              : CupertinoIcons
                                                                    .heart)
                                                        : (isFav
                                                              ? Icons.favorite
                                                              : Icons
                                                                    .favorite_border),
                                                    color: isFav
                                                        ? Colors.redAccent
                                                        : Colors.white70,
                                                  ),
                                                  onPressed: () async =>
                                                      await PlaylistManager.toggleFavourite(
                                                        {
                                                          'id': upcomingSong
                                                              .song
                                                              .id,
                                                          'title': upcomingSong
                                                              .song
                                                              .meta
                                                              .title,
                                                          'artist': upcomingSong
                                                              .song
                                                              .meta
                                                              .artist,
                                                          'imageUrl':
                                                              upcomingSong
                                                                  .song
                                                                  .meta
                                                                  .imageUrl,
                                                        },
                                                      ),
                                                ),
                                                IconButton(
                                                  tooltip: 'Add to playlist',
                                                  iconSize: 20,
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  constraints:
                                                      const BoxConstraints.tightFor(
                                                        width: 32,
                                                        height: 32,
                                                      ),
                                                  icon: Icon(
                                                    theme.useGlassTheme
                                                        ? CupertinoIcons
                                                              .music_note_list
                                                        : Icons.playlist_add,
                                                    color: Colors.white70,
                                                  ),
                                                  onPressed: () =>
                                                      _showAddToPlaylistSheet(
                                                        context,
                                                        upcomingSong.song,
                                                      ),
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                    onTap: () => player.jumpToIndex(
                                      upcomingSong.absoluteIndex,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 32),
                      ],
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }
}

void _showAddToPlaylistSheet(BuildContext context, QueuedSong song) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.black.withValues(alpha: 0.85),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) {
      return StreamBuilder<Map<String, List<Map<String, dynamic>>>>(
        stream: PlaylistManager.stream,
        builder: (_, snap) {
          final playlists = snap.data ?? {};

          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Add to Playlist',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),

                if (playlists.isEmpty)
                  const Text(
                    'No playlists yet',
                    style: TextStyle(color: Colors.white54),
                  ),

                ...playlists.keys
                    .where((name) => name != PlaylistManager.systemFavourites)
                    .map(
                      (name) => ListTile(
                        leading: const Icon(CupertinoIcons.music_note_list),
                        title: Text(name),
                        onTap: () async {
                          final navigator = Navigator.of(context);
                          final success = await PlaylistManager.addSong(name, {
                            'id': song.id,
                            'title': song.meta.title,
                            'artist': song.meta.artist,
                            'imageUrl': song.meta.imageUrl,
                          });

                          navigator.pop();

                          if (success) {
                            AppMessenger.show(
                              'Added to "$name"',
                              color: Colors.green.shade700,
                            );
                          } else {
                            AppMessenger.show(
                              'Already in "$name"',
                              color: Colors.orange.shade700,
                            );
                          }
                        },
                      ),
                    ),

                const SizedBox(height: 8),

                TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    _showCreatePlaylistDialog(context);
                  },
                  child: const Text('＋ Create new playlist'),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

void _showCreatePlaylistDialog(BuildContext context) {
  final controller = TextEditingController();

  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('New Playlist'),
      content: TextField(
        controller: controller,
        decoration: const InputDecoration(hintText: 'Playlist name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () async {
            final name = controller.text.trim();
            if (name.isEmpty) return;

            final navigator = Navigator.of(context);
            await PlaylistManager.create(name);
            navigator.pop();
            AppMessenger.show(
              'Playlist "$name" created',
              color: Colors.green.shade700,
            );
          },
          child: const Text('Create'),
        ),
      ],
    ),
  );
}

class _UpcomingSong {
  final QueuedSong song;
  final int absoluteIndex;

  _UpcomingSong({required this.song, required this.absoluteIndex});
}

/// Auto marquee
class _AutoMarqueeText extends StatelessWidget {
  final String text;
  final TextStyle style;

  const _AutoMarqueeText({required this.text, required this.style});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, c) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();

        if (painter.width <= c.maxWidth) {
          return Text(
            text,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          );
        }

        return Marquee(
          text: text,
          blankSpace: 40,
          velocity: 28,
          pauseAfterRound: const Duration(seconds: 1),
          style: style,
        );
      },
    );
  }
}
