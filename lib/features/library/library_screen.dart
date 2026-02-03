import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hongit/core/theme/app_theme.dart';
import 'package:hongit/core/utils/glass_page.dart';
import 'package:provider/provider.dart';
import '../../core/utils/glass_container.dart';
import '../../core/utils/audio_player_service.dart';
import '../../core/utils/app_messenger.dart';
import '../library/downloaded_songs_provider.dart';
import '../../features/library/playlist_manager.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late Future<List<DownloadedSong>> _downloads;

  @override
  void initState() {
    super.initState();
    _downloads = DownloadedSongsProvider.load();
  }

  Future<void> _refreshDownloads() async {
    setState(() {
      _downloads = DownloadedSongsProvider.load();
    });
  }

  void _deleteSong(DownloadedSong song) async {
    final confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Song'),
        content: Text('Are you sure you want to delete ${song.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );

    if (confirm == true) {
      await DownloadedSongsProvider.delete(song.path);
      AppMessenger.show('Deleted ${song.name}');
      _refreshDownloads();
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = AudioPlayerService();
    final themeProvider = Provider.of<ThemeProvider>(context);

    return GlassPage(
      child: RefreshIndicator(
        onRefresh: _refreshDownloads,
        child: ListView(
          children: [
            const Text(
              'Library',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 24),
            const Text(
              'Downloaded',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            FutureBuilder(
              future: _downloads,
              builder: (_, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final songs = snap.data!;
                if (songs.isEmpty) return _empty('No downloaded songs');

                return Column(
                  children: songs.map((song) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: GlassContainer(
                        child: ListTile(
                          leading: Icon(themeProvider.useGlassTheme
                              ? CupertinoIcons.arrow_down_circle
                              : Icons.download_done),
                          title: Text(song.name),
                          onTap: () {
                            player.playLocalFile(song.path, song.name);
                            AppMessenger.show('Playing ${song.name}');
                          },
                          trailing: IconButton(
                            icon: Icon(themeProvider.useGlassTheme
                                ? CupertinoIcons.ellipsis
                                : Icons.more_vert),
                            onPressed: () => _deleteSong(song),
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
              'Playlists',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),

            StreamBuilder<Map<String, List<Map<String, dynamic>>>>(
              stream: PlaylistManager.stream,
              builder: (_, snap) {
                final playlists = snap.data ?? {};
                if (playlists.isEmpty) return _empty('No playlists');

                return Column(
                  children: playlists.keys.map((name) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: GlassContainer(
                        child: ListTile(
                          leading: Icon(
                            themeProvider.useGlassTheme
                                ? CupertinoIcons.heart_fill
                                : Icons.favorite,
                          ),
                          title: Text(name),
                          subtitle: Text(
                            name == PlaylistManager.systemFavourites
                                ? 'Liked songs'
                                : '${playlists[name]!.length} songs',
                          ),
                          onTap: () async {
                            final songs = PlaylistManager.getSongs(name);

                            if (songs.isEmpty) {
                              AppMessenger.show('Playlist is empty');
                              return;
                            }

                            await player.playPlaylist(
                              songs: songs,
                              title: name,
                            );

                            AppMessenger.show(
                              'Playing "$name"',
                              color: Colors.green.shade700,
                            );
                          },
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
                final items = snap.data ?? [];
                if (items.isEmpty) return _empty('Nothing played yet');

                return Column(
                  children: items.map((song) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: GlassContainer(
                        child: ListTile(
                          leading: Icon(themeProvider.useGlassTheme
                              ? CupertinoIcons.time
                              : Icons.history),
                          title: Text(song['title']),
                          subtitle: Text(song['artist']),
                          onTap: () => player.playFromCache(song),
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
