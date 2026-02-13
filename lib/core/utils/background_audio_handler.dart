import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'app_logger.dart';
import 'audio_player_service.dart';
import 'notification_art_cache.dart';
import 'youtube_thumbnail_utils.dart';

class BackgroundAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayerService _service = AudioPlayerService();

  StreamSubscription? _positionSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _durationSub;
  String _activeArtSeed = '';

  Duration? _latestDuration;

  BackgroundAudioHandler() {
    _listenState();
    _listenPosition();
    _listenDuration();
    _listenNowPlaying();
  }

  void _listenState() {
    _stateSub = _service.playerStateStream.listen((state) {
      playbackState.add(
        playbackState.value.copyWith(
          controls: [
            MediaControl.skipToPrevious,
            _service.isPlaying ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
          ],
          androidCompactActionIndices: const [0, 1, 2],
          processingState: _mapState(state.processingState),
          playing: _service.isPlaying,
          speed: 1.0,
        ),
      );
    });
  }

  void _listenPosition() {
    _positionSub = _service.positionStream.listen((pos) {
      playbackState.add(
        playbackState.value.copyWith(
          updatePosition: pos,
          bufferedPosition: pos,
        ),
      );
    });
  }

  void _listenDuration() {
    _durationSub = _service.durationStream.listen((dur) {
      // Cache the latest duration
      _latestDuration = dur;

      final item = mediaItem.value;
      if (item == null || dur == null) return;

      mediaItem.add(item.copyWith(duration: dur));
    });
  }

  void _listenNowPlaying() {
    _service.nowPlayingStream.listen((now) {
      if (now == null) return;
      final artSeed = '${now.title}|${now.artist}|${now.imageUrl}';
      _activeArtSeed = artSeed;
      final artUri = _notificationArtUri(now.imageUrl);

      mediaItem.add(
        MediaItem(
          id: now.title,
          title: now.title,
          artist: now.artist,
          artUri: artUri,
          duration: _latestDuration,
        ),
      );

      if (artUri != null) {
        unawaited(_upgradeToSquareNotificationArt(artSeed, artUri.toString()));
      }
    });
  }

  Future<void> _upgradeToSquareNotificationArt(
    String artSeed,
    String sourceUrl,
  ) async {
    try {
      final squareUri = await NotificationArtCache.getSquareArtUri(sourceUrl);
      if (squareUri == null) return;
      if (artSeed != _activeArtSeed) return;

      final current = mediaItem.value;
      if (current == null) return;
      if (current.artUri?.toString() == squareUri.toString()) return;

      mediaItem.add(current.copyWith(artUri: squareUri));
    } catch (e) {
      AppLogger.warning('Failed to upgrade notification art: $e', error: e);
    }
  }

  Uri? _notificationArtUri(String rawImageUrl) {
    final imageUrl = rawImageUrl.trim();
    if (imageUrl.isEmpty) return null;

    final youtubeVideoId = YoutubeThumbnailUtils.videoIdFromUrl(imageUrl);
    if (youtubeVideoId != null) {
      final candidates = YoutubeThumbnailUtils.candidateUrls(
        imageUrl: imageUrl,
      );

      String pickByToken(String token) {
        for (final url in candidates) {
          if (url.contains(token)) return url;
        }
        return '';
      }

      final maxRes = pickByToken('/maxresdefault.jpg');
      final sdDefault = pickByToken('/sddefault.jpg');
      final hq720 = pickByToken('/hq720.jpg');
      final hqDefault = pickByToken('/hqdefault.jpg');

      final preferred = maxRes.isNotEmpty
          ? maxRes
          : sdDefault.isNotEmpty
          ? sdDefault
          : hq720.isNotEmpty
          ? hq720
          : hqDefault.isNotEmpty
          ? hqDefault
          : candidates.isNotEmpty
          ? candidates.first
          : imageUrl;

      return Uri.tryParse(preferred) ?? Uri.tryParse(imageUrl);
    }

    return Uri.tryParse(imageUrl);
  }

  AudioProcessingState _mapState(ProcessingState s) {
    switch (s) {
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
      default:
        return AudioProcessingState.idle;
    }
  }

  @override
  Future<void> play() async => _service.togglePlayPause();

  @override
  Future<void> pause() async => _service.togglePlayPause();

  @override
  Future<void> skipToNext() => _service.skipNext();

  @override
  Future<void> skipToPrevious() => _service.skipPrevious();

  @override
  Future<void> seek(Duration position) => _service.seek(position);

  Future<void> close() async {
    await _positionSub?.cancel();
    await _stateSub?.cancel();
    await _durationSub?.cancel();
  }
}
