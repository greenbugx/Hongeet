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
                  filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  child: Container(color: Colors.black.withOpacity(0.65)),
                ),

                DraggableScrollableSheet(
                  initialChildSize: 1,
                  maxChildSize: 1,
                  minChildSize: 0.3,
                  builder: (_, controller) {
                    return ListView(
                      controller: controller,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        const SizedBox(height: 16),

                        GlassContainer(
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
                                      scale: 1.9,
                                      child: Image.network(
                                        now.imageUrl,
                                        fit: BoxFit.cover,
                                        alignment: Alignment.center,
                                        filterQuality: FilterQuality.medium,
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
                                StreamBuilder<Duration>(
                                  stream: player.positionStream,
                                  builder: (_, posSnap) {
                                    final pos = posSnap.data ?? Duration.zero;
                                    return StreamBuilder<Duration?>(
                                      stream: player.durationStream,
                                      builder: (_, durSnap) {
                                        final dur =
                                            durSnap.data ?? Duration.zero;
                                        final max = dur.inSeconds > 0
                                            ? dur.inSeconds.toDouble()
                                            : 1.0;

                                        return Column(
                                          children: [
                                            Slider(
                                              value: pos.inSeconds
                                                  .toDouble()
                                                  .clamp(0, max),
                                              max: max,
                                              onChanged: (v) => player.seek(
                                                Duration(seconds: v.toInt()),
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
                                                    _fmt(pos),
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color: Colors.white70,
                                                    ),
                                                  ),
                                                  Text(
                                                    _fmt(dur),
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color: Colors.white70,
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
                                              onPressed: player.toggleLoopMode,
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
                                        StreamBuilder(
                                          stream: player.playerStateStream,
                                          builder: (_, snap) {
                                            final playing =
                                                snap.data?.playing ?? false;
                                            return IconButton(
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
                                              onPressed: player.togglePlayPause,
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
                                                      s['id'] == currentSong.id,
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
                                                            'id':
                                                                currentSong.id,
                                                            'title': currentSong
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
                                                ? CupertinoIcons.music_note_list
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
                            (upcomingSong) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: GlassContainer(
                                child: ListTile(
                                  leading: ClipRRect(
                                    clipBehavior: Clip.antiAlias,
                                    borderRadius: BorderRadius.circular(8),
                                    child: Transform.scale(
                                      scale: 1.9,
                                      child: Image.network(
                                        upcomingSong.song.meta.imageUrl,
                                        width: 48,
                                        height: 48,
                                        fit: BoxFit.cover,
                                        alignment: Alignment.center,
                                        filterQuality: FilterQuality.medium,
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
                                  onTap: () => player.jumpToIndex(
                                    upcomingSong.absoluteIndex,
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
    backgroundColor: Colors.black.withOpacity(0.85),
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
                          final success = await PlaylistManager.addSong(name, {
                            'id': song.id,
                            'title': song.meta.title,
                            'artist': song.meta.artist,
                            'imageUrl': song.meta.imageUrl,
                          });

                          Navigator.pop(context);

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

            await PlaylistManager.create(name);
            Navigator.pop(context);
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
