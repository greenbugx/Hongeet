import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import '../../data/api/saavn_song_api.dart';
import '../../features/library/recently_played_cache.dart';
import '../../features/library/playlist_manager.dart';

class NowPlaying {
  final String title;
  final String artist;
  final String imageUrl;

  NowPlaying({
    required this.title,
    required this.artist,
    required this.imageUrl,
  });
}

class QueuedSong {
  final String id;
  final NowPlaying meta;
  final bool isLocal;

  QueuedSong({
    required this.id,
    required this.meta,
    this.isLocal = false,
  });
}

class AudioPlayerService {

  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;

  AudioPlayerService._internal() {
    _player.playerStateStream.listen(_onPlayerStateChanged);
    _player.setLoopMode(LoopMode.off);
    _loadRecentlyPlayed();
    PlaylistManager.load();
  }

  final AudioPlayer _player = AudioPlayer();
  AudioPlayer get player => _player;

  List<QueuedSong> _queue = [];
  List<QueuedSong> get queue => List.unmodifiable(_queue);

  int _currentIndex = 0;

  int _playToken = 0;

  String? _loadedSongId;

  final _nowPlaying = BehaviorSubject<NowPlaying?>();
  Stream<NowPlaying?> get nowPlayingStream => _nowPlaying.stream;

  final _currentIndexSubject = BehaviorSubject<int?>.seeded(null);
  Stream<int?> get currentIndexStream => _currentIndexSubject.stream;
  int? get currentIndex => _currentIndexSubject.value;

  final _recentlyPlayedSubject = BehaviorSubject<List<Map<String, dynamic>>>();
  Stream<List<Map<String, dynamic>>> get recentlyPlayedStream =>
      _recentlyPlayedSubject.stream;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<LoopMode> get loopModeStream => _player.loopModeStream;
  LoopMode get loopMode => _player.loopMode;

  final Map<String, _CachedUrl> _urlCache = {};

  Future<String> _resolveUrl(String id) async {
    if (_urlCache.containsKey(id)) {
      final cached = _urlCache[id]!;
      final age = DateTime.now().difference(cached.timestamp);
      if (age.inHours < 24) {
        return cached.url;
      } else {
        _urlCache.remove(id);
      }
    }
    final url = await SaavnSongApi.fetchBestStreamUrl(id);
    _urlCache[id] = _CachedUrl(url: url, timestamp: DateTime.now());
    if (_urlCache.length > 500) _cleanCache();
    return url;
  }

  void _cleanCache() {
    final entries = _urlCache.entries.toList()
      ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
    for (int i = 0; i < 100 && i < entries.length; i++) {
      _urlCache.remove(entries[i].key);
    }
  }

  Future<void> _loadRecentlyPlayed() async {
    final items = await RecentlyPlayedCache.getAll();
    _recentlyPlayedSubject.add(items);
  }


  Future<void> _loadAndPlaySong(int index, int token) async {
    if (index < 0 || index >= _queue.length) {
      print('⚠️ Invalid index: $index (queue length: ${_queue.length})');
      return;
    }

    final song = _queue[index];

    if (token != _playToken) {
      print('🚫 Stale load request for index $index (token mismatch)');
      return;
    }

    try {
      await _player.stop();
      _loadedSongId = null;

      if (token != _playToken) return;

      final String url;
      if (song.isLocal) {
        url = song.id;
      } else {
        url = await _resolveUrl(song.id);
      }

      if (token != _playToken) return;

      final source = song.isLocal
          ? AudioSource.uri(Uri.file(url))
          : AudioSource.uri(Uri.parse(url));

      await _player.setAudioSource(source);

      if (token != _playToken) return;

      _loadedSongId = song.id;
      _currentIndex = index;
      _currentIndexSubject.add(index);
      _nowPlaying.add(song.meta);

      await _player.play();

      await _addToRecentlyPlayed(song);

      print('✅ Successfully loaded and playing: ${song.meta.title} (index: $index)');
    } catch (e) {
      print('❌ Failed to load song at index $index: $e');
    }
  }

  Future<void> playFromList({
    required List<QueuedSong> songs,
    required int startIndex,
  }) async {
    if (songs.isEmpty) {
      print('⚠️ Cannot play from empty list');
      return;
    }

    final int token = ++_playToken;

    final safeIndex = startIndex.clamp(0, songs.length - 1);

    print('🎵 playFromList called: ${songs.length} songs, starting at index $safeIndex');

    _queue = List.unmodifiable(songs);

    await _loadAndPlaySong(safeIndex, token);
  }

  Future<void> playPlaylist({
    required List<Map<String, dynamic>> songs,
    required String title,
  }) async {
    if (songs.isEmpty) return;

    final queued = songs.map((song) {
      return QueuedSong(
        id: song['id'],
        meta: NowPlaying(
          title: song['title'],
          artist: song['artist'],
          imageUrl: song['imageUrl'],
        ),
      );
    }).toList();

    await playFromList(
      songs: queued,
      startIndex: 0,
    );
  }

  Future<void> playNow(QueuedSong song) async {
    final int token = ++_playToken;

    print('🎵 playNow called: ${song.meta.title}');

    _queue = List.unmodifiable([song]);

    await _loadAndPlaySong(0, token);
  }

  Future<void> playLocalFile(String path, String name) async {
    final song = QueuedSong(
      id: path,
      isLocal: true,
      meta: NowPlaying(title: name, artist: 'Offline', imageUrl: ''),
    );
    await playNow(song);
  }

  Future<void> playFromCache(Map<String, dynamic> song) async {
    final bool isLocal = song['isLocal'] ?? false;
    if (isLocal) {
      await playLocalFile(song['id'], song['title']);
    } else {
      final queued = QueuedSong(
        id: song['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        meta: NowPlaying(
          title: song['title'],
          artist: song['artist'],
          imageUrl: song['imageUrl'],
        ),
      );
      await playNow(queued);
    }
  }

  Future<void> skipNext() async {
    if (_queue.isEmpty) return;

    final nextIndex = _currentIndex + 1;

    // Handle loop mode
    if (nextIndex >= _queue.length) {
      if (_player.loopMode == LoopMode.all) {
        await jumpToIndex(0);
      } else {
        print(' Reached end of queue');
      }
      return;
    }

    await jumpToIndex(nextIndex);
  }

  Future<void> skipPrevious() async {
    if (_queue.isEmpty) return;

    final position = _player.position;
    if (position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      return;
    }

    final prevIndex = _currentIndex - 1;

    // Handle loop mode
    if (prevIndex < 0) {
      if (_player.loopMode == LoopMode.all) {
        await jumpToIndex(_queue.length - 1);
      } else {
        // Restart current song
        await _player.seek(Duration.zero);
      }
      return;
    }

    await jumpToIndex(prevIndex);
  }

  Future<void> jumpToIndex(int queueIndex) async {
    if (queueIndex < 0 || queueIndex >= _queue.length) {
      print('⚠️ Invalid jump index: $queueIndex');
      return;
    }

    final int token = ++_playToken;
    await _loadAndPlaySong(queueIndex, token);
  }

  void togglePlayPause() {
    if (_player.playing) {
      _player.pause();
    } else {
      _player.play();
    }
  }

  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> toggleLoopMode() async {
    switch (_player.loopMode) {
      case LoopMode.off:
        await _player.setLoopMode(LoopMode.all);
        break;
      case LoopMode.all:
        await _player.setLoopMode(LoopMode.one);
        break;
      case LoopMode.one:
        await _player.setLoopMode(LoopMode.off);
        break;
    }
  }

  Future<void> setLoopMode(LoopMode mode) => _player.setLoopMode(mode);

  void _onPlayerStateChanged(PlayerState state) {
    if (state.processingState == ProcessingState.completed) {
      if (_player.loopMode == LoopMode.one) {
        _player.seek(Duration.zero);
        _player.play();
      } else if (_player.loopMode == LoopMode.all || _currentIndex + 1 < _queue.length) {
        skipNext();
      } else {
        print('🏁 Playback completed');
      }
    }
  }

  Future<void> _addToRecentlyPlayed(QueuedSong song) async {
    final songMap = {
      'id': song.id,
      'title': song.meta.title,
      'artist': song.meta.artist,
      'imageUrl': song.meta.imageUrl,
      'isLocal': song.isLocal,
    };
    await RecentlyPlayedCache.add(songMap);
    await _loadRecentlyPlayed();
  }

  void clearStreamCache() {
    _urlCache.clear();
  }

  Future<void> clearRecentlyPlayed() async {
    await RecentlyPlayedCache.clear();
    _recentlyPlayedSubject.add([]);
  }

  Map<String, int> getStreamCacheStats() {
    final now = DateTime.now();
    int fresh = 0;
    int stale = 0;

    for (final entry in _urlCache.values) {
      final age = now.difference(entry.timestamp);
      if (age.inHours < 24) {
        fresh++;
      } else {
        stale++;
      }
    }

    return {
      'total': _urlCache.length,
      'fresh': fresh,
      'stale': stale,
    };
  }

  bool get isPlaying => _player.playing;

  Map<String, dynamic> getCacheStats() {
    final now = DateTime.now();
    int fresh = 0;
    int stale = 0;
    for (final entry in _urlCache.values) {
      final age = now.difference(entry.timestamp);
      if (age.inHours < 24) {
        fresh++;
      } else {
        stale++;
      }
    }
    return {'total': _urlCache.length, 'fresh': fresh, 'stale': stale};
  }

  Future<void> dispose() async {
    await _player.dispose();
    await _nowPlaying.close();
    await _recentlyPlayedSubject.close();
    await _currentIndexSubject.close();
  }
}

class _CachedUrl {
  final String url;
  final DateTime timestamp;
  _CachedUrl({required this.url, required this.timestamp});
}