import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hongit/core/theme/app_theme.dart';
import 'package:hongit/core/utils/glass_page.dart';
import 'package:provider/provider.dart';
import '../../core/utils/app_messenger.dart';
import '../../core/utils/glass_container.dart';
import '../../core/utils/audio_player_service.dart';
import '../../features/library/playlist_manager.dart';
import 'downloaded_songs_screen.dart';
import 'local_audios_screen.dart';
import 'playlist_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  void _showPlaylistOptions(
    BuildContext context,
    String playlistName,
    ThemeProvider theme,
  ) {
    if (playlistName == PlaylistManager.systemFavourites) {
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.9),
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

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                playlistName,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),

            const SizedBox(height: 20),
            const Divider(height: 1, color: Colors.white12),

            // Delete playlist option
            ListTile(
              leading: Icon(
                theme.useGlassTheme
                    ? CupertinoIcons.trash
                    : Icons.delete_outline,
                color: Colors.redAccent,
              ),
              title: const Text(
                'Delete Playlist',
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () async {
                Navigator.pop(ctx);

                // Confirm deletion
                final confirmDelete = await showDialog(
                  context: context,
                  builder: (ctx2) => AlertDialog(
                    title: const Text('Delete Playlist'),
                    content: Text(
                      'Are you sure you want to delete "$playlistName"? This cannot be undone.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx2, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx2, true),
                        child: const Text(
                          'Delete',
                          style: TextStyle(color: Colors.redAccent),
                        ),
                      ),
                    ],
                  ),
                );

                if (confirmDelete == true) {
                  await PlaylistManager.deletePlaylist(playlistName);
                  AppMessenger.show('Playlist deleted');
                }
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

  Widget _buildAnimatedListItem({
    required Widget child,
    required int index,
    required bool animate,
  }) {
    if (!animate) return child;

    return TweenAnimationBuilder<double>(
      duration: Duration(milliseconds: 200 + (index * 50)),
      tween: Tween(begin: 0.0, end: 1.0),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(20 * (1 - value), 0),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = AudioPlayerService();
    final themeProvider = Provider.of<ThemeProvider>(context);
    final perfMode = themeProvider.resolvedUiPerformanceMode(context);
    final animateListItems = perfMode == UiPerformanceMode.full;

    return GlassPage(
      child: ListView(
        children: [
          const Text(
            'Library',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 24),

          const Text(
            'Quick Access',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),

          GlassContainer(
            child: ListTile(
              leading: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.arrow_down_circle
                    : Icons.download_done,
              ),
              title: const Text('Downloaded Songs'),
              subtitle: const Text('Open downloaded songs'),
              trailing: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.right_chevron
                    : Icons.chevron_right,
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DownloadedSongsScreen(),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 12),

          GlassContainer(
            child: ListTile(
              leading: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.heart_fill
                    : Icons.favorite,
              ),
              title: const Text('Favourite Songs'),
              subtitle: const Text('Your liked songs playlist'),
              trailing: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.right_chevron
                    : Icons.chevron_right,
              ),
              onTap: () {
                Navigator.of(context).push(
                  PageRouteBuilder(
                    opaque: false,
                    transitionDuration: const Duration(milliseconds: 300),
                    reverseTransitionDuration: const Duration(
                      milliseconds: 300,
                    ),
                    pageBuilder: (context, animation, secondaryAnimation) =>
                        const PlaylistScreen(
                          name: PlaylistManager.systemFavourites,
                        ),
                    transitionsBuilder:
                        (context, animation, secondaryAnimation, child) {
                          const begin = Offset(1.0, 0.0);
                          const end = Offset.zero;
                          const curve = Curves.easeInOutCubic;

                          final tween = Tween(
                            begin: begin,
                            end: end,
                          ).chain(CurveTween(curve: curve));

                          return SlideTransition(
                            position: animation.drive(tween),
                            child: child,
                          );
                        },
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 12),

          GlassContainer(
            child: ListTile(
              leading: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.music_note_list
                    : Icons.library_music,
              ),
              title: const Text('Local Audios'),
              subtitle: const Text('Browse audio files from your device'),
              trailing: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.right_chevron
                    : Icons.chevron_right,
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LocalAudiosScreen()),
                );
              },
            ),
          ),

          const SizedBox(height: 32),

          const Text(
            'Playlists',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),

          StreamBuilder<Map<String, List<Map<String, dynamic>>>>(
            stream: PlaylistManager.stream,
            builder: (_, snap) {
              final playlists = snap.data ?? {};
              final userPlaylistNames = playlists.keys
                  .where((name) => name != PlaylistManager.systemFavourites)
                  .toList();
              if (userPlaylistNames.isEmpty) return _empty('No playlists');

              return Column(
                children: userPlaylistNames.asMap().entries.map((entry) {
                  final index = entry.key;
                  final name = entry.value;

                  return _buildAnimatedListItem(
                    index: index,
                    animate: animateListItems,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: GlassContainer(
                        child: ListTile(
                          leading: Icon(
                            themeProvider.useGlassTheme
                                ? CupertinoIcons.music_albums
                                : Icons.queue_music,
                          ),
                          subtitle: Text(
                            '${playlists[name]!.length} songs',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          title: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: Icon(
                              themeProvider.useGlassTheme
                                  ? CupertinoIcons.ellipsis
                                  : Icons.more_vert,
                            ),
                            onPressed: () => _showPlaylistOptions(
                              context,
                              name,
                              themeProvider,
                            ),
                          ),
                          onTap: () {
                            Navigator.of(context).push(
                              PageRouteBuilder(
                                opaque: false,
                                transitionDuration: const Duration(
                                  milliseconds: 300,
                                ),
                                reverseTransitionDuration: const Duration(
                                  milliseconds: 300,
                                ),
                                pageBuilder:
                                    (context, animation, secondaryAnimation) =>
                                        PlaylistScreen(name: name),
                                transitionsBuilder:
                                    (
                                      context,
                                      animation,
                                      secondaryAnimation,
                                      child,
                                    ) {
                                      const begin = Offset(1.0, 0.0);
                                      const end = Offset.zero;
                                      const curve = Curves.easeInOutCubic;

                                      final tween = Tween(
                                        begin: begin,
                                        end: end,
                                      ).chain(CurveTween(curve: curve));

                                      return SlideTransition(
                                        position: animation.drive(tween),
                                        child: child,
                                      );
                                    },
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),

          const SizedBox(height: 32),

          const Text(
            'Recently Played',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: player.recentlyPlayedStream,
            builder: (_, snap) {
              final items = (snap.data ?? []).take(20).toList();
              if (items.isEmpty) return _empty('Nothing played yet');

              return Column(
                children: items.asMap().entries.map((entry) {
                  final index = entry.key;
                  final song = entry.value;

                  return _buildAnimatedListItem(
                    index: index,
                    animate: animateListItems,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: GlassContainer(
                        child: ListTile(
                          leading: Icon(
                            themeProvider.useGlassTheme
                                ? CupertinoIcons.time
                                : Icons.history,
                          ),
                          subtitle: Text(
                            song['artist'],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          title: Text(
                            song['title'],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => player.playFromCache(song),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),

          const SizedBox(height: 120),
        ],
      ),
    );
  }

  Widget _empty(String text) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(text, style: const TextStyle(color: Colors.white54)),
      ),
    );
  }
}
