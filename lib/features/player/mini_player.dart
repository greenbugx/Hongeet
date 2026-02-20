import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hongit/core/theme/app_theme.dart';
import 'package:marquee/marquee.dart';
import 'package:provider/provider.dart';
import '../../core/utils/audio_player_service.dart';
import '../../core/utils/glass_container.dart';
import '../../core/utils/youtube_thumbnail_utils.dart';
import '../../core/widgets/fallback_network_image.dart';
import 'full_player_sheet.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = AudioPlayerService();
    final themeProvider = Provider.of<ThemeProvider>(context);
    final perfMode = themeProvider.resolvedUiPerformanceMode(context);
    final animateMiniPlayer = perfMode == UiPerformanceMode.full;

    return StreamBuilder<NowPlaying?>(
      stream: player.nowPlayingStream,
      builder: (context, snapshot) {
        final now = snapshot.data;

        return AnimatedSwitcher(
          duration: Duration(milliseconds: animateMiniPlayer ? 300 : 0),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(animation),
              child: FadeTransition(opacity: animation, child: child),
            );
          },
          child: now == null
              ? const SizedBox.shrink(key: ValueKey('empty'))
              : _MiniPlayerContent(
                  key: ValueKey('player-${now.title}'),
                  now: now,
                  player: player,
                  themeProvider: themeProvider,
                  perfMode: perfMode,
                ),
        );
      },
    );
  }
}

class _MiniPlayerContent extends StatelessWidget {
  final NowPlaying now;
  final AudioPlayerService player;
  final ThemeProvider themeProvider;
  final UiPerformanceMode perfMode;

  const _MiniPlayerContent({
    super.key,
    required this.now,
    required this.player,
    required this.themeProvider,
    required this.perfMode,
  });

  @override
  Widget build(BuildContext context) {
    final animateMiniVisuals = perfMode == UiPerformanceMode.full;
    final imageScale = YoutubeThumbnailUtils.preferredArtworkScale(
      imageUrl: now.imageUrl,
      youtubeVideoScale: 1.9,
      normalScale: 1.0,
    );
    final imageCandidates = YoutubeThumbnailUtils.candidateUrls(
      imageUrl: now.imageUrl,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => const FullPlayerSheet(),
          );
        },
        child: GlassContainer(
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                TweenAnimationBuilder<double>(
                  duration: Duration(
                    milliseconds: animateMiniVisuals ? 300 : 0,
                  ),
                  tween: Tween(begin: 0.0, end: 1.0),
                  builder: (context, value, child) {
                    return Opacity(
                      opacity: value,
                      child: Transform.scale(
                        scale: 0.8 + (0.2 * value),
                        child: child,
                      ),
                    );
                  },
                  child: ClipRRect(
                    clipBehavior: Clip.antiAlias,
                    borderRadius: BorderRadius.circular(10),
                    child: Transform.scale(
                      scale: imageScale,
                      child: FallbackNetworkImage(
                        urls: imageCandidates,
                        width: 48,
                        height: 48,
                        cacheWidth: 256,
                        cacheHeight: 256,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        filterQuality: FilterQuality.medium,
                        fallback: const Icon(Icons.music_note),
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 12),

                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _AutoMarqueeText(
                        text: now.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                        enableMarquee: animateMiniVisuals,
                      ),
                      const SizedBox(height: 2),
                      _AutoMarqueeText(
                        text: now.artist,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                        enableMarquee: animateMiniVisuals,
                      ),
                      const SizedBox(height: 6),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        themeProvider.useGlassTheme
                            ? CupertinoIcons.backward_end_fill
                            : Icons.skip_previous,
                      ),
                      onPressed: player.skipPrevious,
                    ),
                    StreamBuilder<bool>(
                      stream: player.trackLoadingStream,
                      initialData: player.isTrackLoading,
                      builder: (_, loadingSnap) {
                        final isLoading = loadingSnap.data ?? false;
                        return StreamBuilder(
                          stream: player.playerStateStream,
                          builder: (_, snap) {
                            final playing = snap.data?.playing ?? false;
                            return AnimatedSwitcher(
                              duration: Duration(
                                milliseconds: animateMiniVisuals ? 200 : 0,
                              ),
                              child: isLoading
                                  ? SizedBox(
                                      key: const ValueKey('loading'),
                                      width: 42,
                                      height: 42,
                                      child: Center(
                                        child: SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.4,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                  Colors.white,
                                                ),
                                          ),
                                        ),
                                      ),
                                    )
                                  : IconButton(
                                      key: ValueKey(playing),
                                      iconSize: 34,
                                      icon: Icon(
                                        playing
                                            ? themeProvider.useGlassTheme
                                                  ? CupertinoIcons
                                                        .pause_circle_fill
                                                  : Icons.pause_circle_filled
                                            : themeProvider.useGlassTheme
                                            ? CupertinoIcons.play_circle_fill
                                            : Icons.play_circle_filled,
                                      ),
                                      onPressed: player.togglePlayPause,
                                    ),
                            );
                          },
                        );
                      },
                    ),
                    IconButton(
                      icon: Icon(
                        themeProvider.useGlassTheme
                            ? CupertinoIcons.forward_end_fill
                            : Icons.skip_next,
                      ),
                      onPressed: player.skipNext,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Auto marquee only if text overflows
class _AutoMarqueeText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final bool enableMarquee;

  const _AutoMarqueeText({
    required this.text,
    required this.style,
    required this.enableMarquee,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();

        final isOverflowing = painter.width > constraints.maxWidth;

        if (!isOverflowing || !enableMarquee) {
          return Text(
            text,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

        return SizedBox(
          height: (style.fontSize ?? 14) + 6,
          child: Marquee(
            text: text,
            blankSpace: 32,
            velocity: 28,
            pauseAfterRound: const Duration(seconds: 1),
            style: style,
          ),
        );
      },
    );
  }
}
