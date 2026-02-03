import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hongit/core/theme/app_theme.dart';
import 'package:hongit/core/utils/audio_player_service.dart';
import 'package:hongit/data/api/saavn_api.dart';
import 'package:hongit/data/models/saavn_song.dart';
import 'package:hongit/features/search/widgets/song_card.dart';
import 'package:provider/provider.dart';
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

  static const int minSearchLength = 2;

  bool get isSearching => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _searchFuture = SaavnApi.searchSongs('eminem');
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    final trimmed = query.trim();

    if (trimmed.isEmpty) {
      setState(() {
        _lastQuery = '';
        _searchFuture = SaavnApi.searchSongs('eminem');
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
        _searchFuture = SaavnApi.searchSongs(trimmed);
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

    return GlassPage(
      child: ListView(
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
                      color: Colors.white70),
                  hintText: 'Search songs, artists...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                  suffixIcon: _controller.text.isNotEmpty
                      ? IconButton(
                    icon: Icon(
                        themeProvider.useGlassTheme
                            ? CupertinoIcons.clear_circled_solid
                            : Icons.close,
                        color: Colors.white70),
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

          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              isSearching ? 'Search Results' : 'Quick Picks',
              key: ValueKey(isSearching),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
            ),
          ),

          const SizedBox(height: 16),

          // Results
          _buildSearchResults(context),

          const SizedBox(height: 80),
        ],
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
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
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

        final songs = snapshot.data!;

        final queuedSongs = songs
            .map((s) => QueuedSong(
          id: s.id,
          meta: NowPlaying(
            title: s.name,
            artist: s.artists,
            imageUrl: s.imageUrl,
          ),
        ))
            .toList();

        return GridView.builder(
          padding: const EdgeInsets.only(bottom: 16),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.68,
          ),
          itemCount: songs.length,
          itemBuilder: (_, i) {
            final song = songs[i];

            return SongCard(
              song: song,
              onTap: () async {
                if (i < 0 || i >= queuedSongs.length) return;

                await AudioPlayerService().playFromList(
                  songs: queuedSongs,
                  startIndex: i,
                );
              },
            );
          },
        );
      },
    );
  }
}