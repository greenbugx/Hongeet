import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'dart:collection';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:marquee/marquee.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/utils/audio_player_service.dart';
import '../../core/utils/glass_container.dart';
import '../../core/utils/streaming_preferences.dart';
import '../../data/api/local_backend_api.dart';
import '../../data/api/lrclib_api.dart';
import '../../data/api/youtube_song_api.dart';
import '../../core/utils/app_messenger.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/youtube_thumbnail_utils.dart';
import '../../core/widgets/fallback_network_image.dart';
import 'widgets/player_progress_bar.dart';

import '../../features/library/downloaded_songs_provider.dart';
import '../../features/library/playlist_manager.dart';
import '../../features/library/local_audio_provider.dart';

class FullPlayerSheet extends StatelessWidget {
  const FullPlayerSheet({super.key});
  static const int _maxConcurrentDownloads = 3;
  static const int _queueFeedbackThreshold = 5;
  static int _activeDownloadCount = 0;
  static final Queue<_QueuedDownloadTask> _downloadQueue =
      Queue<_QueuedDownloadTask>();
  static final Set<String> _queuedOrActiveSongIds = <String>{};

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
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

  void _showSleepTimerSheet(
    BuildContext context,
    AudioPlayerService player,
    bool useGlassTheme,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withValues(alpha: 0.88),
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
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Sleep Timer',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              StreamBuilder<SleepTimerStatus>(
                stream: player.sleepTimerStream,
                initialData: player.sleepTimerStatus,
                builder: (_, snap) => Text(
                  'Current: ${_sleepTimerLabel(snap.data ?? const SleepTimerStatus.off())}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final mins in const [15, 30, 60])
                    ActionChip(
                      avatar: Icon(
                        useGlassTheme
                            ? CupertinoIcons.timer
                            : Icons.timer_outlined,
                        size: 16,
                      ),
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
                leading: Icon(
                  useGlassTheme
                      ? CupertinoIcons.music_note
                      : Icons.music_note_outlined,
                ),
                title: const Text('End of current song'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  player.setSleepTimerEndOfCurrentSong();
                },
              ),
              ListTile(
                leading: Icon(
                  useGlassTheme
                      ? CupertinoIcons.clear_circled
                      : Icons.timer_off_outlined,
                ),
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

  Future<void> _downloadSong(QueuedSong song) async {
    await StreamingPreferences.reload();
    if (!StreamingPreferences.isStreamingEnabled) {
      AppMessenger.show(
        'Enable a streaming service in Settings to download.',
        color: Colors.orange.shade700,
      );
      return;
    }

    if (_queuedOrActiveSongIds.contains(song.id)) {
      AppMessenger.show(
        'Already queued: ${song.meta.title}',
        color: Colors.orange.shade700,
      );
      return;
    }

    _queuedOrActiveSongIds.add(song.id);
    _downloadQueue.add(_QueuedDownloadTask(song: song));
    final pendingTotal = _activeDownloadCount + _downloadQueue.length;

    if (pendingTotal > _queueFeedbackThreshold) {
      AppMessenger.show(
        'Queued $pendingTotal downloads. Running $_maxConcurrentDownloads at a time.',
        color: Colors.blueGrey.shade800,
      );
    } else {
      AppMessenger.show(
        'Added to queue: ${song.meta.title}',
        color: Colors.blueGrey.shade800,
      );
    }

    _pumpDownloadQueue();
  }

  void _pumpDownloadQueue() {
    while (_activeDownloadCount < _maxConcurrentDownloads &&
        _downloadQueue.isNotEmpty) {
      final task = _downloadQueue.removeFirst();
      _activeDownloadCount++;
      _runDownloadTask(task);
    }
  }

  void _runDownloadTask(_QueuedDownloadTask task) {
    () async {
      final song = task.song;
      AppMessenger.show(
        'Downloading: ${song.meta.title}',
        color: Colors.blueGrey.shade800,
      );

      try {
        if (song.id.startsWith('yt:')) {
          final videoId = song.id.substring(3);
          final audioUrl = await YoutubeSongApi.fetchBestStreamUrl(videoId);
          await LocalBackendApi.downloadDirect(
            title: song.meta.title,
            url: audioUrl,
          );
        } else {
          await LocalBackendApi.downloadSaavn(
            title: song.meta.title,
            songId: song.id,
          );
        }

        AppMessenger.show('Download complete', color: Colors.green.shade700);
      } catch (_) {
        AppMessenger.show('Download failed', color: Colors.red.shade700);
      } finally {
        _queuedOrActiveSongIds.remove(song.id);
        if (_activeDownloadCount > 0) {
          _activeDownloadCount--;
        }
        _pumpDownloadQueue();
      }
    }();
  }

  bool _isDownloadedLocalTrack(QueuedSong? song) {
    if (song == null || !song.isLocal) return false;
    final normalizedPath = song.id.replaceAll('\\', '/').toLowerCase();
    return normalizedPath.startsWith('/storage/emulated/0/download/hongit/') ||
        normalizedPath.startsWith('/storage/emulated/0/downloads/hongit/');
  }

  bool _isLocalAudio(QueuedSong? song) {
    if (song == null || !song.isLocal) return false;
    return !_isDownloadedLocalTrack(song);
  }

  Future<void> _deleteDownloadedSong(
    BuildContext context,
    QueuedSong song,
    AudioPlayerService player,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Song'),
        content: Text('Delete "${song.meta.title}" from downloads?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final wasRemoved = await player.removeSongFromQueue(song.id);
    await DownloadedSongsProvider.delete(song.id);

    if (!wasRemoved) {
      final currentIndex = player.currentIndex;
      final queue = player.queue;
      if (currentIndex != null &&
          currentIndex >= 0 &&
          currentIndex < queue.length &&
          queue[currentIndex].id == song.id) {
        await player.stopAndClearNowPlaying();
      }
    }

    AppMessenger.show(
      'Deleted ${song.meta.title}',
      color: Colors.redAccent.shade700,
    );
    if (context.mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _deleteLocalAudio(
    BuildContext context,
    QueuedSong song,
    AudioPlayerService player,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Audio'),
        content: Text('Delete "${song.meta.title}" from device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      if (Platform.isAndroid) {
        final status = await Permission.manageExternalStorage.request();

        if (status.isDenied) {
          AppMessenger.show(
            'Permission denied. Cannot delete file.',
            color: Colors.red.shade700,
          );
          return;
        }

        if (status.isPermanentlyDenied) {
          AppMessenger.show(
            'Storage permission permanently denied. Open app settings to enable it.',
            color: Colors.red.shade700,
          );
          openAppSettings();
          return;
        }
      }

      final file = File(song.id);

      if (file.existsSync()) {
        try {
          final currentIndex = player.currentIndex;
          final queue = player.queue;
          final isCurrentSong =
              currentIndex != null &&
              currentIndex >= 0 &&
              currentIndex < queue.length &&
              queue[currentIndex].id == song.id;

          await player.removeSongFromQueue(song.id);

          if (isCurrentSong && player.queue.isEmpty) {
            await player.stopAndClearNowPlaying();
          }

          await Future.delayed(const Duration(milliseconds: 100));

          await file.delete();

          LocalAudioProvider.notifyChanged();

          AppMessenger.show(
            'Deleted ${song.meta.title}',
            color: Colors.redAccent.shade700,
          );
        } catch (e) {
          AppMessenger.show(
            'Failed to delete file',
            color: Colors.red.shade700,
          );
        }
      } else {
        AppMessenger.show('File not found', color: Colors.orange.shade700);
      }

      if (context.mounted) {
        Navigator.of(context).maybePop();
      }
    } catch (e) {
      AppMessenger.show('Error: ${e.toString()}', color: Colors.red.shade700);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = AudioPlayerService();
    final theme = Provider.of<ThemeProvider>(context);
    final perfMode = theme.resolvedUiPerformanceMode(context);
    final fullVisuals = perfMode == UiPerformanceMode.full;
    final smoothVisuals = perfMode == UiPerformanceMode.smooth;
    final backdropBlur = fullVisuals ? 30.0 : 16.0;
    final mainArtCacheSize = smoothVisuals ? 512 : 768;
    final queueArtCacheSize = smoothVisuals ? 192 : 256;

    return StreamBuilder<NowPlaying?>(
      stream: player.nowPlayingStream,
      builder: (_, snap) {
        final now = snap.data;
        if (now == null) return const SizedBox.shrink();

        return StreamBuilder<int?>(
          stream: player.currentIndexStream,
          builder: (_, indexSnap) {
            return StreamBuilder<int>(
              stream: player.queueChangeStream,
              initialData: 0,
              builder: (_, queueSnap) {
                final index = indexSnap.data ?? 0;
                final queue = player.queue;
                final currentSong = index >= 0 && index < queue.length
                    ? queue[index]
                    : null;
                final hasRemoteTrack =
                    currentSong != null && !currentSong.isLocal;
                final hasDownloadedLocalTrack = _isDownloadedLocalTrack(
                  currentSong,
                );
                final currentArtScale =
                    YoutubeThumbnailUtils.preferredArtworkScale(
                      songId: currentSong?.id,
                      imageUrl: now.imageUrl,
                      youtubeVideoScale: 1.0,
                      normalScale: 1.0,
                    );
                final currentArtCandidates =
                    YoutubeThumbnailUtils.candidateUrls(
                      songId: currentSong?.id,
                      imageUrl: now.imageUrl,
                    );

                final List<_UpcomingSong> upcomingWithIndices = [];
                for (
                  int i = index + 1;
                  i < queue.length && upcomingWithIndices.length < 10;
                  i++
                ) {
                  upcomingWithIndices.add(
                    _UpcomingSong(song: queue[i], absoluteIndex: i),
                  );
                }

                return Stack(
                  children: [
                    if (smoothVisuals)
                      Container(color: Colors.black.withValues(alpha: 0.72))
                    else
                      BackdropFilter(
                        filter: ImageFilter.blur(
                          sigmaX: backdropBlur,
                          sigmaY: backdropBlur,
                        ),
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.65),
                        ),
                      ),

                    DraggableScrollableSheet(
                      initialChildSize: 1,
                      maxChildSize: 1,
                      minChildSize: 0.3,
                      builder: (_, controller) {
                        return ListView(
                          controller: controller,
                          cacheExtent: 900,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          children: [
                            const SizedBox(height: 16),

                            RepaintBoundary(
                              child: _SwipeLyricsPlayerCard(
                                song: currentSong,
                                player: player,
                                useGlassTheme: theme.useGlassTheme,
                                frontCard: GlassContainer(
                                  borderRadius: BorderRadius.circular(32),
                                  child: Padding(
                                    padding: const EdgeInsets.all(20),
                                    child: Column(
                                      children: [
                                        Container(
                                          width: 36,
                                          height: 4,
                                          margin: const EdgeInsets.only(
                                            bottom: 16,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white30,
                                            borderRadius: BorderRadius.circular(
                                              2,
                                            ),
                                          ),
                                        ),

                                        AspectRatio(
                                          aspectRatio: 1,
                                          child: ClipRRect(
                                            clipBehavior: Clip.antiAlias,
                                            borderRadius: BorderRadius.circular(
                                              22,
                                            ),
                                            child: Transform.scale(
                                              scale: currentArtScale,
                                              child: FallbackNetworkImage(
                                                urls: currentArtCandidates,
                                                fit: BoxFit.cover,
                                                alignment: Alignment.center,
                                                cacheWidth: mainArtCacheSize,
                                                cacheHeight: mainArtCacheSize,
                                                filterQuality:
                                                    FilterQuality.medium,
                                                fallback: Container(
                                                  color: Colors.black26,
                                                  child: const Icon(
                                                    Icons.music_note_rounded,
                                                    size: 56,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),

                                        const SizedBox(height: 20),

                                        SizedBox(
                                          height: 26,
                                          child: _AutoMarqueeText(
                                            text: now.title,
                                            style: const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),

                                        const SizedBox(height: 6),

                                        SizedBox(
                                          height: 20,
                                          child: _AutoMarqueeText(
                                            text: now.artist,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              color: Colors.white70,
                                            ),
                                          ),
                                        ),

                                        const SizedBox(height: 20),

                                        StreamBuilder<bool>(
                                          stream: player.trackLoadingStream,
                                          initialData: player.isTrackLoading,
                                          builder: (_, loadingSnap) {
                                            final isTrackLoading =
                                                loadingSnap.data ?? false;
                                            return StreamBuilder<Duration>(
                                              stream: player.positionStream,
                                              builder: (_, posSnap) {
                                                final livePos =
                                                    posSnap.data ??
                                                    Duration.zero;
                                                return StreamBuilder<Duration?>(
                                                  stream: player.durationStream,
                                                  builder: (_, durSnap) {
                                                    final liveDur =
                                                        durSnap.data ??
                                                        Duration.zero;
                                                    final shownPos =
                                                        isTrackLoading
                                                        ? Duration.zero
                                                        : livePos;
                                                    final shownDur =
                                                        isTrackLoading
                                                        ? Duration.zero
                                                        : liveDur;
                                                    final max =
                                                        shownDur.inSeconds > 0
                                                        ? shownDur.inSeconds
                                                              .toDouble()
                                                        : 1.0;

                                                    return Column(
                                                      children: [
                                                        PlayerProgressBar(
                                                          value: shownPos
                                                              .inSeconds
                                                              .toDouble()
                                                              .clamp(0, max),
                                                          max: max,
                                                          style: theme
                                                              .effectiveProgressBarStyle,
                                                          useGlassTheme: theme
                                                              .useGlassTheme,
                                                          onChanged:
                                                              isTrackLoading
                                                              ? (_) {}
                                                              : (
                                                                  v,
                                                                ) => player.seek(
                                                                  Duration(
                                                                    seconds: v
                                                                        .toInt(),
                                                                  ),
                                                                ),
                                                        ),
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 6,
                                                              ),
                                                          child: Row(
                                                            mainAxisAlignment:
                                                                MainAxisAlignment
                                                                    .spaceBetween,
                                                            children: [
                                                              Text(
                                                                _fmt(shownPos),
                                                                style: const TextStyle(
                                                                  fontSize: 12,
                                                                  color: Colors
                                                                      .white70,
                                                                ),
                                                              ),
                                                              Text(
                                                                _fmt(shownDur),
                                                                style: const TextStyle(
                                                                  fontSize: 12,
                                                                  color: Colors
                                                                      .white70,
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ],
                                                    );
                                                  },
                                                );
                                              },
                                            );
                                          },
                                        ),

                                        const SizedBox(height: 12),

                                        Column(
                                          children: [
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                SizedBox(
                                                  width: 48,
                                                  child: StreamBuilder<LoopMode>(
                                                    stream:
                                                        player.loopModeStream,
                                                    builder: (_, snap) {
                                                      final mode =
                                                          snap.data ??
                                                          LoopMode.off;
                                                      return IconButton(
                                                        icon: Icon(
                                                          mode == LoopMode.one
                                                              ? (theme.useGlassTheme
                                                                    ? CupertinoIcons
                                                                          .repeat_1
                                                                    : Icons
                                                                          .repeat_one)
                                                              : (theme.useGlassTheme
                                                                    ? CupertinoIcons
                                                                          .repeat
                                                                    : Icons
                                                                          .repeat),
                                                          color:
                                                              mode ==
                                                                  LoopMode.off
                                                              ? Colors.white54
                                                              : Colors.white,
                                                        ),
                                                        onPressed: player
                                                            .toggleLoopMode,
                                                      );
                                                    },
                                                  ),
                                                ),
                                                SizedBox(
                                                  width: 52,
                                                  child: IconButton(
                                                    icon: Icon(
                                                      theme.useGlassTheme
                                                          ? CupertinoIcons
                                                                .backward_end_fill
                                                          : Icons.skip_previous,
                                                    ),
                                                    iconSize: 30,
                                                    onPressed:
                                                        player.skipPrevious,
                                                  ),
                                                ),
                                                SizedBox(
                                                  width: 72,
                                                  child: StreamBuilder<bool>(
                                                    stream: player
                                                        .trackLoadingStream,
                                                    initialData:
                                                        player.isTrackLoading,
                                                    builder: (_, loadingSnap) {
                                                      final isLoading =
                                                          loadingSnap.data ??
                                                          false;
                                                      return StreamBuilder(
                                                        stream: player
                                                            .playerStateStream,
                                                        builder: (_, snap) {
                                                          final playing =
                                                              snap
                                                                  .data
                                                                  ?.playing ??
                                                              false;
                                                          return AnimatedSwitcher(
                                                            duration:
                                                                const Duration(
                                                                  milliseconds:
                                                                      200,
                                                                ),
                                                            child: isLoading
                                                                ? SizedBox(
                                                                    key: const ValueKey(
                                                                      'loading',
                                                                    ),
                                                                    width: 56,
                                                                    height: 56,
                                                                    child: Center(
                                                                      child: SizedBox(
                                                                        width:
                                                                            28,
                                                                        height:
                                                                            28,
                                                                        child: CircularProgressIndicator(
                                                                          strokeWidth:
                                                                              2.8,
                                                                          valueColor:
                                                                              AlwaysStoppedAnimation<
                                                                                Color
                                                                              >(
                                                                                Colors.white,
                                                                              ),
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  )
                                                                : IconButton(
                                                                    key: ValueKey(
                                                                      playing,
                                                                    ),
                                                                    iconSize:
                                                                        56,
                                                                    icon: Icon(
                                                                      playing
                                                                          ? (theme.useGlassTheme
                                                                                ? CupertinoIcons.pause_circle_fill
                                                                                : Icons.pause_circle_filled)
                                                                          : (theme.useGlassTheme
                                                                                ? CupertinoIcons.play_circle_fill
                                                                                : Icons.play_circle_filled),
                                                                    ),
                                                                    onPressed:
                                                                        player
                                                                            .togglePlayPause,
                                                                  ),
                                                          );
                                                        },
                                                      );
                                                    },
                                                  ),
                                                ),
                                                SizedBox(
                                                  width: 52,
                                                  child: IconButton(
                                                    icon: Icon(
                                                      theme.useGlassTheme
                                                          ? CupertinoIcons
                                                                .forward_end_fill
                                                          : Icons.skip_next,
                                                    ),
                                                    iconSize: 30,
                                                    onPressed: player.skipNext,
                                                  ),
                                                ),
                                                if (hasRemoteTrack)
                                                  SizedBox(
                                                    width: 48,
                                                    child: IconButton(
                                                      icon: Icon(
                                                        theme.useGlassTheme
                                                            ? CupertinoIcons
                                                                  .arrow_down
                                                            : Icons.download,
                                                      ),
                                                      onPressed: () =>
                                                          _downloadSong(
                                                            currentSong,
                                                          ),
                                                    ),
                                                  ),
                                                if (!hasRemoteTrack &&
                                                    hasDownloadedLocalTrack)
                                                  SizedBox(
                                                    width: 48,
                                                    child: IconButton(
                                                      icon: Icon(
                                                        theme.useGlassTheme
                                                            ? CupertinoIcons
                                                                  .trash
                                                            : Icons
                                                                  .delete_outline,
                                                        color: Colors.redAccent,
                                                      ),
                                                      onPressed: () =>
                                                          _deleteDownloadedSong(
                                                            context,
                                                            currentSong!,
                                                            player,
                                                          ),
                                                    ),
                                                  ),
                                                if (_isLocalAudio(currentSong))
                                                  SizedBox(
                                                    width: 48,
                                                    child: IconButton(
                                                      icon: Icon(
                                                        theme.useGlassTheme
                                                            ? CupertinoIcons
                                                                  .trash
                                                            : Icons
                                                                  .delete_outline,
                                                        color: Colors.redAccent,
                                                      ),
                                                      onPressed: () =>
                                                          _deleteLocalAudio(
                                                            context,
                                                            currentSong!,
                                                            player,
                                                          ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            if (currentSong != null) ...[
                                              const SizedBox(height: 8),

                                              Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  if (hasRemoteTrack) ...[
                                                    StreamBuilder<
                                                      Map<
                                                        String,
                                                        List<
                                                          Map<String, dynamic>
                                                        >
                                                      >
                                                    >(
                                                      stream: PlaylistManager
                                                          .stream,
                                                      builder: (_, snap) {
                                                        final playlists =
                                                            snap.data ?? {};
                                                        final favs =
                                                            playlists[PlaylistManager
                                                                .systemFavourites] ??
                                                            [];
                                                        final isFav = favs.any(
                                                          (s) =>
                                                              s['id'] ==
                                                              currentSong.id,
                                                        );

                                                        return IconButton(
                                                          icon: Icon(
                                                            theme.useGlassTheme
                                                                ? (isFav
                                                                      ? CupertinoIcons
                                                                            .heart_fill
                                                                      : CupertinoIcons
                                                                            .heart)
                                                                : (isFav
                                                                      ? Icons
                                                                            .favorite
                                                                      : Icons
                                                                            .favorite_border),
                                                            color: isFav
                                                                ? Colors
                                                                      .redAccent
                                                                : Colors
                                                                      .white70,
                                                          ),
                                                          iconSize: 26,
                                                          onPressed: () async =>
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
                                                              }),
                                                        );
                                                      },
                                                    ),
                                                    const SizedBox(width: 12),
                                                  ],
                                                  StreamBuilder<
                                                    SleepTimerStatus
                                                  >(
                                                    stream:
                                                        player.sleepTimerStream,
                                                    initialData:
                                                        player.sleepTimerStatus,
                                                    builder: (_, snap) {
                                                      final timerStatus =
                                                          snap.data ??
                                                          const SleepTimerStatus.off();
                                                      return IconButton(
                                                        tooltip:
                                                            timerStatus.isActive
                                                            ? 'Sleep timer: ${_sleepTimerLabel(timerStatus)}'
                                                            : 'Sleep timer',
                                                        icon: Icon(
                                                          theme.useGlassTheme
                                                              ? CupertinoIcons
                                                                    .moon
                                                              : Icons
                                                                    .bedtime_outlined,
                                                          color:
                                                              timerStatus
                                                                  .isActive
                                                              ? Colors
                                                                    .lightBlueAccent
                                                              : Colors.white70,
                                                        ),
                                                        iconSize: 26,
                                                        onPressed: () {
                                                          _showSleepTimerSheet(
                                                            context,
                                                            player,
                                                            theme.useGlassTheme,
                                                          );
                                                        },
                                                      );
                                                    },
                                                  ),
                                                  if (hasRemoteTrack) ...[
                                                    const SizedBox(width: 12),
                                                    IconButton(
                                                      icon: Icon(
                                                        theme.useGlassTheme
                                                            ? CupertinoIcons
                                                                  .music_note_list
                                                            : Icons
                                                                  .playlist_add,
                                                        color: Colors.white70,
                                                      ),
                                                      iconSize: 26,
                                                      onPressed: () {
                                                        _showAddToPlaylistSheet(
                                                          context,
                                                          currentSong,
                                                        );
                                                      },
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ],
                                            const SizedBox(height: 12),
                                            const Text(
                                              'Swipe right for lyrics',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.white54,
                                              ),
                                              textAlign: TextAlign.center,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            if (upcomingWithIndices.isNotEmpty) ...[
                              const SizedBox(height: 28),
                              const Text(
                                'Up Next',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 12),
                              ...upcomingWithIndices.map(
                                (upcomingSong) => RepaintBoundary(
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: GlassContainer(
                                      child: ListTile(
                                        leading: ClipRRect(
                                          clipBehavior: Clip.antiAlias,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: Transform.scale(
                                            scale:
                                                YoutubeThumbnailUtils.preferredArtworkScale(
                                                  songId: upcomingSong.song.id,
                                                  imageUrl: upcomingSong
                                                      .song
                                                      .meta
                                                      .imageUrl,
                                                  youtubeVideoScale: 1.0,
                                                  normalScale: 1.0,
                                                ),
                                            child: FallbackNetworkImage(
                                              urls:
                                                  YoutubeThumbnailUtils.candidateUrls(
                                                    songId:
                                                        upcomingSong.song.id,
                                                    imageUrl: upcomingSong
                                                        .song
                                                        .meta
                                                        .imageUrl,
                                                  ),
                                              width: 48,
                                              height: 48,
                                              cacheWidth: queueArtCacheSize,
                                              cacheHeight: queueArtCacheSize,
                                              fit: BoxFit.cover,
                                              alignment: Alignment.center,
                                              filterQuality:
                                                  FilterQuality.medium,
                                              fallback: Container(
                                                width: 48,
                                                height: 48,
                                                color: Colors.black26,
                                                child: const Icon(
                                                  Icons.music_note_rounded,
                                                  size: 22,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        title: Text(
                                          upcomingSong.song.meta.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(
                                          upcomingSong.song.meta.artist,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing:
                                            _isDownloadedLocalTrack(
                                                  upcomingSong.song,
                                                ) ||
                                                _isLocalAudio(upcomingSong.song)
                                            ? IconButton(
                                                tooltip: 'Delete file',
                                                iconSize: 20,
                                                visualDensity:
                                                    VisualDensity.compact,
                                                constraints:
                                                    const BoxConstraints.tightFor(
                                                      width: 32,
                                                      height: 32,
                                                    ),
                                                icon: Icon(
                                                  theme.useGlassTheme
                                                      ? CupertinoIcons.trash
                                                      : Icons.delete_outline,
                                                  color: Colors.redAccent,
                                                ),
                                                onPressed: () async {
                                                  if (_isDownloadedLocalTrack(
                                                    upcomingSong.song,
                                                  )) {
                                                    await _deleteDownloadedSong(
                                                      context,
                                                      upcomingSong.song,
                                                      player,
                                                    );
                                                  } else {
                                                    await _deleteLocalAudio(
                                                      context,
                                                      upcomingSong.song,
                                                      player,
                                                    );
                                                  }
                                                },
                                              )
                                            : StreamBuilder<
                                                Map<
                                                  String,
                                                  List<Map<String, dynamic>>
                                                >
                                              >(
                                                stream: PlaylistManager.stream,
                                                builder: (_, playlistSnap) {
                                                  final playlists =
                                                      playlistSnap.data ?? {};
                                                  final favs =
                                                      playlists[PlaylistManager
                                                          .systemFavourites] ??
                                                      [];
                                                  final isFav = favs.any(
                                                    (s) =>
                                                        s['id'] ==
                                                        upcomingSong.song.id,
                                                  );

                                                  return Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      IconButton(
                                                        tooltip: isFav
                                                            ? 'Remove from favorites'
                                                            : 'Add to favorites',
                                                        iconSize: 20,
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                        constraints:
                                                            const BoxConstraints.tightFor(
                                                              width: 32,
                                                              height: 32,
                                                            ),
                                                        icon: Icon(
                                                          theme.useGlassTheme
                                                              ? (isFav
                                                                    ? CupertinoIcons
                                                                          .heart_fill
                                                                    : CupertinoIcons
                                                                          .heart)
                                                              : (isFav
                                                                    ? Icons
                                                                          .favorite
                                                                    : Icons
                                                                          .favorite_border),
                                                          color: isFav
                                                              ? Colors.redAccent
                                                              : Colors.white70,
                                                        ),
                                                        onPressed: () async =>
                                                            await PlaylistManager.toggleFavourite({
                                                              'id': upcomingSong
                                                                  .song
                                                                  .id,
                                                              'title':
                                                                  upcomingSong
                                                                      .song
                                                                      .meta
                                                                      .title,
                                                              'artist':
                                                                  upcomingSong
                                                                      .song
                                                                      .meta
                                                                      .artist,
                                                              'imageUrl':
                                                                  upcomingSong
                                                                      .song
                                                                      .meta
                                                                      .imageUrl,
                                                            }),
                                                      ),
                                                      IconButton(
                                                        tooltip:
                                                            'Add to playlist',
                                                        iconSize: 20,
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                        constraints:
                                                            const BoxConstraints.tightFor(
                                                              width: 32,
                                                              height: 32,
                                                            ),
                                                        icon: Icon(
                                                          theme.useGlassTheme
                                                              ? CupertinoIcons
                                                                    .music_note_list
                                                              : Icons
                                                                    .playlist_add,
                                                          color: Colors.white70,
                                                        ),
                                                        onPressed: () =>
                                                            _showAddToPlaylistSheet(
                                                              context,
                                                              upcomingSong.song,
                                                            ),
                                                      ),
                                                    ],
                                                  );
                                                },
                                              ),
                                        onTap: () => player.jumpToIndex(
                                          upcomingSong.absoluteIndex,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 32),
                          ],
                        );
                      },
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

class _QueuedDownloadTask {
  final QueuedSong song;

  const _QueuedDownloadTask({required this.song});
}

void _showAddToPlaylistSheet(BuildContext context, QueuedSong song) {
  final stableContext = context;
  final useGlassTheme = Provider.of<ThemeProvider>(
    context,
    listen: false,
  ).useGlassTheme;
  final addedInSheet = <String>{};

  IconData playlistIcon() {
    return useGlassTheme
        ? CupertinoIcons.music_note_list
        : Icons.playlist_add_rounded;
  }

  IconData addedIcon() {
    return useGlassTheme
        ? CupertinoIcons.check_mark_circled_solid
        : Icons.check_circle;
  }

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.black.withValues(alpha: 0.85),
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
                      const Text(
                        'Add to Playlist',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: playlistNames.isEmpty
                            ? const Center(
                                child: Text(
                                  'No playlists yet',
                                  style: TextStyle(color: Colors.white54),
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
                                          exists || addedInSheet.contains(name);

                                      return ListTile(
                                        leading: Icon(
                                          added ? addedIcon() : playlistIcon(),
                                          color: added
                                              ? Colors.green.shade400
                                              : null,
                                        ),
                                        title: Text(name),
                                        onTap: () async {
                                          if (added) {
                                            AppMessenger.show(
                                              'Already in "$name"',
                                              color: Colors.orange.shade700,
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
                                              color: Colors.green.shade700,
                                            );
                                          } else {
                                            AppMessenger.show(
                                              'Already in "$name"',
                                              color: Colors.orange.shade700,
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
            AppMessenger.show(
              'Playlist "$name" created',
              color: Colors.green.shade700,
            );
          },
          child: const Text('Create'),
        ),
      ],
    ),
  );
}

class _UpcomingSong {
  final QueuedSong song;
  final int absoluteIndex;

  _UpcomingSong({required this.song, required this.absoluteIndex});
}

class _AutoMarqueeText extends StatelessWidget {
  final String text;
  final TextStyle style;

  const _AutoMarqueeText({required this.text, required this.style});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, c) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();

        if (painter.width <= c.maxWidth) {
          return Text(
            text,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          );
        }

        return Marquee(
          text: text,
          blankSpace: 40,
          velocity: 28,
          pauseAfterRound: const Duration(seconds: 1),
          style: style,
        );
      },
    );
  }
}

class _SwipeLyricsPlayerCard extends StatefulWidget {
  final QueuedSong? song;
  final AudioPlayerService player;
  final bool useGlassTheme;
  final Widget frontCard;

  const _SwipeLyricsPlayerCard({
    required this.song,
    required this.player,
    required this.useGlassTheme,
    required this.frontCard,
  });

  @override
  State<_SwipeLyricsPlayerCard> createState() => _SwipeLyricsPlayerCardState();
}

class _SwipeLyricsPlayerCardState extends State<_SwipeLyricsPlayerCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flipController;
  Future<LrcLibLyrics?>? _lyricsFuture;
  String? _lyricsSongId;
  double _dragDx = 0;
  double _dragDy = 0;

  @override
  void initState() {
    super.initState();
    _flipController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _syncLyricsRequest();
  }

  @override
  void didUpdateWidget(covariant _SwipeLyricsPlayerCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncLyricsRequest();
    final nextSong = widget.song;
    if ((nextSong == null || nextSong.isLocal) && _flipController.value > 0) {
      _flipController.reverse();
    }
  }

  @override
  void dispose() {
    _flipController.dispose();
    super.dispose();
  }

  void _syncLyricsRequest() {
    final song = widget.song;
    final songId = song?.id;
    if (songId == _lyricsSongId) return;
    _lyricsSongId = songId;

    if (song == null || song.isLocal) {
      _lyricsFuture = null;
      return;
    }

    _lyricsFuture = LrcLibApi.fetchBestLyrics(
      title: song.meta.title,
      artist: song.meta.artist,
    );
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    _dragDx += details.delta.dx;
    _dragDy += details.delta.dy;
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dx;

    final isMostlyHorizontal = _dragDx.abs() > _dragDy.abs() * 1.2;

    if (!isMostlyHorizontal) {
      _resetDrag();
      return;
    }

    const distanceThreshold = 90.0;
    const velocityThreshold = 700.0;

    final swipeRight =
        _dragDx > distanceThreshold || velocity > velocityThreshold;

    final swipeLeft =
        _dragDx < -distanceThreshold || velocity < -velocityThreshold;

    if (swipeRight && _flipController.value < 0.5) {
      _flipToLyrics();
    } else if (swipeLeft && _flipController.value >= 0.5) {
      _flipToPlayer();
    }

    _resetDrag();
  }

  void _resetDrag() {
    _dragDx = 0;
    _dragDy = 0;
  }

  void _flipToLyrics() {
    final song = widget.song;
    if (song == null || song.isLocal) return;
    _flipController.forward();
  }

  void _flipToPlayer() {
    _flipController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: AnimatedBuilder(
        animation: _flipController,
        builder: (context, _) {
          final value = _flipController.value;
          final showingFront = value < 0.5;
          final angle = showingFront ? value * math.pi : (value - 1) * math.pi;

          final transform = Matrix4.identity()
            ..setEntry(3, 2, 0.0018)
            ..rotateY(angle);

          final visibleChild = showingFront
              ? widget.frontCard
              : _LyricsBackCard(
                  song: widget.song,
                  player: widget.player,
                  useGlassTheme: widget.useGlassTheme,
                  lyricsFuture: _lyricsFuture,
                );

          return Transform(
            alignment: Alignment.center,
            transform: transform,
            child: visibleChild,
          );
        },
      ),
    );
  }
}

class _LyricsBackCard extends StatelessWidget {
  final QueuedSong? song;
  final AudioPlayerService player;
  final bool useGlassTheme;
  final Future<LrcLibLyrics?>? lyricsFuture;

  const _LyricsBackCard({
    required this.song,
    required this.player,
    required this.useGlassTheme,
    required this.lyricsFuture,
  });

  @override
  Widget build(BuildContext context) {
    final activeSong = song;
    return GlassContainer(
      borderRadius: BorderRadius.circular(32),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Row(
              children: [
                Icon(
                  useGlassTheme
                      ? CupertinoIcons.music_note_2
                      : Icons.lyrics_outlined,
                  size: 20,
                  color: Colors.white70,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Lyrics',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                FutureBuilder<LrcLibLyrics?>(
                  future: lyricsFuture,
                  builder: (context, snap) {
                    if (snap.data == null) return const SizedBox.shrink();
                    final isSynced = snap.data!.hasSyncedLyrics;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: isSynced
                            ? Colors.white.withValues(alpha: 0.15)
                            : Colors.white.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Text(
                        isSynced ? '✦ Synced' : 'Plain',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'Helvetica',
                          fontWeight: FontWeight.w700,
                          color: isSynced ? Colors.white : Colors.white54,
                          letterSpacing: 0.3,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (activeSong == null)
              const SizedBox(
                height: 360,
                child: Center(
                  child: Text(
                    'No song playing',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              )
            else if (activeSong.isLocal)
              const SizedBox(
                height: 360,
                child: Center(
                  child: Text(
                    'Lyrics are currently available for streaming tracks only.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              )
            else
              SizedBox(
                height: 360,
                child: FutureBuilder<LrcLibLyrics?>(
                  future: lyricsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    if (snapshot.hasError) {
                      return const Center(
                        child: Text(
                          'Lyrics failed to load.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      );
                    }

                    final lyrics = snapshot.data;
                    if (lyrics == null) {
                      return const Center(
                        child: Text(
                          'No lyrics found for this song.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70),
                        ),
                      );
                    }

                    if (lyrics.instrumental) {
                      return const Center(
                        child: Text(
                          'Instrumental track.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      );
                    }

                    if (lyrics.hasSyncedLyrics) {
                      return _SyncedLyricsView(
                        key: ValueKey(lyrics),
                        lines: lyrics.parsedLines,
                        player: player,
                      );
                    }

                    final plain = lyrics.plainLyrics.trim();
                    if (plain.isEmpty) {
                      return const Center(
                        child: Text(
                          'No lyrics available.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      );
                    }

                    return SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: Text(
                        plain,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 17,
                          fontFamily: 'Helvetica',
                          fontWeight: FontWeight.w400,
                          color: Colors.white70,
                          height: 1.7,
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              'Swipe left to return to player controls',
              style: TextStyle(fontSize: 12, color: Colors.white54),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncedLyricsView extends StatefulWidget {
  final List<LyricLine> lines;
  final AudioPlayerService player;

  const _SyncedLyricsView({
    super.key,
    required this.lines,
    required this.player,
  });

  @override
  State<_SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends State<_SyncedLyricsView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late Animation<double> _indexAnim;
  StreamSubscription<Duration>? _positionSub;
  int _activeIndex = 0;
  static const double _lineHeight = 72.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
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
  void didUpdateWidget(covariant _SyncedLyricsView oldWidget) {
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
    var low = 0, high = lines.length - 1, result = 0;
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
            stops: [0.0, 0.22, 0.78, 1.0],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _indexAnim,
              builder: (context, _) {
                final translateY = centerY - _indexAnim.value * _lineHeight;
                return OverflowBox(
                  maxHeight: double.infinity,
                  alignment: Alignment.topCenter,
                  child: Transform.translate(
                    offset: Offset(0, translateY),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(widget.lines.length, (index) {
                        final isActive = index == _activeIndex;
                        final distance = (index - _activeIndex).abs();
                        final opacity = isActive
                            ? 1.0
                            : (distance <= 1
                                  ? 0.45
                                  : (distance <= 3 ? 0.25 : 0.12));

                        return SizedBox(
                          height: _lineHeight,
                          child: Center(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 300),
                              opacity: opacity,
                              child: AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOut,
                                style: TextStyle(
                                  fontSize: 17,
                                  height: 1.3,
                                  fontFamily: 'Helvetica',
                                  fontWeight: isActive
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                  color: Colors.white,
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
                );
              },
            ),
          ),
        );
      },
    );
  }
}
