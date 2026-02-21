import 'dart:io';
import 'dart:ui';
import 'dart:collection';
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
    final backdropBlur = fullVisuals ? 30.0 : 16.0;

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
                      youtubeVideoScale: 1.9,
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
                              child: GlassContainer(
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
                                              cacheWidth: 768,
                                              cacheHeight: 768,
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
                                                  posSnap.data ?? Duration.zero;
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
                                                        useGlassTheme:
                                                            theme.useGlassTheme,
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
                                                              style:
                                                                  const TextStyle(
                                                                    fontSize:
                                                                        12,
                                                                    color: Colors
                                                                        .white70,
                                                                  ),
                                                            ),
                                                            Text(
                                                              _fmt(shownDur),
                                                              style:
                                                                  const TextStyle(
                                                                    fontSize:
                                                                        12,
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
                                                  stream: player.loopModeStream,
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
                                                            mode == LoopMode.off
                                                            ? Colors.white54
                                                            : Colors.white,
                                                      ),
                                                      onPressed:
                                                          player.toggleLoopMode,
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
                                                  stream:
                                                      player.trackLoadingStream,
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
                                                                      width: 28,
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
                                                                  iconSize: 56,
                                                                  icon: Icon(
                                                                    playing
                                                                        ? (theme.useGlassTheme
                                                                              ? CupertinoIcons.pause_circle_fill
                                                                              : Icons.pause_circle_filled)
                                                                        : (theme.useGlassTheme
                                                                              ? CupertinoIcons.play_circle_fill
                                                                              : Icons.play_circle_filled),
                                                                  ),
                                                                  onPressed: player
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
                                                          ? CupertinoIcons.trash
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
                                                          ? CupertinoIcons.trash
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
                                          if (hasRemoteTrack) ...[
                                            const SizedBox(height: 8),

                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                StreamBuilder<
                                                  Map<
                                                    String,
                                                    List<Map<String, dynamic>>
                                                  >
                                                >(
                                                  stream:
                                                      PlaylistManager.stream,
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
                                                            ? Colors.redAccent
                                                            : Colors.white70,
                                                      ),
                                                      iconSize: 26,
                                                      onPressed: () async =>
                                                          await PlaylistManager.toggleFavourite(
                                                            {
                                                              'id': currentSong
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
                                                            },
                                                          ),
                                                    );
                                                  },
                                                ),
                                                const SizedBox(width: 12),
                                                StreamBuilder<SleepTimerStatus>(
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
                                                            timerStatus.isActive
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
                                                const SizedBox(width: 12),
                                                IconButton(
                                                  icon: Icon(
                                                    theme.useGlassTheme
                                                        ? CupertinoIcons
                                                              .music_note_list
                                                        : Icons.playlist_add,
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
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
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
                                                  youtubeVideoScale: 1.9,
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
                                              cacheWidth: 256,
                                              cacheHeight: 256,
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
                            if (!rootNavigator.mounted) return;
                            _showCreatePlaylistDialog(rootNavigator.context);
                          });
                        },
                        child: const Text('+ Create new playlist'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                if (playlists.isEmpty)
                  const Text(
                    'No playlists yet',
                    style: TextStyle(color: Colors.white54),
                  ),

                ...playlists.keys
                    .where((name) => name != PlaylistManager.systemFavourites)
                    .map(
                      (name) => ListTile(
                        leading: const Icon(CupertinoIcons.music_note_list),
                        title: Text(name),
                        onTap: () async {
                          final navigator = Navigator.of(context);
                          final success = await PlaylistManager.addSong(name, {
                            'id': song.id,
                            'title': song.meta.title,
                            'artist': song.meta.artist,
                            'imageUrl': song.meta.imageUrl,
                          });

                          navigator.pop();

                          if (success) {
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
                      ),
                    ),

                const SizedBox(height: 8),

                TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    _showCreatePlaylistDialog(context);
                  },
                  child: const Text('＋ Create new playlist'),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

void _showCreatePlaylistDialog(BuildContext context) {
  final controller = TextEditingController();

  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      title: const Text('New Playlist'),
      content: TextField(
        controller: controller,
        decoration: const InputDecoration(hintText: 'Playlist name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () async {
            final name = controller.text.trim();
            if (name.isEmpty) return;

            final navigator = Navigator.of(context);
            await PlaylistManager.create(name);
            navigator.pop();
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
