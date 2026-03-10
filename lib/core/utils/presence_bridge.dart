import 'dart:async';
import 'audio_player_service.dart';

/// Normalized snapshot sent to every PresenceAdapter
class NowPlayingState {
  final String title;
  final String artist;
  final String imageUrl;
  final bool isPlaying;
  final DateTime startedAt;

  /// Current playback position at the time this snapshot was created
  final Duration position;

  /// Total track duration, null if unknown
  final Duration? duration;

  const NowPlayingState({
    required this.title,
    required this.artist,
    required this.imageUrl,
    required this.isPlaying,
    required this.startedAt,
    this.position = Duration.zero,
    this.duration,
  });

  NowPlayingState copyWith({bool? isPlaying, Duration? position}) =>
      NowPlayingState(
        title: title,
        artist: artist,
        imageUrl: imageUrl,
        isPlaying: isPlaying ?? this.isPlaying,
        startedAt: startedAt,
        position: position ?? this.position,
        duration: duration,
      );
}

abstract class PresenceAdapter {
  Future<void> onStateChanged(NowPlayingState state);
  Future<void> onCleared();
  Future<void> dispose();
}

/// Singleton bridge: wires AudioPlayerService to pluggable PresenceAdapters
class PresenceBridge {
  PresenceBridge._();
  static final PresenceBridge instance = PresenceBridge._();

  final List<PresenceAdapter> _adapters = [];
  StreamSubscription<NowPlaying?>? _nowPlayingSub;
  StreamSubscription? _stateSub;
  NowPlayingState? _lastState;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;

    final service = AudioPlayerService();

    _nowPlayingSub = service.nowPlayingStream.listen((now) {
      if (now == null) {
        _lastState = null;
        _broadcast(null);
        return;
      }
      final state = NowPlayingState(
        title: now.title,
        artist: now.artist,
        imageUrl: now.imageUrl,
        isPlaying: service.isPlaying,
        startedAt: DateTime.now(),
        position: service.position,
        duration: service.duration,
      );
      _lastState = state;
      _broadcast(state);
    });

    _stateSub = service.playerStateStream.listen((_) {
      final last = _lastState;
      if (last == null) return;
      final isPlaying = service.isPlaying;
      // Skip if play/pause state didn't actually change which avoids redundant pushes
      if (isPlaying == last.isPlaying) return;
      final updated = last.copyWith(
        isPlaying: isPlaying,
        position: service.position,
      );
      _lastState = updated;
      _broadcast(updated);
    });
  }

  void addAdapter(PresenceAdapter adapter) {
    if (_adapters.contains(adapter)) return;
    _adapters.add(adapter);
    final state = _lastState;
    if (state != null) adapter.onStateChanged(state);
  }

  void removeAdapter(PresenceAdapter adapter) {
    _adapters.remove(adapter);
    adapter.dispose();
  }

  void _broadcast(NowPlayingState? state) {
    for (final adapter in List.of(_adapters)) {
      if (state == null) {
        adapter.onCleared();
      } else {
        adapter.onStateChanged(state);
      }
    }
  }

  Future<void> dispose() async {
    await _nowPlayingSub?.cancel();
    await _stateSub?.cancel();
    for (final adapter in List.of(_adapters)) {
      await adapter.dispose();
    }
    _adapters.clear();
    _started = false;
  }
}
