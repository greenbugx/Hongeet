import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/theme/responsive.dart';
import '../../core/utils/app_distribution.dart';
import '../../core/utils/app_update_service.dart';
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
  static const _startupUpdateCheckDoneKey = 'startup_update_check_done_v1';

  int _index = 0;
  int _searchScreenVersion = 0;

  bool _useYoutube = false;
  bool _useSaavn = false;

  @override
  void initState() {
    super.initState();
    _loadStreamingPrefs();
    _runStartupUpdateCheckIfNeeded();
  }

  Future<void> _loadStreamingPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _useYoutube = prefs.getBool('use_youtube_service') ?? false;
      _useSaavn = prefs.getBool('use_saavn_service') ?? false;
    });
  }

  Future<void> _runStartupUpdateCheckIfNeeded() async {
    final enabled = await AppDistribution.isStartupUpdateCheckEnabled();
    if (!enabled) return;

    final prefs = await SharedPreferences.getInstance();
    final alreadyChecked = prefs.getBool(_startupUpdateCheckDoneKey) ?? false;
    if (alreadyChecked) return;

    await prefs.setBool(_startupUpdateCheckDoneKey, true);

    try {
      final result = await AppUpdateService().checkForUpdates();
      if (!mounted || !result.hasUpdate) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showUpdateDialog(context, result);
      });
    } catch (_) {
      // Ignore startup update-check errors to avoid interrupting app launch.
    }
  }

  void _onMusicServiceChanged(bool _) {
    _loadStreamingPrefs();
    setState(() {
      _searchScreenVersion++;
    });
  }

  void _onDestinationSelected(int nextIndex, {required bool isLocalMode}) {
    if (nextIndex == _index) return;
    if (nextIndex == 1 && isLocalMode) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enable Saavn or YouTube in Settings to use Library'),
        ),
      );
      return;
    }
    setState(() => _index = nextIndex);
  }

  String _labelForIndex(int index) {
    switch (index) {
      case 0:
        return 'Search';
      case 1:
        return 'Library';
      default:
        return 'Settings';
    }
  }

  IconData _iconForIndex(int index, {required bool selected}) {
    switch (index) {
      case 0:
        return selected ? Icons.search : Icons.search_outlined;
      case 1:
        return selected ? Icons.library_music : Icons.library_music_outlined;
      default:
        return selected ? Icons.settings : Icons.settings_outlined;
    }
  }

  Widget _buildQuickTabSwitcher({
    required BuildContext context,
    required int displayIndex,
    required bool isLocalMode,
    required double top,
    required double bottom,
  }) {
    final scheme = Theme.of(context).colorScheme;

    Widget buildQuickIcon(int index) {
      final selected = index == displayIndex;
      final disabled = index == 1 && isLocalMode;
      final icon = _iconForIndex(index, selected: selected);
      final iconColor = disabled
          ? scheme.onSurface.withValues(alpha: 0.35)
          : selected
          ? scheme.onSecondaryContainer
          : scheme.onSurfaceVariant;

      return Tooltip(
        message: _labelForIndex(index),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: disabled
                ? null
                : () => _onDestinationSelected(index, isLocalMode: isLocalMode),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: selected
                    ? scheme.secondaryContainer.withValues(alpha: 0.95)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, size: 22, color: iconColor),
            ),
          ),
        ),
      );
    }

    return Positioned(
      top: top,
      right: 8,
      bottom: bottom,
      child: Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
          elevation: 4,
          shadowColor: scheme.shadow.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(18),
          child: Container(
            width: 50,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                buildQuickIcon(0),
                const SizedBox(height: 16),
                buildQuickIcon(1),
                const SizedBox(height: 16),
                buildQuickIcon(2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottomInset = media.viewPadding.bottom;
    final keyboardHeight = media.viewInsets.bottom;
    final quickSwitcherTop = media.padding.top + 90;
    final quickSwitcherBottom = keyboardHeight == 0
        ? (108 + bottomInset)
        : 24.0;
    final miniPlayerBottom = 12 + bottomInset;

    final isLocalMode = !_useYoutube && !_useSaavn;

    final tabs = <Widget>[
      SearchScreen(key: ValueKey('search_$_searchScreenVersion')),
      isLocalMode ? const _DisabledLibraryPlaceholder() : const LibraryScreen(),
      SettingsScreen(onMusicServiceChanged: _onMusicServiceChanged),
    ];

    int displayIndex = _index;
    if (displayIndex >= tabs.length) displayIndex = 0;

    Widget buildIndexedContent() {
      return IndexedStack(
        index: displayIndex,
        children: List<Widget>.generate(
          tabs.length,
          (i) => RepaintBoundary(
            child: TickerMode(enabled: i == displayIndex, child: tabs[i]),
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: buildIndexedContent()),
          if (keyboardHeight == 0)
            Positioned(
              left: 16,
              right: 16,
              bottom: miniPlayerBottom,
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
          _buildQuickTabSwitcher(
            context: context,
            displayIndex: displayIndex,
            isLocalMode: isLocalMode,
            top: quickSwitcherTop,
            bottom: quickSwitcherBottom,
          ),
        ],
      ),
    );
  }
}

class _DisabledLibraryPlaceholder extends StatelessWidget {
  const _DisabledLibraryPlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 56,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 12),
            Text(
              'Library is disabled in Local-only mode',
              style: TextStyle(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
