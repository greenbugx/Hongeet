import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:marquee/marquee.dart';
import 'package:provider/provider.dart';

import '../../core/utils/audio_player_service.dart';
import '../../core/utils/youtube_thumbnail_utils.dart';
import '../../core/widgets/fallback_network_image.dart';
import '../../core/utils/themed_container.dart';
import '../../core/utils/themed_page.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/responsive.dart';
import '../../core/utils/app_messenger.dart';
import '../../features/library/playlist_manager.dart';
import '../player/mini_player.dart';

class PlaylistScreen extends StatefulWidget {
  final String name;

  const PlaylistScreen({super.key, required this.name});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  Widget _buildAnimatedSongEntry({
    required Widget child,
    required int index,
    required bool animate,
    Key? key,
  }) {
    if (!animate) {
      return KeyedSubtree(key: key, child: child);
    }

    return TweenAnimationBuilder<double>(
      key: key,
      duration: Duration(milliseconds: 300 + (index * 50)),
      tween: Tween(begin: 0.0, end: 1.0),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, 20 * (1 - value)),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: child,
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

  void _showSongOptions(
    BuildContext context,
    Map<String, dynamic> song,
    ThemeProvider theme,
  ) {
    final uiTheme = Theme.of(context);
    final scheme = uiTheme.colorScheme;
    final textTheme = uiTheme.textTheme;
    final perfMode = theme.resolvedUiPerformanceMode(context);
    final thumbFilterQuality = perfMode == UiPerformanceMode.full
        ? FilterQuality.medium
        : FilterQuality.low;

    final songId = (song['id'] ?? '').toString().trim();
    final imageUrl = (song['imageUrl'] ?? '').toString().trim();
    final imageCandidates = YoutubeThumbnailUtils.candidateUrls(
      songId: songId,
      imageUrl: imageUrl,
    );

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: FallbackNetworkImage(
                    urls: imageCandidates,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    filterQuality: thumbFilterQuality,
                    fallback: Container(
                      width: 56,
                      height: 56,
                      color: scheme.surfaceContainerHighest,
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
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        song['artist'],
                        style: textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
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
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),

          ListTile(
            leading: Icon(
              theme.useGlassTheme
                  ? CupertinoIcons.minus_circle
                  : Icons.remove_circle_outline,
              color: scheme.error,
            ),
            title: Text(
              widget.name == PlaylistManager.systemFavourites
                  ? 'Remove from Favorites'
                  : 'Remove from Playlist',
              style: TextStyle(color: scheme.error),
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

          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),

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
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = AudioPlayerService();
    final theme = Provider.of<ThemeProvider>(context);
    final uiTheme = Theme.of(context);
    final textTheme = uiTheme.textTheme;
    final scheme = uiTheme.colorScheme;
    final perfMode = theme.resolvedUiPerformanceMode(context);
    final animateEntries = perfMode == UiPerformanceMode.full;
    final thumbFilterQuality = perfMode == UiPerformanceMode.full
        ? FilterQuality.medium
        : FilterQuality.low;

    return ThemedPage(
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
                          style: textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
                              color: scheme.onSurfaceVariant.withValues(
                                alpha: 0.7,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No songs yet',
                              style: textTheme.bodyLarge?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  ...songs.asMap().entries.map((entry) {
                    final index = entry.key;
                    final song = entry.value;

                    return _buildAnimatedSongEntry(
                      key: ValueKey(song['id']),
                      index: index,
                      animate: animateEntries,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ThemedContainer(
                          child: ListTile(
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: FallbackNetworkImage(
                                urls: YoutubeThumbnailUtils.candidateUrls(
                                  songId: (song['id'] ?? '').toString().trim(),
                                  imageUrl: (song['imageUrl'] ?? '')
                                      .toString()
                                      .trim(),
                                ),
                                width: 48,
                                height: 48,
                                fit: BoxFit.cover,
                                filterQuality: thumbFilterQuality,
                                fallback: Container(
                                  width: 48,
                                  height: 48,
                                  color: scheme.surfaceContainerHighest,
                                  child: const Icon(Icons.music_note, size: 24),
                                ),
                              ),
                            ),
                            title: _buildSongTitle(song['title'].toString()),
                            subtitle: Text(
                              song['artist'].toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              icon: Icon(
                                theme.useGlassTheme
                                    ? CupertinoIcons.ellipsis_vertical
                                    : Icons.more_vert,
                              ),
                              onPressed: () =>
                                  _showSongOptions(context, song, theme),
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

              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
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
            ],
          );
        },
      ),
    );
  }
}
