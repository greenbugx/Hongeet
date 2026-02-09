import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'audio_player_service.dart';

class BackgroundAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {

  final AudioPlayerService _service = AudioPlayerService();

  StreamSubscription? _positionSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _durationSub;

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

      mediaItem.add(
        MediaItem(
          id: now.title,
          title: now.title,
          artist: now.artist,
          artUri: now.imageUrl.isEmpty ? null : Uri.parse(now.imageUrl),
          duration: _latestDuration,
        ),
      );
    });
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
