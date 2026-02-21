import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/theme/app_theme.dart';
import '../library/library_screen.dart';
import '../search/search_screen.dart';
import '../settings/settings_screen.dart';
import '../player/mini_player.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;
  int _searchScreenVersion = 0;

  void _onMusicServiceChanged(bool _) {
    setState(() {
      _searchScreenVersion++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    const navBottomPadding = 12.0;

    return FutureBuilder<Map<String, bool>>(
      future: SharedPreferences.getInstance().then(
        (prefs) => {
          'use_youtube_service': prefs.getBool('use_youtube_service') ?? false,
          'use_saavn_service': prefs.getBool('use_saavn_service') ?? false,
        },
      ),
      builder: (context, snapshot) {
        final useYoutube = snapshot.data?['use_youtube_service'] ?? false;
        final useSaavn = snapshot.data?['use_saavn_service'] ?? false;
        final isLocalMode = !useYoutube && !useSaavn;

        final tabs = <Widget>[
          SearchScreen(key: ValueKey('search_$_searchScreenVersion')),
          // Keep a placeholder in place of Library when in local-only mode so the tab indices remain stable and we don't force navigation
          isLocalMode
              ? const _DisabledLibraryPlaceholder()
              : const LibraryScreen(),
          SettingsScreen(onMusicServiceChanged: _onMusicServiceChanged),
        ];

        int displayIndex = _index;
        if (displayIndex >= tabs.length) displayIndex = 0;

        return Scaffold(
          extendBody: false,
          body: IndexedStack(
            index: displayIndex,
            children: List<Widget>.generate(
              tabs.length,
              (i) => RepaintBoundary(
                child: TickerMode(enabled: i == displayIndex, child: tabs[i]),
              ),
            ),
          ),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MiniPlayer(),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  0,
                  12,
                  navBottomPadding + bottomInset,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    color: Colors.white.withValues(alpha: 0.08),
                    child: BottomNavigationBar(
                      backgroundColor: Colors.transparent,
                      elevation: 0,
                      currentIndex: displayIndex,
                      onTap: (i) {
                        if (i == displayIndex) return;
                        setState(() => _index = i);
                      },
                      items: [
                        BottomNavigationBarItem(
                          icon: Icon(
                            themeProvider.useGlassTheme
                                ? CupertinoIcons.search
                                : Icons.search,
                          ),
                          label: 'Search',
                        ),
                        BottomNavigationBarItem(
                          icon: Icon(
                            themeProvider.useGlassTheme
                                ? CupertinoIcons.music_albums
                                : Icons.library_music,
                            color: isLocalMode ? Colors.white24 : null,
                          ),
                          label: 'Library',
                        ),
                        BottomNavigationBarItem(
                          icon: Icon(
                            themeProvider.useGlassTheme
                                ? CupertinoIcons.settings
                                : Icons.settings,
                          ),
                          label: 'Settings',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DisabledLibraryPlaceholder extends StatelessWidget {
  const _DisabledLibraryPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.library_music, size: 56, color: Colors.white38),
            SizedBox(height: 12),
            Text(
              'Library is disabled in Local-only mode',
              style: TextStyle(color: Colors.white54),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
