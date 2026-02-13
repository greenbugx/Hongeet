import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
    const miniGapAboveNav = 20.0;
    final miniPlayerBottom =
        kBottomNavigationBarHeight +
        navBottomPadding +
        miniGapAboveNav +
        bottomInset;
    final tabs = <Widget>[
      SearchScreen(key: ValueKey('search_$_searchScreenVersion')),
      const LibraryScreen(),
      SettingsScreen(onMusicServiceChanged: _onMusicServiceChanged),
    ];

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          // Main screen
          IndexedStack(
            index: _index,
            children: List<Widget>.generate(
              tabs.length,
              (i) => RepaintBoundary(
                child: TickerMode(enabled: i == _index, child: tabs[i]),
              ),
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: miniPlayerBottom,
            child: const MiniPlayer(),
          ),
        ],
      ),

      // Bottom Navigation
      bottomNavigationBar: Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, navBottomPadding + bottomInset),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Container(
            color: Colors.white.withValues(alpha: 0.08),
            child: BottomNavigationBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              currentIndex: _index,
              onTap: (i) {
                if (i == _index) return;
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
    );
  }
}
