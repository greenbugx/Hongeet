import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/utils/app_messenger.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/responsive.dart';
import '../../core/utils/app_distribution.dart';
import '../../core/utils/app_update_service.dart';
import '../../core/utils/audio_player_service.dart';
import '../../core/utils/streaming_preferences.dart';
import '../../core/utils/youtube_thumbnail_utils.dart';
import '../../core/widgets/fallback_network_image.dart';
import '../../data/api/local_backend_api.dart';
import '../../data/api/lyrics_service.dart';
import '../../data/api/lrclib_api.dart';
import '../../data/api/youtube_song_api.dart';
import '../library/playlist_manager.dart';
import '../library/library_screen.dart';
import '../player/widgets/player_progress_bar.dart';
import '../search/artist_profile_screen.dart';
import '../search/search_screen.dart';
import '../settings/settings_screen.dart';
import '../player/mini_player.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _lastSeenUpdateKey = 'last_seen_update_version';

  final GlobalKey<NavigatorState> _desktopNavigatorKey =
      GlobalKey<NavigatorState>();

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

    try {
      final result = await AppUpdateService().checkForUpdates();
      if (!mounted || !result.hasUpdate) return;

      final prefs = await SharedPreferences.getInstance();
      final lastSeen = prefs.getString(_lastSeenUpdateKey) ?? '';
      if (lastSeen == result.latestLabel) return;

      await prefs.setString(_lastSeenUpdateKey, result.latestLabel);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showUpdateDialog(context, result);
      });
    } catch (_) {}
  }

  void _onMusicServiceChanged(bool _) {
    _loadStreamingPrefs();
    setState(() {
      _searchScreenVersion++;
    });
  }

  void _onDestinationSelected(int nextIndex, {required bool isLocalMode}) {
    if (nextIndex == 1 && isLocalMode) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enable Saavn or YouTube in Settings to use Library'),
        ),
      );
      return;
    }

    final useDesktopShell = _isDesktopShellActive(context);
    if (nextIndex == _index) return;

    setState(() => _index = nextIndex);

    if (useDesktopShell) {
      _desktopNavigatorKey.currentState?.pushNamedAndRemoveUntil(
        _desktopRootRouteName(nextIndex),
        (route) => false,
      );
    }
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

  bool get _isDesktopShellTarget {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  bool _isDesktopShellActive(BuildContext context) {
    return _isDesktopShellTarget && ResponsiveLayout.isExpanded(context);
  }

  String _desktopRootRouteName(int index) {
    switch (index) {
      case 0:
        return '/desktop/search';
      case 1:
        return '/desktop/library';
      default:
        return '/desktop/settings';
    }
  }

  int _desktopIndexFromRouteName(String? routeName) {
    switch (routeName) {
      case '/desktop/library':
        return 1;
      case '/desktop/settings':
        return 2;
      case '/desktop/search':
      default:
        return 0;
    }
  }

  Widget _buildTabForIndex(int index, {required bool isLocalMode}) {
    switch (index) {
      case 0:
        return SearchScreen(key: ValueKey('search_$_searchScreenVersion'));
      case 1:
        return isLocalMode
            ? const _DisabledLibraryPlaceholder()
            : const LibraryScreen();
      default:
        return SettingsScreen(onMusicServiceChanged: _onMusicServiceChanged);
    }
  }

  Widget _buildDesktopCenterNavigator({required bool isLocalMode}) {
    return Navigator(
      key: _desktopNavigatorKey,
      initialRoute: _desktopRootRouteName(_index),
      onGenerateRoute: (settings) {
        final tabIndex = _desktopIndexFromRouteName(settings.name);
        return PageRouteBuilder<void>(
          settings: RouteSettings(name: _desktopRootRouteName(tabIndex)),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => RepaintBoundary(
            child: _buildTabForIndex(tabIndex, isLocalMode: isLocalMode),
          ),
        );
      },
    );
  }

  String _desktopLabelForIndex(int index) {
    switch (index) {
      case 0:
        return 'Home';
      case 1:
        return 'Library';
      default:
        return 'Settings';
    }
  }

  Widget _buildDesktopNavTile({
    required BuildContext context,
    required int index,
    required bool selected,
    required bool disabled,
    required bool isLocalMode,
    required String label,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final icon = _iconForIndex(index, selected: selected);
    return Tooltip(
      message: disabled ? '$label (disabled in local mode)' : label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: disabled
              ? null
              : () => _onDestinationSelected(index, isLocalMode: isLocalMode),
          child: AnimatedContainer(
            duration: Duration.zero,
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.secondaryContainer.withValues(alpha: 0.94)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? scheme.secondary.withValues(alpha: 0.28)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: disabled
                      ? scheme.onSurface.withValues(alpha: 0.35)
                      : selected
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: disabled
                          ? scheme.onSurface.withValues(alpha: 0.4)
                          : selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurface,
                    ),
                  ),
                ),
                if (disabled)
                  Icon(
                    Icons.lock_outline,
                    size: 16,
                    color: scheme.onSurface.withValues(alpha: 0.35),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopShell({
    required BuildContext context,
    required Widget indexedContent,
    required int displayIndex,
    required bool isLocalMode,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        minimum: const EdgeInsets.all(14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.surfaceContainer.withValues(alpha: 0.96),
                scheme.surface.withValues(alpha: 0.96),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.26),
                blurRadius: 28,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: Row(
              children: [
                Container(
                  width: 220,
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.72),
                    border: Border(
                      right: BorderSide(
                        color: scheme.outlineVariant.withValues(alpha: 0.42),
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 120,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: GestureDetector(
                            onTap: () => launchUrl(
                              Uri.parse('https://greenbugx.github.io/Hongeet'),
                              mode: LaunchMode.externalApplication,
                            ),
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: scheme.primary.withValues(
                                        alpha: 0.35,
                                      ),
                                      blurRadius: 200,
                                      spreadRadius: 100,
                                    ),
                                  ],
                                ),
                                child: Image.asset(
                                  'assets/app/icon_fg.webp',
                                  width: 210,
                                  height: 120,
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stackTrace) =>
                                      Image.asset(
                                        'assets/icon/icon_fg.png',
                                        width: 210,
                                        height: 120,
                                        fit: BoxFit.contain,
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      _buildDesktopNavTile(
                        context: context,
                        index: 0,
                        label: _desktopLabelForIndex(0),
                        selected: displayIndex == 0,
                        disabled: false,
                        isLocalMode: isLocalMode,
                      ),
                      const SizedBox(height: 8),
                      _buildDesktopNavTile(
                        context: context,
                        index: 1,
                        label: _desktopLabelForIndex(1),
                        selected: displayIndex == 1,
                        disabled: isLocalMode,
                        isLocalMode: isLocalMode,
                      ),
                      const Spacer(),
                      _buildDesktopNavTile(
                        context: context,
                        index: 2,
                        label: _desktopLabelForIndex(2),
                        selected: displayIndex == 2,
                        disabled: false,
                        isLocalMode: isLocalMode,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.32),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: indexedContent,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
                  child: SizedBox(
                    width: 340,
                    child: _DesktopNowPlayingPanel(
                      centerNavigatorKey: _desktopNavigatorKey,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
              duration: Duration.zero,
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
    const tabCount = 3;
    int displayIndex = _index;
    if (displayIndex >= tabCount) displayIndex = 0;

    Widget buildIndexedContent() {
      return IndexedStack(
        index: displayIndex,
        children: List<Widget>.generate(
          tabCount,
          (i) => RepaintBoundary(
            child: TickerMode(
              enabled: i == displayIndex,
              child: _buildTabForIndex(i, isLocalMode: isLocalMode),
            ),
          ),
        ),
      );
    }

    final useDesktopShell = _isDesktopShellActive(context);
    if (useDesktopShell) {
      return _buildDesktopShell(
        context: context,
        indexedContent: _buildDesktopCenterNavigator(isLocalMode: isLocalMode),
        displayIndex: displayIndex,
        isLocalMode: isLocalMode,
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

class _DesktopNowPlayingPanel extends StatefulWidget {
  final GlobalKey<NavigatorState> centerNavigatorKey;

  const _DesktopNowPlayingPanel({required this.centerNavigatorKey});

  @override
  State<_DesktopNowPlayingPanel> createState() =>
      _DesktopNowPlayingPanelState();
}

class _DesktopNowPlayingPanelState extends State<_DesktopNowPlayingPanel> {
  bool _showLyrics = false;

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString();
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _sleepTimerLabel(SleepTimerStatus status) {
    if (status.endOfCurrentSong) return 'After current song';
    final endsAt = status.endsAt;
    if (endsAt == null) return 'Off';
    final remaining = endsAt.difference(DateTime.now());
    if (remaining <= Duration.zero) return 'Off';
    final mins = remaining.inMinutes;
    final secs = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    return mins > 0 ? '${mins}m ${secs}s' : '${remaining.inSeconds}s';
  }

  bool _isBlockedArtistName(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    return normalized == 'unknown' ||
        normalized == 'offline' ||
        normalized == 'local audio' ||
        normalized == 'artist' ||
        normalized == 'various artists';
  }

  List<String> _extractArtistNames(String rawArtist) {
    var text = rawArtist.trim();
    if (text.isEmpty) return const <String>[];

    text = text.replaceAll(RegExp(r'\s+'), ' ');
    text = text.replaceAll(
      RegExp(r'\b(featuring|feat|ft)\.?\b', caseSensitive: false),
      ',',
    );
    text = text.replaceAll('&', ',');
    text = text.replaceAll(
      RegExp(r'\b(and|with)\b', caseSensitive: false),
      ',',
    );
    text = text.replaceAll(RegExp(r'\s+[xX]\s+'), ',');

    final parts = text
        .split(RegExp(r'[,/;|]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .map((e) => e.replaceAll(RegExp(r'^\(|\)$'), '').trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    final out = <String>[];
    final seen = <String>{};
    for (final part in parts) {
      if (_isBlockedArtistName(part)) continue;
      final key = part.toLowerCase();
      if (!seen.add(key)) continue;
      out.add(part);
    }
    return out;
  }

  void _pushArtistProfile(BuildContext context, String artist) {
    final centerNavigator = widget.centerNavigatorKey.currentState;
    final route = MaterialPageRoute<void>(
      builder: (_) => ArtistProfileScreen(artistName: artist),
    );
    if (centerNavigator != null) {
      centerNavigator.push(route);
      return;
    }
    Navigator.of(context).push(route);
  }

  void _openArtistProfile(BuildContext context, String rawArtist) {
    final artists = _extractArtistNames(rawArtist);
    if (artists.isEmpty) {
      AppMessenger.show('Artist profile not available');
      return;
    }

    if (artists.length == 1) {
      _pushArtistProfile(context, artists.first);
      return;
    }

    final uiTheme = Theme.of(context);
    final scheme = uiTheme.colorScheme;
    final textTheme = uiTheme.textTheme;
    final stableContext = context;

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(
              12,
              8,
              12,
              8 + MediaQuery.of(sheetCtx).viewPadding.bottom,
            ),
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  'Choose Artist',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              ...artists.map(
                (artist) => ListTile(
                  title: Text(artist),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!stableContext.mounted) return;
                      _pushArtistProfile(stableContext, artist);
                    });
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _ensureLyricsVisibility(bool canShowLyrics) {
    if (canShowLyrics || !_showLyrics) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _showLyrics = false);
    });
  }

  Future<void> _downloadSong(QueuedSong song) async {
    await StreamingPreferences.reload();
    if (!StreamingPreferences.isStreamingEnabled) {
      AppMessenger.show('Enable a streaming service in Settings to download.');
      return;
    }

    try {
      AppMessenger.show('Downloading: ${song.meta.title}');
      if (song.id.startsWith('yt:')) {
        final videoId = song.id.substring(3);
        final extracted = await YoutubeSongApi.fetchBestStream(videoId);
        await LocalBackendApi.downloadDirect(
          title: song.meta.title,
          url: extracted.url,
          headers: extracted.headers,
        );
      } else {
        await LocalBackendApi.downloadSaavn(
          title: song.meta.title,
          songId: song.id,
        );
      }
      AppMessenger.show('Download complete');
    } catch (_) {
      AppMessenger.show('Download failed');
    }
  }

  void _showSleepTimerSheet(BuildContext context, AudioPlayerService player) {
    final uiTheme = Theme.of(context);
    final scheme = uiTheme.colorScheme;
    final textTheme = uiTheme.textTheme;

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Sleep Timer',
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              StreamBuilder<SleepTimerStatus>(
                stream: player.sleepTimerStream,
                initialData: player.sleepTimerStatus,
                builder: (_, snap) => Text(
                  'Current: ${_sleepTimerLabel(snap.data ?? const SleepTimerStatus.off())}',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final mins in const [15, 30, 60])
                    ActionChip(
                      avatar: const Icon(Icons.timer_outlined, size: 16),
                      label: Text('${mins}m'),
                      onPressed: () {
                        Navigator.of(sheetCtx).pop();
                        player.setSleepTimer(Duration(minutes: mins));
                      },
                    ),
                ],
              ),
              const SizedBox(height: 10),
              ListTile(
                leading: const Icon(Icons.music_note_outlined),
                title: const Text('End of current song'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  player.setSleepTimerEndOfCurrentSong();
                },
              ),
              ListTile(
                leading: const Icon(Icons.timer_off_outlined),
                title: const Text('Turn off timer'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  player.clearSleepTimer();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _showAddToPlaylistSheet(BuildContext context, QueuedSong song) {
    final stableContext = context;
    final uiTheme = Theme.of(context);
    final scheme = uiTheme.colorScheme;
    final textTheme = uiTheme.textTheme;
    final addedInSheet = <String>{};

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return StreamBuilder<Map<String, List<Map<String, dynamic>>>>(
              stream: PlaylistManager.stream,
              builder: (_, snap) {
                final playlists = snap.data ?? {};
                final playlistNames = playlists.keys
                    .where((name) => name != PlaylistManager.systemFavourites)
                    .toList(growable: false);
                final mediaQuery = MediaQuery.of(sheetContext);

                return ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: mediaQuery.size.height * 0.75,
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      16,
                      16,
                      12 + mediaQuery.viewPadding.bottom,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        Text(
                          'Add to Playlist',
                          style: textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: playlistNames.isEmpty
                              ? Center(
                                  child: Text(
                                    'No playlists yet',
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                )
                              : ListView(
                                  children: playlistNames
                                      .map((name) {
                                        final playlistSongs =
                                            playlists[name] ?? const [];
                                        final exists = playlistSongs.any(
                                          (entry) =>
                                              (entry['id'] ?? '')
                                                  .toString()
                                                  .trim() ==
                                              song.id,
                                        );
                                        final added =
                                            exists ||
                                            addedInSheet.contains(name);

                                        return ListTile(
                                          leading: Icon(
                                            added
                                                ? Icons.check_circle
                                                : Icons.playlist_add_rounded,
                                            color: added
                                                ? scheme.primary
                                                : null,
                                          ),
                                          title: Text(name),
                                          onTap: () async {
                                            if (added) {
                                              AppMessenger.show(
                                                'Already in "$name"',
                                              );
                                              return;
                                            }

                                            final success =
                                                await PlaylistManager.addSong(
                                                  name,
                                                  {
                                                    'id': song.id,
                                                    'title': song.meta.title,
                                                    'artist': song.meta.artist,
                                                    'imageUrl':
                                                        song.meta.imageUrl,
                                                  },
                                                );
                                            if (!context.mounted) return;

                                            if (success) {
                                              setModalState(
                                                () => addedInSheet.add(name),
                                              );
                                              AppMessenger.show(
                                                'Added to "$name"',
                                              );
                                            } else {
                                              AppMessenger.show(
                                                'Already in "$name"',
                                              );
                                            }
                                          },
                                        );
                                      })
                                      .toList(growable: false),
                                ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!stableContext.mounted) return;
                              _showCreatePlaylistDialog(stableContext);
                            });
                          },
                          child: const Text('+ Create new playlist'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    String playlistName = '';

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('New Playlist'),
        content: TextField(
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
          onChanged: (value) => playlistName = value,
        ),
        actions: [
          TextButton(
            onPressed: () {
              FocusScope.of(dialogContext).unfocus();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final name = playlistName.trim();
              if (name.isEmpty) return;

              FocusScope.of(dialogContext).unfocus();
              await PlaylistManager.create(name);
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              AppMessenger.show('Playlist "$name" created');
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final themeProvider = Provider.of<ThemeProvider>(context);
    final player = AudioPlayerService();

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: scheme.surface.withValues(alpha: 0.72),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.34),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Now Playing',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: StreamBuilder<NowPlaying?>(
                stream: player.nowPlayingStream,
                builder: (context, snapshot) {
                  final now = snapshot.data;
                  if (now == null) {
                    _ensureLyricsVisibility(false);
                    return Center(
                      child: Text(
                        'Play a song to see controls and queue.',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }

                  final imageCandidates = YoutubeThumbnailUtils.candidateUrls(
                    imageUrl: now.imageUrl,
                  );
                  final queue = player.queue;
                  final current = player.currentIndex ?? -1;
                  final currentSong = current >= 0 && current < queue.length
                      ? queue[current]
                      : null;
                  final canShowLyrics =
                      currentSong != null && !currentSong.isLocal;
                  _ensureLyricsVisibility(canShowLyrics);

                  return Stack(
                    children: [
                      Positioned.fill(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeOutCubic,
                          transitionBuilder: (child, animation) {
                            return FadeTransition(
                              opacity: animation,
                              child: child,
                            );
                          },
                          child: _showLyrics
                              ? _DesktopLyricsPane(
                                  key: ValueKey(
                                    'lyrics-${currentSong?.id ?? now.title}',
                                  ),
                                  song: currentSong,
                                  player: player,
                                )
                              : LayoutBuilder(
                                  key: ValueKey(
                                    'player-${currentSong?.id ?? now.title}',
                                  ),
                                  builder: (context, constraints) {
                                    double artworkSize =
                                        constraints.maxHeight >= 760
                                        ? 226.0
                                        : constraints.maxHeight >= 640
                                        ? 202.0
                                        : 176.0;
                                    final maxSquareFromWidth =
                                        constraints.maxWidth - 8;
                                    if (artworkSize > maxSquareFromWidth) {
                                      artworkSize = maxSquareFromWidth;
                                    }
                                    if (artworkSize < 148) {
                                      artworkSize = 148;
                                    }

                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Align(
                                          alignment: Alignment.center,
                                          child: SizedBox(
                                            width: artworkSize,
                                            height: artworkSize,
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              child: FallbackNetworkImage(
                                                urls: imageCandidates,
                                                fit: BoxFit.cover,
                                                cacheWidth: 640,
                                                cacheHeight: 640,
                                                fallback: Container(
                                                  color: scheme
                                                      .surfaceContainerHighest,
                                                  child: const Icon(
                                                    Icons.music_note,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          now.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                          style: textTheme.titleLarge?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        Center(
                                          child: Material(
                                            color: Colors.transparent,
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              onTap: () => _openArtistProfile(
                                                context,
                                                now.artist,
                                              ),
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                child: Text(
                                                  now.artist,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  textAlign: TextAlign.center,
                                                  style: textTheme.bodyLarge
                                                      ?.copyWith(
                                                        color: scheme
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        StreamBuilder<Duration>(
                                          stream: player.positionStream,
                                          initialData: player.position,
                                          builder: (context, positionSnapshot) {
                                            return StreamBuilder<Duration?>(
                                              stream: player.durationStream,
                                              initialData: player.duration,
                                              builder: (context, durationSnapshot) {
                                                final total =
                                                    durationSnapshot.data ??
                                                    Duration.zero;
                                                final position =
                                                    positionSnapshot.data ??
                                                    Duration.zero;
                                                final clamped =
                                                    total <= Duration.zero
                                                    ? Duration.zero
                                                    : (position > total
                                                          ? total
                                                          : position);
                                                return Column(
                                                  children: [
                                                    PlayerProgressBar(
                                                      value: clamped
                                                          .inMilliseconds
                                                          .toDouble(),
                                                      max:
                                                          total <= Duration.zero
                                                          ? 1
                                                          : total.inMilliseconds
                                                                .toDouble(),
                                                      style: themeProvider
                                                          .effectiveProgressBarStyle,
                                                      onChanged: (millis) {
                                                        if (total <=
                                                            Duration.zero) {
                                                          return;
                                                        }
                                                        player.seek(
                                                          Duration(
                                                            milliseconds: millis
                                                                .round(),
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                    Row(
                                                      children: [
                                                        Text(
                                                          _formatDuration(
                                                            clamped,
                                                          ),
                                                          style: textTheme
                                                              .bodySmall
                                                              ?.copyWith(
                                                                color: scheme
                                                                    .onSurfaceVariant,
                                                              ),
                                                        ),
                                                        const Spacer(),
                                                        Text(
                                                          _formatDuration(
                                                            total,
                                                          ),
                                                          style: textTheme
                                                              .bodySmall
                                                              ?.copyWith(
                                                                color: scheme
                                                                    .onSurfaceVariant,
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                );
                                              },
                                            );
                                          },
                                        ),
                                        StreamBuilder<int?>(
                                          stream: player.currentIndexStream,
                                          initialData: player.currentIndex,
                                          builder: (_, currentSnapshot) {
                                            return StreamBuilder<int>(
                                              stream: player.queueChangeStream,
                                              initialData: 0,
                                              builder: (context, _) {
                                                final queue = player.queue;
                                                final current =
                                                    currentSnapshot.data ?? -1;
                                                final currentSong =
                                                    current >= 0 &&
                                                        current < queue.length
                                                    ? queue[current]
                                                    : null;
                                                final hasRemoteTrack =
                                                    currentSong != null &&
                                                    !currentSong.isLocal;

                                                return Column(
                                                  children: [
                                                    Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .center,
                                                      children: [
                                                        StreamBuilder<LoopMode>(
                                                          stream: player
                                                              .loopModeStream,
                                                          initialData:
                                                              player.loopMode,
                                                          builder: (_, loopSnapshot) {
                                                            final mode =
                                                                loopSnapshot
                                                                    .data ??
                                                                LoopMode.off;
                                                            return IconButton(
                                                              tooltip:
                                                                  mode ==
                                                                      LoopMode
                                                                          .off
                                                                  ? 'Repeat off'
                                                                  : mode ==
                                                                        LoopMode
                                                                            .one
                                                                  ? 'Repeat one'
                                                                  : 'Repeat all',
                                                              icon: Icon(
                                                                mode ==
                                                                        LoopMode
                                                                            .one
                                                                    ? Icons
                                                                          .repeat_one
                                                                    : Icons
                                                                          .repeat,
                                                                color:
                                                                    mode ==
                                                                        LoopMode
                                                                            .off
                                                                    ? scheme
                                                                          .onSurfaceVariant
                                                                    : scheme
                                                                          .onSurface,
                                                              ),
                                                              onPressed: player
                                                                  .toggleLoopMode,
                                                            );
                                                          },
                                                        ),
                                                        IconButton(
                                                          icon: const Icon(
                                                            Icons
                                                                .skip_previous_rounded,
                                                          ),
                                                          onPressed: player
                                                              .skipPrevious,
                                                        ),
                                                        StreamBuilder(
                                                          stream: player
                                                              .playerStateStream,
                                                          builder:
                                                              (
                                                                context,
                                                                stateSnapshot,
                                                              ) {
                                                                final isPlaying =
                                                                    stateSnapshot
                                                                        .data
                                                                        ?.playing ??
                                                                    false;
                                                                return IconButton(
                                                                  iconSize: 34,
                                                                  icon: Icon(
                                                                    isPlaying
                                                                        ? Icons
                                                                              .pause_circle_filled_rounded
                                                                        : Icons
                                                                              .play_circle_fill_rounded,
                                                                  ),
                                                                  onPressed: player
                                                                      .togglePlayPause,
                                                                );
                                                              },
                                                        ),
                                                        IconButton(
                                                          icon: const Icon(
                                                            Icons
                                                                .skip_next_rounded,
                                                          ),
                                                          onPressed:
                                                              player.skipNext,
                                                        ),
                                                        if (!hasRemoteTrack)
                                                          StreamBuilder<
                                                            SleepTimerStatus
                                                          >(
                                                            stream: player
                                                                .sleepTimerStream,
                                                            initialData: player
                                                                .sleepTimerStatus,
                                                            builder: (_, sleepSnapshot) {
                                                              final timerStatus =
                                                                  sleepSnapshot
                                                                      .data ??
                                                                  const SleepTimerStatus.off();
                                                              return IconButton(
                                                                tooltip:
                                                                    timerStatus
                                                                        .isActive
                                                                    ? 'Sleep timer: ${_sleepTimerLabel(timerStatus)}'
                                                                    : 'Sleep timer',
                                                                icon: Icon(
                                                                  Icons
                                                                      .bedtime_outlined,
                                                                  color:
                                                                      timerStatus
                                                                          .isActive
                                                                      ? scheme
                                                                            .primary
                                                                      : scheme
                                                                            .onSurfaceVariant,
                                                                ),
                                                                onPressed: () =>
                                                                    _showSleepTimerSheet(
                                                                      context,
                                                                      player,
                                                                    ),
                                                              );
                                                            },
                                                          ),
                                                        if (hasRemoteTrack)
                                                          IconButton(
                                                            tooltip: 'Download',
                                                            icon: const Icon(
                                                              Icons
                                                                  .download_rounded,
                                                            ),
                                                            onPressed: () =>
                                                                _downloadSong(
                                                                  currentSong,
                                                                ),
                                                          ),
                                                      ],
                                                    ),
                                                    if (currentSong != null &&
                                                        hasRemoteTrack)
                                                      Row(
                                                        mainAxisAlignment:
                                                            MainAxisAlignment
                                                                .center,
                                                        children: [
                                                          StreamBuilder<
                                                            Map<
                                                              String,
                                                              List<
                                                                Map<
                                                                  String,
                                                                  dynamic
                                                                >
                                                              >
                                                            >
                                                          >(
                                                            stream:
                                                                PlaylistManager
                                                                    .stream,
                                                            builder: (_, playlistSnapshot) {
                                                              final playlists =
                                                                  playlistSnapshot
                                                                      .data ??
                                                                  {};
                                                              final favs =
                                                                  playlists[PlaylistManager
                                                                      .systemFavourites] ??
                                                                  [];
                                                              final isFav = favs.any(
                                                                (entry) =>
                                                                    entry['id'] ==
                                                                    currentSong
                                                                        .id,
                                                              );
                                                              return IconButton(
                                                                tooltip: isFav
                                                                    ? 'Remove from favorites'
                                                                    : 'Add to favorites',
                                                                icon: Icon(
                                                                  isFav
                                                                      ? Icons
                                                                            .favorite
                                                                      : Icons
                                                                            .favorite_border,
                                                                  color: isFav
                                                                      ? scheme
                                                                            .error
                                                                      : scheme
                                                                            .onSurfaceVariant,
                                                                ),
                                                                onPressed: () async {
                                                                  await PlaylistManager.toggleFavourite({
                                                                    'id':
                                                                        currentSong
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
                                                                  });
                                                                },
                                                              );
                                                            },
                                                          ),
                                                          StreamBuilder<
                                                            SleepTimerStatus
                                                          >(
                                                            stream: player
                                                                .sleepTimerStream,
                                                            initialData: player
                                                                .sleepTimerStatus,
                                                            builder: (_, sleepSnapshot) {
                                                              final timerStatus =
                                                                  sleepSnapshot
                                                                      .data ??
                                                                  const SleepTimerStatus.off();
                                                              return IconButton(
                                                                tooltip:
                                                                    timerStatus
                                                                        .isActive
                                                                    ? 'Sleep timer: ${_sleepTimerLabel(timerStatus)}'
                                                                    : 'Sleep timer',
                                                                icon: Icon(
                                                                  Icons
                                                                      .bedtime_outlined,
                                                                  color:
                                                                      timerStatus
                                                                          .isActive
                                                                      ? scheme
                                                                            .primary
                                                                      : scheme
                                                                            .onSurfaceVariant,
                                                                ),
                                                                onPressed: () =>
                                                                    _showSleepTimerSheet(
                                                                      context,
                                                                      player,
                                                                    ),
                                                              );
                                                            },
                                                          ),
                                                          IconButton(
                                                            tooltip:
                                                                'Add to playlist',
                                                            icon: const Icon(
                                                              Icons
                                                                  .playlist_add_rounded,
                                                            ),
                                                            color: scheme
                                                                .onSurfaceVariant,
                                                            onPressed: () =>
                                                                _showAddToPlaylistSheet(
                                                                  context,
                                                                  currentSong,
                                                                ),
                                                          ),
                                                        ],
                                                      ),
                                                  ],
                                                );
                                              },
                                            );
                                          },
                                        ),
                                        const SizedBox(height: 6),
                                        Divider(
                                          height: 1,
                                          color: scheme.outlineVariant
                                              .withValues(alpha: 0.32),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          'Up Next',
                                          style: textTheme.titleSmall?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Expanded(
                                          child: StreamBuilder<int>(
                                            stream: player.queueChangeStream,
                                            initialData: 0,
                                            builder: (context, _) {
                                              return StreamBuilder<int?>(
                                                stream:
                                                    player.currentIndexStream,
                                                initialData:
                                                    player.currentIndex,
                                                builder: (context, currentSnapshot) {
                                                  final queue = player.queue;
                                                  final current =
                                                      currentSnapshot.data ??
                                                      -1;
                                                  final upcoming =
                                                      <
                                                        MapEntry<
                                                          int,
                                                          QueuedSong
                                                        >
                                                      >[];
                                                  for (
                                                    int i = current + 1;
                                                    i < queue.length &&
                                                        upcoming.length < 8;
                                                    i++
                                                  ) {
                                                    upcoming.add(
                                                      MapEntry(i, queue[i]),
                                                    );
                                                  }

                                                  if (upcoming.isEmpty) {
                                                    return Center(
                                                      child: Text(
                                                        'Queue is empty.',
                                                        style: textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                              color: scheme
                                                                  .onSurfaceVariant,
                                                            ),
                                                      ),
                                                    );
                                                  }

                                                  return StreamBuilder<
                                                    Map<
                                                      String,
                                                      List<Map<String, dynamic>>
                                                    >
                                                  >(
                                                    stream:
                                                        PlaylistManager.stream,
                                                    builder: (_, playlistSnapshot) {
                                                      final playlists =
                                                          playlistSnapshot
                                                              .data ??
                                                          {};
                                                      final favourites =
                                                          playlists[PlaylistManager
                                                              .systemFavourites] ??
                                                          const [];

                                                      return ListView.separated(
                                                        padding:
                                                            EdgeInsets.zero,
                                                        itemCount:
                                                            upcoming.length,
                                                        separatorBuilder:
                                                            (_, index) =>
                                                                const SizedBox(
                                                                  height: 6,
                                                                ),
                                                        itemBuilder: (_, idx) {
                                                          final entry =
                                                              upcoming[idx];
                                                          final song =
                                                              entry.value;
                                                          final isFav =
                                                              favourites.any(
                                                                (fav) =>
                                                                    (fav['id'] ??
                                                                            '')
                                                                        .toString()
                                                                        .trim() ==
                                                                    song.id,
                                                              );
                                                          final queueArtCandidates =
                                                              YoutubeThumbnailUtils.candidateUrls(
                                                                imageUrl: song
                                                                    .meta
                                                                    .imageUrl,
                                                              );
                                                          return ListTile(
                                                            dense: true,
                                                            minTileHeight: 54,
                                                            contentPadding:
                                                                const EdgeInsets.symmetric(
                                                                  horizontal: 8,
                                                                  vertical: 2,
                                                                ),
                                                            tileColor: scheme
                                                                .surfaceContainerHighest
                                                                .withValues(
                                                                  alpha: 0.45,
                                                                ),
                                                            shape: RoundedRectangleBorder(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    12,
                                                                  ),
                                                            ),
                                                            leading: ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    8,
                                                                  ),
                                                              child: SizedBox(
                                                                width: 42,
                                                                height: 42,
                                                                child: FallbackNetworkImage(
                                                                  urls:
                                                                      queueArtCandidates,
                                                                  fit: BoxFit
                                                                      .cover,
                                                                  cacheWidth:
                                                                      168,
                                                                  cacheHeight:
                                                                      168,
                                                                  fallback: Container(
                                                                    color: scheme
                                                                        .surfaceContainerHigh,
                                                                    child: const Icon(
                                                                      Icons
                                                                          .music_note,
                                                                      size: 16,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                            title: Text(
                                                              song.meta.title,
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            ),
                                                            subtitle: Text(
                                                              song.meta.artist,
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            ),
                                                            trailing: SizedBox(
                                                              width: 72,
                                                              child: Row(
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                children: [
                                                                  IconButton(
                                                                    tooltip:
                                                                        isFav
                                                                        ? 'Remove from favorites'
                                                                        : 'Add to favorites',
                                                                    visualDensity:
                                                                        VisualDensity
                                                                            .compact,
                                                                    padding:
                                                                        EdgeInsets
                                                                            .zero,
                                                                    constraints:
                                                                        const BoxConstraints.tightFor(
                                                                          width:
                                                                              30,
                                                                          height:
                                                                              30,
                                                                        ),
                                                                    icon: Icon(
                                                                      isFav
                                                                          ? Icons.favorite
                                                                          : Icons.favorite_border,
                                                                      size: 18,
                                                                      color:
                                                                          isFav
                                                                          ? scheme.error
                                                                          : scheme.onSurfaceVariant,
                                                                    ),
                                                                    onPressed: () async {
                                                                      await PlaylistManager.toggleFavourite({
                                                                        'id': song
                                                                            .id,
                                                                        'title': song
                                                                            .meta
                                                                            .title,
                                                                        'artist': song
                                                                            .meta
                                                                            .artist,
                                                                        'imageUrl': song
                                                                            .meta
                                                                            .imageUrl,
                                                                      });
                                                                    },
                                                                  ),
                                                                  IconButton(
                                                                    tooltip:
                                                                        'Add to playlist',
                                                                    visualDensity:
                                                                        VisualDensity
                                                                            .compact,
                                                                    padding:
                                                                        EdgeInsets
                                                                            .zero,
                                                                    constraints:
                                                                        const BoxConstraints.tightFor(
                                                                          width:
                                                                              30,
                                                                          height:
                                                                              30,
                                                                        ),
                                                                    icon: Icon(
                                                                      Icons
                                                                          .playlist_add_rounded,
                                                                      size: 18,
                                                                      color: scheme
                                                                          .onSurfaceVariant,
                                                                    ),
                                                                    onPressed: () =>
                                                                        _showAddToPlaylistSheet(
                                                                          context,
                                                                          song,
                                                                        ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                            onTap: () => player
                                                                .jumpToIndex(
                                                                  entry.key,
                                                                ),
                                                          );
                                                        },
                                                      );
                                                    },
                                                  );
                                                },
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                        ),
                      ),
                      if (!_showLyrics && canShowLyrics)
                        Positioned(
                          top: 2,
                          right: 2,
                          child: _DesktopPanelFloatingButton(
                            icon: Icons.lyrics_outlined,
                            tooltip: 'Show lyrics',
                            onTap: () {
                              setState(() => _showLyrics = true);
                            },
                          ),
                        ),
                      if (_showLyrics)
                        Positioned(
                          top: 2,
                          left: 2,
                          child: _DesktopPanelFloatingButton(
                            icon: Icons.arrow_back_rounded,
                            tooltip: 'Back to player',
                            onTap: () {
                              setState(() => _showLyrics = false);
                            },
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopPanelFloatingButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _DesktopPanelFloatingButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Ink(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.46),
              ),
            ),
            child: Icon(icon, size: 18, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}

class _DesktopLyricsPane extends StatefulWidget {
  final QueuedSong? song;
  final AudioPlayerService player;

  const _DesktopLyricsPane({
    super.key,
    required this.song,
    required this.player,
  });

  @override
  State<_DesktopLyricsPane> createState() => _DesktopLyricsPaneState();
}

class _DesktopLyricsPaneState extends State<_DesktopLyricsPane> {
  Future<LrcLibLyrics?>? _lyricsFuture;

  @override
  void initState() {
    super.initState();
    _fetchIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _DesktopLyricsPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song?.id != widget.song?.id) {
      _fetchIfNeeded();
    }
  }

  void _fetchIfNeeded() {
    final song = widget.song;
    if (song == null || song.isLocal) {
      _lyricsFuture = null;
      return;
    }
    _lyricsFuture = LyricsService.fetchBestLyrics(
      title: song.meta.title,
      artist: song.meta.artist,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final activeSong = widget.song;

    if (activeSong == null) {
      return Center(
        child: Text(
          'No song playing',
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }

    if (activeSong.isLocal) {
      return Center(
        child: Text(
          'Lyrics are currently available for streaming tracks only.',
          textAlign: TextAlign.center,
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }

    final lyricsFuture = _lyricsFuture;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        SizedBox(
          height: 26,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                'Lyrics',
                textAlign: TextAlign.center,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Positioned(
                right: 0,
                child: FutureBuilder<LrcLibLyrics?>(
                  future: lyricsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const SizedBox.shrink();
                    }
                    final lyrics = snapshot.data;
                    if (lyrics == null || lyrics.instrumental) {
                      return const SizedBox.shrink();
                    }
                    return _DesktopLyricsModeBadge(
                      isSynced: lyrics.hasSyncedLyrics,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: FutureBuilder<LrcLibLyrics?>(
            future: lyricsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    'Lyrics failed to load.',
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              final lyrics = snapshot.data;
              if (lyrics == null) {
                return Center(
                  child: Text(
                    'No lyrics found for this song.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              if (lyrics.instrumental) {
                return Center(
                  child: Text(
                    'Instrumental track.',
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              if (lyrics.hasWordSyncedLyrics) {
                return _DesktopWordSyncedLyricsView(
                  key: ValueKey(lyrics),
                  wordLines: lyrics.wordLines!,
                  player: widget.player,
                );
              }
              if (lyrics.hasSyncedLyrics) {
                return _DesktopSyncedLyricsView(
                  key: ValueKey(lyrics),
                  lines: lyrics.parsedLines,
                  player: widget.player,
                );
              }
              final plain = lyrics.plainLyrics.trim();
              if (plain.isEmpty) {
                return Center(
                  child: Text(
                    'No lyrics available.',
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              }
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(
                  plain,
                  textAlign: TextAlign.center,
                  style: textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                    height: 1.7,
                    color: scheme.onSurface,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DesktopSyncedLyricsView extends StatefulWidget {
  final List<LyricLine> lines;
  final AudioPlayerService player;

  const _DesktopSyncedLyricsView({
    super.key,
    required this.lines,
    required this.player,
  });

  @override
  State<_DesktopSyncedLyricsView> createState() =>
      _DesktopSyncedLyricsViewState();
}

class _DesktopSyncedLyricsViewState extends State<_DesktopSyncedLyricsView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late Animation<double> _indexAnim;
  StreamSubscription<Duration>? _positionSub;
  int _activeIndex = 0;
  static const double _lineHeight = 64.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    final initialIndex = _findActiveIndex(widget.player.player.position);
    _activeIndex = initialIndex;
    _indexAnim = _buildAnim(initialIndex.toDouble(), initialIndex.toDouble());
    _positionSub = widget.player.positionStream.listen(_onPositionChanged);
  }

  Animation<double> _buildAnim(double from, double to) {
    return Tween<double>(begin: from, end: to).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
  }

  @override
  void didUpdateWidget(covariant _DesktopSyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      _positionSub?.cancel();
      _positionSub = widget.player.positionStream.listen(_onPositionChanged);
    }
    if (!identical(oldWidget.lines, widget.lines)) {
      final idx = _findActiveIndex(widget.player.player.position);
      _activeIndex = idx;
      _indexAnim = _buildAnim(idx.toDouble(), idx.toDouble());
      _animController.reset();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _animController.dispose();
    super.dispose();
  }

  void _onPositionChanged(Duration position) {
    if (!mounted || widget.lines.isEmpty) return;
    final next = _findActiveIndex(position);
    if (next == _activeIndex) return;
    setState(() {
      final from = _indexAnim.value;
      _activeIndex = next;
      _indexAnim = _buildAnim(from, next.toDouble());
      _animController
        ..reset()
        ..forward();
    });
  }

  int _findActiveIndex(Duration position) {
    final lines = widget.lines;
    final targetMs = position.inMilliseconds;
    var low = 0;
    var high = lines.length - 1;
    var result = 0;

    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (lines[mid].start.inMilliseconds <= targetMs) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result.clamp(0, lines.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final centerY = constraints.maxHeight / 2 - _lineHeight / 2;
        return ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black,
              Colors.black,
              Colors.transparent,
            ],
            stops: [0.0, 0.20, 0.80, 1.0],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _indexAnim,
              builder: (context, child) {
                final translateY = centerY - _indexAnim.value * _lineHeight;
                return OverflowBox(
                  maxHeight: double.infinity,
                  alignment: Alignment.topCenter,
                  child: Transform.translate(
                    offset: Offset(0, translateY),
                    child: child,
                  ),
                );
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(widget.lines.length, (index) {
                  final isActive = index == _activeIndex;
                  final distance = (index - _activeIndex).abs();
                  final opacity = isActive
                      ? 1.0
                      : (distance <= 1 ? 0.48 : (distance <= 3 ? 0.28 : 0.14));

                  return SizedBox(
                    height: _lineHeight,
                    child: Center(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 280),
                        opacity: opacity,
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                          style: TextStyle(
                            fontSize: 17,
                            height: 1.3,
                            fontWeight: isActive
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: scheme.onSurface,
                          ),
                          child: Text(
                            widget.lines[index].text,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DesktopWordSyncedLyricsView extends StatefulWidget {
  final List<WordSyncedLine> wordLines;
  final AudioPlayerService player;

  const _DesktopWordSyncedLyricsView({
    super.key,
    required this.wordLines,
    required this.player,
  });

  @override
  State<_DesktopWordSyncedLyricsView> createState() =>
      _DesktopWordSyncedLyricsViewState();
}

class _DesktopWordSyncedLyricsViewState
    extends State<_DesktopWordSyncedLyricsView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late Animation<double> _lineIndexAnim;
  StreamSubscription<Duration>? _positionSub;
  int _activeLineIndex = 0;
  int _activeWordIndex = -1;
  static const double _lineHeight = 64.0; // desktop uses 64, mobile uses 72

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    final pos = widget.player.player.position;
    final initLine = _findActiveLineIndex(pos);
    _activeLineIndex = initLine;
    _activeWordIndex = _findActiveWordIndex(initLine, pos);
    _lineIndexAnim = _buildAnim(initLine.toDouble(), initLine.toDouble());
    _positionSub = widget.player.positionStream.listen(_onPositionChanged);
  }

  Animation<double> _buildAnim(double from, double to) {
    return Tween<double>(begin: from, end: to).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
  }

  @override
  void didUpdateWidget(covariant _DesktopWordSyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      _positionSub?.cancel();
      _positionSub = widget.player.positionStream.listen(_onPositionChanged);
    }
    if (!identical(oldWidget.wordLines, widget.wordLines)) {
      final pos = widget.player.player.position;
      final idx = _findActiveLineIndex(pos);
      _activeLineIndex = idx;
      _activeWordIndex = _findActiveWordIndex(idx, pos);
      _lineIndexAnim = _buildAnim(idx.toDouble(), idx.toDouble());
      _animController.reset();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _animController.dispose();
    super.dispose();
  }

  int _findActiveLineIndex(Duration position) {
    final lines = widget.wordLines;
    if (lines.isEmpty) return 0;
    final posMs = position.inMilliseconds;
    var low = 0, high = lines.length - 1, result = 0;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      if (lines[mid].start.inMilliseconds <= posMs) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result.clamp(0, lines.length - 1);
  }

  int _findActiveWordIndex(int lineIndex, Duration position) {
    if (lineIndex < 0 || lineIndex >= widget.wordLines.length) return -1;
    final words = widget.wordLines[lineIndex].words;
    if (words.isEmpty) return -1;
    final posMs = position.inMilliseconds;
    var result = -1;
    for (var i = 0; i < words.length; i++) {
      if (words[i].start.inMilliseconds <= posMs) {
        result = i;
      } else {
        break;
      }
    }
    return result;
  }

  void _onPositionChanged(Duration position) {
    if (!mounted || widget.wordLines.isEmpty) return;
    final newLine = _findActiveLineIndex(position);
    final newWord = _findActiveWordIndex(newLine, position);
    if (newLine == _activeLineIndex && newWord == _activeWordIndex) return;

    setState(() {
      if (newLine != _activeLineIndex) {
        final from = _lineIndexAnim.value;
        _activeLineIndex = newLine;
        _lineIndexAnim = _buildAnim(from, newLine.toDouble());
        _animController
          ..reset()
          ..forward();
      }
      _activeWordIndex = newWord;
    });
  }

  Widget _buildActiveLineText(WordSyncedLine line, ColorScheme scheme) {
    if (line.words.isEmpty) {
      return Text(
        line.fullText,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 17,
          height: 1.3,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      );
    }

    final spans = <InlineSpan>[];
    for (var i = 0; i < line.words.length; i++) {
      final Color color;
      if (_activeWordIndex < 0) {
        color = scheme.onSurface.withValues(alpha: 0.45);
      } else if (i < _activeWordIndex) {
        color = scheme.onSurface;
      } else if (i == _activeWordIndex) {
        color = scheme.primary;
      } else {
        color = scheme.onSurface.withValues(alpha: 0.45);
      }

      spans.add(
        TextSpan(
          text: line.words[i].text,
          style: TextStyle(
            fontSize: 17,
            height: 1.3,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      );
    }

    return Text.rich(TextSpan(children: spans), textAlign: TextAlign.center);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final centerY = constraints.maxHeight / 2 - _lineHeight / 2;
        return ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black,
              Colors.black,
              Colors.transparent,
            ],
            stops: [0.0, 0.20, 0.80, 1.0],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _lineIndexAnim,
              builder: (context, _) {
                final translateY = centerY - _lineIndexAnim.value * _lineHeight;
                return OverflowBox(
                  maxHeight: double.infinity,
                  alignment: Alignment.topCenter,
                  child: Transform.translate(
                    offset: Offset(0, translateY),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(widget.wordLines.length, (index) {
                        final isActive = index == _activeLineIndex;
                        final distance = (index - _activeLineIndex).abs();
                        final opacity = isActive
                            ? 1.0
                            : (distance <= 1
                                  ? 0.48
                                  : (distance <= 3 ? 0.28 : 0.14));
                        final line = widget.wordLines[index];

                        return SizedBox(
                          height: _lineHeight,
                          child: Center(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 280),
                              opacity: opacity,
                              child: isActive
                                  ? _buildActiveLineText(line, scheme)
                                  : Text(
                                      line.fullText,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 17,
                                        height: 1.3,
                                        fontWeight: FontWeight.w500,
                                        color: scheme.onSurface,
                                      ),
                                    ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _DesktopLyricsModeBadge extends StatelessWidget {
  final bool isSynced;

  const _DesktopLyricsModeBadge({required this.isSynced});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isSynced
            ? scheme.primary.withValues(alpha: 0.20)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.60),
        ),
      ),
      child: Text(
        isSynced ? 'Synced' : 'Unsynced',
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: isSynced ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
