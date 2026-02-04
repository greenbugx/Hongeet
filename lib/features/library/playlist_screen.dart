import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/audio_player_service.dart';
import '../../core/utils/glass_container.dart';
import '../../core/utils/glass_page.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/app_messenger.dart';
import '../../features/library/playlist_manager.dart';
import '../player/mini_player.dart';

class PlaylistScreen extends StatefulWidget {
  final String name;

  const PlaylistScreen({
    super.key,
    required this.name,
  });

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  void _showSongOptions(
      BuildContext context,
      Map<String, dynamic> song,
      ThemeProvider theme,
      ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.9),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),

            // Song info
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      song['imageUrl'],
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 56,
                        height: 56,
                        color: Colors.white12,
                        child: const Icon(Icons.music_note),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song['title'],
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          song['artist'],
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),
            const Divider(height: 1, color: Colors.white12),

            // Remove from playlist option
            ListTile(
              leading: Icon(
                theme.useGlassTheme
                    ? CupertinoIcons.minus_circle
                    : Icons.remove_circle_outline,
                color: Colors.redAccent,
              ),
              title: Text(
                widget.name == PlaylistManager.systemFavourites
                    ? 'Remove from Favorites'
                    : 'Remove from Playlist',
                style: const TextStyle(color: Colors.redAccent),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                await PlaylistManager.removeSong(widget.name, song['id']);
                AppMessenger.show(
                  widget.name == PlaylistManager.systemFavourites
                      ? 'Removed from favorites'
                      : 'Removed from playlist',
                );
              },
            ),

            const Divider(height: 1, color: Colors.white12),

            // Cancel
            ListTile(
              leading: Icon(
                theme.useGlassTheme
                    ? CupertinoIcons.xmark_circle
                    : Icons.cancel_outlined,
              ),
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(ctx),
            ),

            SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = AudioPlayerService();
    final theme = Provider.of<ThemeProvider>(context);

    return GlassPage(
      child: StreamBuilder<Map<String, List<Map<String, dynamic>>>>(
        stream: PlaylistManager.stream,
        builder: (context, snapshot) {
          final playlists = snapshot.data ?? {};
          final songs = playlists[widget.name] ?? [];

          return Stack(
            children: [
              // Main content
              ListView(
                padding: const EdgeInsets.only(bottom: 140),
                children: [
                  const SizedBox(height: 12),

                  // Back button and title
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
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.name,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  if (songs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(
                              theme.useGlassTheme
                                  ? CupertinoIcons.music_note_2
                                  : Icons.music_note,
                              size: 64,
                              color: Colors.white24,
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'No songs yet',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  ...songs.asMap().entries.map((entry) {
                    final index = entry.key;
                    final song = entry.value;

                    return TweenAnimationBuilder<double>(
                      key: ValueKey(song['id']),
                      duration: Duration(milliseconds: 300 + (index * 50)),
                      tween: Tween(begin: 0.0, end: 1.0),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, child) {
                        return Transform.translate(
                          offset: Offset(0, 20 * (1 - value)),
                          child: Opacity(
                            opacity: value,
                            child: child,
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: GlassContainer(
                          child: ListTile(
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                song['imageUrl'],
                                width: 48,
                                height: 48,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 48,
                                  height: 48,
                                  color: Colors.white12,
                                  child: const Icon(Icons.music_note, size: 24),
                                ),
                              ),
                            ),
                            title: Text(song['title']),
                            subtitle: Text(song['artist']),
                            trailing: IconButton(
                              icon: Icon(
                                theme.useGlassTheme
                                    ? CupertinoIcons.ellipsis_vertical
                                    : Icons.more_vert,
                              ),
                              onPressed: () => _showSongOptions(context, song, theme),
                            ),
                            onTap: () async {
                              final queued = songs.map((s) {
                                return QueuedSong(
                                  id: s['id'],
                                  meta: NowPlaying(
                                    title: s['title'],
                                    artist: s['artist'],
                                    imageUrl: s['imageUrl'],
                                  ),
                                );
                              }).toList();

                              await player.playFromList(
                                songs: queued,
                                startIndex: index,
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),

              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: MiniPlayer(),
              ),
            ],
          );
        },
      ),
    );
  }
}