import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:marquee/marquee.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/app_messenger.dart';
import '../../core/utils/audio_player_service.dart';
import '../../core/utils/glass_container.dart';
import '../../core/utils/glass_page.dart';
import '../player/mini_player.dart';
import 'downloaded_songs_provider.dart';

class DownloadedSongsScreen extends StatefulWidget {
  const DownloadedSongsScreen({super.key});

  @override
  State<DownloadedSongsScreen> createState() => _DownloadedSongsScreenState();
}

class _DownloadedSongsScreenState extends State<DownloadedSongsScreen> {
  late Future<List<DownloadedSong>> _songsFuture;
  StreamSubscription<int>? _downloadsChangeSub;

  @override
  void initState() {
    super.initState();
    _songsFuture = DownloadedSongsProvider.load();
    _downloadsChangeSub = DownloadedSongsProvider.changes.listen((_) {
      if (!mounted) return;
      _refresh();
    });
  }

  @override
  void dispose() {
    _downloadsChangeSub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _songsFuture = DownloadedSongsProvider.load();
    });
  }

  Future<void> _deleteSong(DownloadedSong song) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Song'),
        content: Text('Delete "${song.name}" from downloads?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final player = AudioPlayerService();
    final currentIndex = player.currentIndex;
    final queue = player.queue;
    final isDeletedSongCurrentlyPlaying =
        currentIndex != null &&
        currentIndex >= 0 &&
        currentIndex < queue.length &&
        queue[currentIndex].id == song.path;

    await DownloadedSongsProvider.delete(song.path);
    if (isDeletedSongCurrentlyPlaying) {
      await player.stopAndClearNowPlaying();
    }
    if (!mounted) return;
    AppMessenger.show('Deleted ${song.name}');
    await _refresh();
  }

  Widget _emptyState(String text) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(text, style: const TextStyle(color: Colors.white54)),
      ),
    );
  }

  Widget _buildSongTitle(String text) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = Theme.of(context).textTheme.titleMedium;
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);

        if (!painter.didExceedMaxLines) {
          return Text(
            text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          );
        }

        final height = (style?.fontSize ?? 16) * 1.35;
        return SizedBox(
          height: height,
          child: Marquee(
            text: text,
            style: style,
            blankSpace: 28,
            velocity: 24,
            pauseAfterRound: const Duration(milliseconds: 900),
            startPadding: 6,
            fadingEdgeStartFraction: 0.08,
            fadingEdgeEndFraction: 0.08,
            accelerationDuration: const Duration(milliseconds: 250),
            decelerationDuration: const Duration(milliseconds: 250),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final player = AudioPlayerService();

    return GlassPage(
      child: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 140),
              children: [
                const SizedBox(height: 12),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        themeProvider.useGlassTheme
                            ? CupertinoIcons.back
                            : Icons.arrow_back,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Downloaded Songs',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                FutureBuilder<List<DownloadedSong>>(
                  future: _songsFuture,
                  builder: (_, snap) {
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final songs = snap.data!;
                    if (songs.isEmpty) {
                      return _emptyState('No downloaded songs');
                    }

                    return Column(
                      children: songs.asMap().entries.map((entry) {
                        final index = entry.key;
                        final song = entry.value;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: GlassContainer(
                            child: ListTile(
                              leading: Icon(
                                themeProvider.useGlassTheme
                                    ? CupertinoIcons.arrow_down_circle
                                    : Icons.download_done,
                              ),
                              title: _buildSongTitle(song.name),
                              onTap: () {
                                // Build queue from all downloaded songs, starting at clicked song
                                player.playLocalFiles(
                                  files: songs
                                      .map((s) => (path: s.path, name: s.name))
                                      .toList(),
                                  startIndex: index,
                                );
                                AppMessenger.show('Playing ${song.name}');
                              },
                              trailing: IconButton(
                                icon: Icon(
                                  themeProvider.useGlassTheme
                                      ? CupertinoIcons.trash
                                      : Icons.delete_outline,
                                ),
                                onPressed: () => _deleteSong(song),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
          ),
          const Positioned(left: 0, right: 0, bottom: 0, child: MiniPlayer()),
        ],
      ),
    );
  }
}
