import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_messenger.dart';
import 'app_logger.dart';
import 'data_saver_settings.dart';
import 'streaming_preferences.dart';
import 'youtube_thumbnail_utils.dart';
import '../widgets/sleep_timer_overlay_screen.dart';
import '../../data/models/saavn_song.dart';
import '../../data/api/saavn_song_api.dart';
import '../../data/api/youtube_song_api.dart';
import '../../data/api/youtube_api.dart';
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

  QueuedSong({required this.id, required this.meta, this.isLocal = false});
}

class AudioPlayerService {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;

  AudioPlayerService._internal() {
    _playerStateSub = _player.playerStateStream.listen(_onPlayerStateChanged);
    _positionSub = _player.positionStream.listen(_onPlaybackPosition);
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
  DateTime? _lastAutoSkipNoticeAt;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  Future<void>? _skipNextInFlight;
  Future<bool>? _queueExtendInFlight;
  int? _prefetchedForIndex;
  bool _autoQueueExtendEnabled = false;
  String? _lastQueueExtendAttemptSongId;
  DateTime? _lastQueueExtendAttemptAt;
  final Set<String> _dynamicQueueSeenKeys = <String>{};
  static const int _maxDynamicSeenKeys = 600;

  final _nowPlaying = BehaviorSubject<NowPlaying?>();
  Stream<NowPlaying?> get nowPlayingStream => _nowPlaying.stream;

  final _currentIndexSubject = BehaviorSubject<int?>.seeded(null);
  Stream<int?> get currentIndexStream => _currentIndexSubject.stream;
  int? get currentIndex => _currentIndexSubject.value;

  final _queueVersion = BehaviorSubject<int>.seeded(0);
  Stream<int> get queueChangeStream => _queueVersion.stream;
  void _notifyQueueChanged() {
    if (!_queueVersion.isClosed) _queueVersion.add(_queueVersion.value + 1);
  }

  final _trackLoading = BehaviorSubject<bool>.seeded(false);
  Stream<bool> get trackLoadingStream => _trackLoading.stream;
  bool get isTrackLoading => _trackLoading.valueOrNull ?? false;

  final _recentlyPlayedSubject = BehaviorSubject<List<Map<String, dynamic>>>();
  Stream<List<Map<String, dynamic>>> get recentlyPlayedStream =>
      _recentlyPlayedSubject.stream;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<LoopMode> get loopModeStream => _player.loopModeStream;
  LoopMode get loopMode => _player.loopMode;

  final Map<String, _CachedUrl> _urlCache = {};
  final Map<String, Future<_ResolvedStream>> _resolveInFlight = {};
  final Map<String, int> _youtubeRetryCount = {};
  final Map<String, int> _transientRetryCount = {};
  Timer? _sleepTimer;
  Timer? _sleepTicker;
  DateTime? _sleepTimerEndsAt;
  bool _sleepEndOfCurrentSong = false;
  bool _sleepOverlayShowing = false;
  final _sleepTimerSubject = BehaviorSubject<SleepTimerStatus>.seeded(
    const SleepTimerStatus.off(),
  );
  Stream<SleepTimerStatus> get sleepTimerStream => _sleepTimerSubject.stream;
  SleepTimerStatus get sleepTimerStatus => _sleepTimerSubject.value;

  static const Map<String, String> _defaultStreamHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
  };
  static const Duration _loadWatchdogTimeout = Duration(seconds: 26);
  static const int _upNextTargetCount = 10;

  Future<_ResolvedStream> _resolveUrl(String id) async {
    final qualityKey = DataSaverSettings.isEnabled ? 'ds' : 'hq';
    final cacheKey = '$id::$qualityKey';
    final bool isYoutube = id.startsWith('yt:');
    final inFlight = _resolveInFlight[cacheKey];
    if (inFlight != null) {
      return inFlight;
    }

    final future = () async {
      if (_urlCache.containsKey(cacheKey)) {
        final cached = _urlCache[cacheKey]!;
        final age = DateTime.now().difference(cached.timestamp);

        final maxAge = isYoutube ? 1 : 24;

        if (age.inHours < maxAge) {
          AppLogger.info(
            'Using cached URL for $cacheKey (age: ${age.inMinutes}m)',
          );
          return _ResolvedStream(
            url: cached.url,
            headers: cached.headers ?? const {},
          );
        } else {
          AppLogger.info(
            'Cache expired for $cacheKey (age: ${age.inHours}h), fetching fresh URL',
          );
          _urlCache.remove(cacheKey);
        }
      }

      final String url;
      final Map<String, String> headers;

      if (isYoutube) {
        final prefs = await SharedPreferences.getInstance();
        final useYoutube = prefs.getBool('use_youtube_service') ?? true;
        if (!useYoutube) {
          throw StateError('YouTube streaming disabled by user');
        }
        final videoId = id.substring(3);
        AppLogger.info('Using YouTube service for playback: $videoId');
        final extracted = await YoutubeSongApi.fetchBestStream(videoId);
        url = extracted.url;
        headers = extracted.headers;
      } else {
        final prefs = await SharedPreferences.getInstance();
        final useSaavn = prefs.getBool('use_saavn_service') ?? false;
        if (!useSaavn) {
          throw StateError('Saavn streaming disabled by user');
        }
        AppLogger.info('Using Saavn service for playback: $id');
        url = await SaavnSongApi.fetchBestStreamUrl(id);
        headers = const {};
      }

      _urlCache[cacheKey] = _CachedUrl(
        url: url,
        headers: headers.isEmpty ? null : headers,
        timestamp: DateTime.now(),
      );

      if (_urlCache.length > 500) _cleanCache();

      return _ResolvedStream(url: url, headers: headers);
    }();

    _resolveInFlight[cacheKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_resolveInFlight[cacheKey], future)) {
        _resolveInFlight.remove(cacheKey);
      }
    }
  }

  void _cleanCache() {
    final entries = _urlCache.entries.toList()
      ..sort((a, b) => a.value.timestamp.compareTo(b.value.timestamp));
    for (int i = 0; i < 100 && i < entries.length; i++) {
      _urlCache.remove(entries[i].key);
    }
  }

  void _onPlaybackPosition(Duration position) {
    final duration = _player.duration;
    if (duration == null || duration <= Duration.zero) return;
    if (isTrackLoading) return;
    final remaining = duration - position;
    if (remaining <= const Duration(seconds: 18)) {
      unawaited(_prefetchNextIfNeeded());
    }
  }

  Future<void> _prefetchNextIfNeeded() async {
    if (_queue.isEmpty) return;
    if (_currentIndex < 0 || _currentIndex >= _queue.length - 1) return;
    if (_prefetchedForIndex == _currentIndex) return;

    final nextSong = _queue[_currentIndex + 1];
    if (nextSong.isLocal) {
      _prefetchedForIndex = _currentIndex;
      return;
    }

    _prefetchedForIndex = _currentIndex;
    try {
      await _resolveUrl(nextSong.id).timeout(const Duration(seconds: 10));
      AppLogger.info('Prefetched next stream for ${nextSong.meta.title}');
    } catch (e) {
      _prefetchedForIndex = null;
      AppLogger.warning('Next stream prefetch failed: $e', error: e);
    }
  }

  void _showAutoSkipNotice() {
    final now = DateTime.now();
    final last = _lastAutoSkipNoticeAt;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    _lastAutoSkipNoticeAt = now;
    AppMessenger.show('Skipping song: server/load error');
  }

  void setSleepTimer(Duration duration) {
    if (duration <= Duration.zero) {
      clearSleepTimer(showMessage: false);
      return;
    }
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    _sleepEndOfCurrentSong = false;
    _sleepTimerEndsAt = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, _onSleepTimerElapsed);
    _sleepTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      _emitSleepTimerState();
    });
    _emitSleepTimerState();
    final mins = duration.inMinutes;
    AppMessenger.show('Sleep timer set: ${mins}m');
  }

  void setSleepTimerEndOfCurrentSong() {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    _sleepTimerEndsAt = null;
    _sleepEndOfCurrentSong = true;
    _emitSleepTimerState();
    AppMessenger.show('Sleep timer: end of current song');
  }

  void clearSleepTimer({bool showMessage = true}) {
    final hadActive = _sleepTimer != null || _sleepEndOfCurrentSong;
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    _sleepTimer = null;
    _sleepTicker = null;
    _sleepTimerEndsAt = null;
    _sleepEndOfCurrentSong = false;
    _emitSleepTimerState();
    if (showMessage && hadActive) {
      AppMessenger.show('Sleep timer turned off');
    }
  }

  void _emitSleepTimerState() {
    if (_sleepEndOfCurrentSong) {
      _sleepTimerSubject.add(const SleepTimerStatus.endOfCurrentSong());
      return;
    }
    final endsAt = _sleepTimerEndsAt;
    if (endsAt == null) {
      _sleepTimerSubject.add(const SleepTimerStatus.off());
      return;
    }
    final remaining = endsAt.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _sleepTimerSubject.add(const SleepTimerStatus.off());
      return;
    }
    _sleepTimerSubject.add(SleepTimerStatus.until(endsAt: endsAt));
  }

  void _onSleepTimerElapsed() {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    _sleepTimer = null;
    _sleepTicker = null;
    _sleepTimerEndsAt = null;
    _sleepEndOfCurrentSong = false;
    _emitSleepTimerState();
    unawaited(_stopFromSleepTimer(endOfCurrentSong: false));
  }

  Future<void> _stopFromSleepTimer({required bool endOfCurrentSong}) async {
    await stopAndClearNowPlaying();
    _showSleepTimerOverlay(endOfCurrentSong: endOfCurrentSong);
  }

  void _showSleepTimerOverlay({required bool endOfCurrentSong}) {
    if (_sleepOverlayShowing) return;
    final navigator = AppMessenger.navigatorKey.currentState;
    final context = AppMessenger.navigatorKey.currentContext;
    if (navigator == null || context == null) return;

    _sleepOverlayShowing = true;
    navigator
        .push(
          PageRouteBuilder<void>(
            opaque: true,
            barrierDismissible: false,
            pageBuilder: (context, animation, secondaryAnimation) =>
                SleepTimerOverlayScreen(endOfCurrentSong: endOfCurrentSong),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
                  return FadeTransition(opacity: animation, child: child);
                },
            transitionDuration: const Duration(milliseconds: 180),
          ),
        )
        .whenComplete(() {
          _sleepOverlayShowing = false;
        });
  }

  void _removeCachedUrlsForSong(String songId) {
    final keysToRemove = _urlCache.keys
        .where((key) => key == songId || key.startsWith('$songId::'))
        .toList(growable: false);
    for (final key in keysToRemove) {
      _urlCache.remove(key);
    }
  }

  bool _isTransientLoadError(String errorText) {
    final lower = errorText.toLowerCase();
    const transientTokens = <String>[
      'failed host lookup',
      'no address associated with hostname',
      'socketexception',
      'transporterror',
      'unable to download api page',
      'network is unreachable',
      'temporary failure in name resolution',
      'connection reset',
      'connection aborted',
      'timed out',
      'timeout',
      'the page needs to be reloaded',
      'page needs to be reloaded',
      'failed to extract any player response',
      'source error',
      'http exception',
      'connection closed before full header was received',
      'watchdog timeout',
    ];

    return transientTokens.any(lower.contains);
  }

  Timer _startLoadWatchdog({
    required QueuedSong song,
    required int index,
    required int token,
  }) {
    return Timer(_loadWatchdogTimeout, () {
      unawaited(
        _handleLoadWatchdogTimeout(song: song, index: index, token: token),
      );
    });
  }

  Future<void> _handleLoadWatchdogTimeout({
    required QueuedSong song,
    required int index,
    required int token,
  }) async {
    if (token != _playToken) return;
    if (!isTrackLoading) return;
    final state = _player.playerState.processingState;
    if (state == ProcessingState.ready || state == ProcessingState.completed) {
      return;
    }

    AppLogger.warning(
      'Load watchdog timeout for ${song.meta.title}, forcing recovery',
    );

    final retried = await _retryCurrentTrackIfTransient(
      song: song,
      index: index,
      token: token,
      errorText: 'watchdog timeout',
    );
    if (retried || token != _playToken) return;

    if (_currentIndex + 1 < _queue.length) {
      _showAutoSkipNotice();
      await Future.delayed(const Duration(milliseconds: 500));
      await skipNext();
    }
  }

  Future<bool> _retryCurrentTrackIfTransient({
    required QueuedSong song,
    required int index,
    required int token,
    required String errorText,
  }) async {
    if (!_isTransientLoadError(errorText)) return false;

    final attempts = (_transientRetryCount[song.id] ?? 0) + 1;
    const maxAttempts = 2;
    if (attempts > maxAttempts) {
      _transientRetryCount.remove(song.id);
      return false;
    }

    _transientRetryCount[song.id] = attempts;
    _removeCachedUrlsForSong(song.id);
    AppLogger.warning(
      'Transient load failure for ${song.meta.title}, retrying ($attempts/$maxAttempts)',
    );

    await Future.delayed(Duration(milliseconds: 700 * attempts));
    if (token != _playToken) {
      return true;
    }

    final retryToken = ++_playToken;
    await _loadAndPlaySong(index, retryToken);
    return true;
  }

  Future<void> _loadRecentlyPlayed() async {
    final items = await RecentlyPlayedCache.getAll();
    _recentlyPlayedSubject.add(items);
  }

  Future<void> _loadAndPlaySong(int index, int token) async {
    if (index < 0 || index >= _queue.length) {
      AppLogger.warning(
        'Invalid index: $index (queue length: ${_queue.length})',
      );
      return;
    }

    final song = _queue[index];

    if (token != _playToken) {
      AppLogger.info('Stale load request for index $index (token mismatch)');
      return;
    }

    final loadWatchdog = _startLoadWatchdog(
      song: song,
      index: index,
      token: token,
    );
    try {
      _currentIndex = index;
      _currentIndexSubject.add(index);
      _nowPlaying.add(song.meta);
      _trackLoading.add(true);

      await _player.stop();

      if (token != _playToken) return;

      final _ResolvedStream resolved;
      if (song.isLocal) {
        resolved = _ResolvedStream(url: song.id, headers: const {});
      } else {
        resolved = await _resolveUrl(song.id);
      }

      if (token != _playToken) return;

      final source = song.isLocal
          ? AudioSource.uri(Uri.file(resolved.url))
          : AudioSource.uri(
              Uri.parse(resolved.url),
              headers: {..._defaultStreamHeaders, ...resolved.headers},
            );

      await _player.setAudioSource(source).timeout(const Duration(seconds: 18));

      if (token != _playToken) return;

      _currentIndex = index;
      _currentIndexSubject.add(index);
      _nowPlaying.add(song.meta);

      if (token == _playToken) {
        _trackLoading.add(false);
      }
      unawaited(_player.play());

      await _addToRecentlyPlayed(song);
      _youtubeRetryCount.remove(song.id);
      _transientRetryCount.remove(song.id);
      unawaited(_prefetchNextIfNeeded());
      unawaited(_maybeExtendDynamicQueue());

      AppLogger.info(
        'Successfully loaded and playing: ${song.meta.title} (index: $index)',
      );
    } on PlayerException catch (e) {
      AppLogger.warning(
        'PlayerException at index $index: ${e.code} - ${e.message}',
        error: e,
      );

      final errText = '${e.code} ${e.message ?? ''} $e';
      if (song.id.startsWith('yt:') && errText.contains('403')) {
        final attempts = (_youtubeRetryCount[song.id] ?? 0) + 1;
        _youtubeRetryCount[song.id] = attempts;
        _removeCachedUrlsForSong(song.id);

        if (attempts <= 1) {
          AppLogger.warning(
            'YouTube 403 detected, retrying current track with fresh extraction (attempt $attempts)',
          );
          final retryToken = ++_playToken;
          await Future.delayed(const Duration(milliseconds: 400));
          await _loadAndPlaySong(index, retryToken);
          return;
        }

        _youtubeRetryCount.remove(song.id);
        _transientRetryCount.remove(song.id);
        AppLogger.warning('YouTube 403 persists after retries, skipping track');
        if (_currentIndex + 1 < _queue.length) {
          _showAutoSkipNotice();
          await Future.delayed(const Duration(milliseconds: 500));
          await skipNext();
        }
        return;
      }

      final lowerError = errText.toLowerCase();
      final retried = await _retryCurrentTrackIfTransient(
        song: song,
        index: index,
        token: token,
        errorText: lowerError,
      );
      if (retried) {
        return;
      }

      if (_currentIndex + 1 < _queue.length) {
        _showAutoSkipNotice();
        await Future.delayed(const Duration(milliseconds: 500));
        await skipNext();
      }
    } catch (e) {
      AppLogger.warning('Failed to load song at index $index: $e', error: e);

      final retried = await _retryCurrentTrackIfTransient(
        song: song,
        index: index,
        token: token,
        errorText: e.toString(),
      );
      if (retried) {
        return;
      }

      if (_currentIndex + 1 < _queue.length) {
        _showAutoSkipNotice();
        await Future.delayed(const Duration(milliseconds: 500));
        await skipNext();
      }
    } finally {
      if (token == _playToken) {
        _trackLoading.add(false);
      }
      loadWatchdog.cancel();
    }
  }

  Future<void> playFromList({
    required List<QueuedSong> songs,
    required int startIndex,
    bool autoExtendQueue = false,
  }) async {
    if (songs.isEmpty) {
      AppLogger.warning('Cannot play from empty list');
      return;
    }

    final int token = ++_playToken;

    final safeIndex = startIndex.clamp(0, songs.length - 1);

    AppLogger.info(
      'playFromList called: ${songs.length} songs, starting at index $safeIndex',
    );

    _queue = List.unmodifiable(songs);
    _autoQueueExtendEnabled = autoExtendQueue;
    _lastQueueExtendAttemptSongId = null;
    _lastQueueExtendAttemptAt = null;
    _queueExtendInFlight = null;
    _dynamicQueueSeenKeys.clear();
    for (final s in songs) {
      _rememberDynamicSeenKey(_songSimilarityKey(s.meta.title, s.meta.artist));
    }
    _prefetchedForIndex = null;
    _notifyQueueChanged();

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

    await playFromList(songs: queued, startIndex: 0);
  }

  Future<void> playNow(QueuedSong song) async {
    final int token = ++_playToken;

    AppLogger.info('playNow called: ${song.meta.title}');

    _queue = List.unmodifiable([song]);
    _autoQueueExtendEnabled = false;
    _lastQueueExtendAttemptSongId = null;
    _lastQueueExtendAttemptAt = null;
    _queueExtendInFlight = null;
    _dynamicQueueSeenKeys.clear();
    _rememberDynamicSeenKey(
      _songSimilarityKey(song.meta.title, song.meta.artist),
    );
    _prefetchedForIndex = null;
    _notifyQueueChanged();

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

  Future<void> playLocalFiles({
    required List<({String path, String name})> files,
    required int startIndex,
  }) async {
    if (files.isEmpty) {
      AppLogger.warning('Cannot play from empty local files list');
      return;
    }

    final queued = files.map((file) {
      return QueuedSong(
        id: file.path,
        isLocal: true,
        meta: NowPlaying(title: file.name, artist: 'Offline', imageUrl: ''),
      );
    }).toList();

    await playFromList(songs: queued, startIndex: startIndex);
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

  Future<void> skipNext() {
    final inFlight = _skipNextInFlight;
    if (inFlight != null) return inFlight;

    final future = _skipNextInternal();
    _skipNextInFlight = future;
    return future.whenComplete(() {
      if (identical(_skipNextInFlight, future)) {
        _skipNextInFlight = null;
      }
    });
  }

  Future<void> _skipNextInternal() async {
    if (_queue.isEmpty) return;

    var nextIndex = _currentIndex + 1;
    final remainingBeforeSkip = _queue.length - _currentIndex - 1;

    if (_autoQueueExtendEnabled && remainingBeforeSkip <= _upNextTargetCount) {
      unawaited(_maybeExtendDynamicQueue());
    }

    if (_autoQueueExtendEnabled && nextIndex >= _queue.length) {
      await _maybeExtendDynamicQueue(forceAtEnd: true);
      nextIndex = _currentIndex + 1;
    }

    if (nextIndex >= _queue.length) {
      if (_player.loopMode == LoopMode.all) {
        await jumpToIndex(0);
      } else {
        AppLogger.info('Reached end of queue');
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

    if (prevIndex < 0) {
      if (_player.loopMode == LoopMode.all) {
        await jumpToIndex(_queue.length - 1);
      } else {
        await _player.seek(Duration.zero);
      }
      return;
    }

    await jumpToIndex(prevIndex);
  }

  Future<bool> _maybeExtendDynamicQueue({bool forceAtEnd = false}) async {
    if (!_autoQueueExtendEnabled) return false;
    if (_queue.isEmpty) return false;
    if (_currentIndex < 0 || _currentIndex >= _queue.length) return false;

    final current = _queue[_currentIndex];
    if (current.isLocal) return false;

    await StreamingPreferences.load();
    if (!StreamingPreferences.useYoutube) return false;

    final remaining = _queue.length - _currentIndex - 1;

    if (!forceAtEnd && remaining >= _upNextTargetCount) return false;

    final now = DateTime.now();
    if (_lastQueueExtendAttemptSongId == current.id &&
        _lastQueueExtendAttemptAt != null &&
        now.difference(_lastQueueExtendAttemptAt!) <
            const Duration(seconds: 8)) {
      return false;
    }

    final inFlight = _queueExtendInFlight;
    if (inFlight != null) return inFlight;

    final future = _extendQueueFromCurrentSong(current, forceAtEnd: forceAtEnd);
    _queueExtendInFlight = future;
    return future.whenComplete(() {
      if (identical(_queueExtendInFlight, future)) {
        _queueExtendInFlight = null;
      }
    });
  }

  Future<bool> _extendQueueFromCurrentSong(
    QueuedSong current, {
    required bool forceAtEnd,
  }) async {
    _lastQueueExtendAttemptSongId = current.id;
    _lastQueueExtendAttemptAt = DateTime.now();

    const appendCount = 1;
    const candidateTake = 5;
    final query = '${current.meta.title} ${current.meta.artist}'.trim();
    if (query.isEmpty) return false;

    List<SaavnSong> candidates = const [];

    if (candidates.isEmpty && StreamingPreferences.useYoutube) {
      try {
        candidates = await YoutubeApi.searchSongs(query, take: candidateTake);
      } catch (_) {
        candidates = const [];
      }
    }

    if (candidates.isEmpty) return false;

    final existingIds = _queue.map((s) => s.id).toSet();
    final existingSimilarityKeys = <String>{
      ..._dynamicQueueSeenKeys,
      ..._queue.map((s) => _songSimilarityKey(s.meta.title, s.meta.artist)),
    };
    final recent = _recentlyPlayedSubject.valueOrNull ?? const [];
    for (final item in recent.take(60)) {
      final title = (item['title'] ?? '').toString();
      final artist = (item['artist'] ?? '').toString();
      if (title.trim().isEmpty) continue;
      existingSimilarityKeys.add(_songSimilarityKey(title, artist));
    }

    QueuedSong? addition;
    QueuedSong? lowQualityFallback;
    for (final song in candidates) {
      if (_isLowSignalCandidate(song.name, song.artists)) continue;
      if (existingIds.contains(song.id)) continue;
      final seedKey = _songSimilarityKey(song.name, song.artists);
      if (existingSimilarityKeys.contains(seedKey)) continue;

      final improved = await _improveDynamicQueueArtwork(song);
      if (_isLowSignalCandidate(improved.name, improved.artists)) continue;
      final improvedKey = _songSimilarityKey(improved.name, improved.artists);
      if (existingSimilarityKeys.contains(improvedKey)) continue;
      final queued = QueuedSong(
        id: improved.id,
        meta: NowPlaying(
          title: improved.name,
          artist: improved.artists,
          imageUrl: improved.imageUrl,
        ),
      );
      if (!YoutubeThumbnailUtils.isLikelyLowQualityArtwork(improved.imageUrl)) {
        addition = queued;
        break;
      }
      lowQualityFallback ??= queued;
    }

    addition ??= lowQualityFallback;
    if (addition == null) return false;

    _queue = List<QueuedSong>.from(_queue)..add(addition);
    _rememberDynamicSeenKey(
      _songSimilarityKey(addition.meta.title, addition.meta.artist),
    );
    _notifyQueueChanged();
    AppLogger.info('Added $appendCount song to dynamic queue');
    return true;
  }

  Future<SaavnSong> _improveDynamicQueueArtwork(SaavnSong song) async {
    if (!YoutubeThumbnailUtils.isLikelyLowQualityArtwork(song.imageUrl)) {
      return song;
    }

    try {
      final upgraded = await YoutubeApi.resolveSingleSongArtworkFallback(
        song,
      ).timeout(const Duration(seconds: 5));
      return upgraded;
    } catch (_) {
      return song;
    }
  }

  Future<void> jumpToIndex(int queueIndex) async {
    if (queueIndex < 0 || queueIndex >= _queue.length) {
      AppLogger.warning('Invalid jump index: $queueIndex');
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

  void _onPlayerStateChanged(PlayerState state) async {
    if (state.processingState == ProcessingState.completed) {
      if (_sleepEndOfCurrentSong) {
        clearSleepTimer(showMessage: false);
        unawaited(_stopFromSleepTimer(endOfCurrentSong: true));
        return;
      }
      if (_player.loopMode == LoopMode.one) {
        _player.seek(Duration.zero);
        _player.play();
      } else if (_player.loopMode == LoopMode.all ||
          _currentIndex + 1 < _queue.length) {
        skipNext();
      } else {
        final extended = await _maybeExtendDynamicQueue(forceAtEnd: true);
        if (extended && _currentIndex + 1 < _queue.length) {
          await skipNext();
          return;
        }
        AppLogger.info('Playback completed');
      }
    }
  }

  Future<void> _addToRecentlyPlayed(QueuedSong song) async {
    _rememberDynamicSeenKey(
      _songSimilarityKey(song.meta.title, song.meta.artist),
    );
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
    AppLogger.info('Stream cache cleared');
  }

  Future<void> clearRecentlyPlayed() async {
    await RecentlyPlayedCache.clear();
    _recentlyPlayedSubject.add([]);
  }

  Future<bool> removeSongFromQueue(String songId) async {
    final indexToRemove = _queue.indexWhere((song) => song.id == songId);
    if (indexToRemove == -1) return false;

    final wasCurrentSong = indexToRemove == _currentIndex;
    final newQueue = List<QueuedSong>.from(_queue);
    newQueue.removeAt(indexToRemove);

    if (newQueue.isEmpty) {
      await stopAndClearNowPlaying();
      return true;
    }

    _queue = List.unmodifiable(newQueue);
    _prefetchedForIndex = null;
    _notifyQueueChanged();

    int newIndex = _currentIndex;
    if (wasCurrentSong) {
      if (newIndex >= newQueue.length) {
        newIndex = newQueue.length - 1;
      }
      ++_playToken;
      await _player.stop();
      _trackLoading.add(false);

      if (newIndex >= 0 && newIndex < newQueue.length) {
        _currentIndex = newIndex;
        _currentIndexSubject.add(newIndex);
        final token = ++_playToken;
        await _loadAndPlaySong(newIndex, token);
      } else {
        _currentIndex = 0;
        _currentIndexSubject.add(null);
        _nowPlaying.add(null);
      }
    } else {
      if (indexToRemove < _currentIndex) {
        newIndex = _currentIndex - 1;
        _currentIndex = newIndex;
        _currentIndexSubject.add(newIndex);
      }
      _notifyQueueChanged();
    }

    return true;
  }

  Future<void> stopAndClearNowPlaying() async {
    clearSleepTimer(showMessage: false);
    ++_playToken;
    _queue = [];
    _autoQueueExtendEnabled = false;
    _notifyQueueChanged();
    _currentIndex = 0;
    _prefetchedForIndex = null;
    _queueExtendInFlight = null;
    _lastQueueExtendAttemptSongId = null;
    _lastQueueExtendAttemptAt = null;
    _dynamicQueueSeenKeys.clear();
    _skipNextInFlight = null;
    _youtubeRetryCount.clear();
    _transientRetryCount.clear();

    _currentIndexSubject.add(null);
    _nowPlaying.add(null);
    _trackLoading.add(false);

    await _player.stop();
  }

  Map<String, int> getStreamCacheStats() {
    final now = DateTime.now();
    int fresh = 0;
    int stale = 0;

    for (final entry in _urlCache.values) {
      final age = now.difference(entry.timestamp);
      final maxAge = entry.url.contains('youtube') ? 1 : 24;
      if (age.inHours < maxAge) {
        fresh++;
      } else {
        stale++;
      }
    }

    return {'total': _urlCache.length, 'fresh': fresh, 'stale': stale};
  }

  bool get isPlaying => _player.playing;

  Map<String, dynamic> getCacheStats() {
    final now = DateTime.now();
    int fresh = 0;
    int stale = 0;
    for (final entry in _urlCache.values) {
      final age = now.difference(entry.timestamp);
      final maxAge = entry.url.contains('youtube') ? 1 : 24;
      if (age.inHours < maxAge) {
        fresh++;
      } else {
        stale++;
      }
    }
    return {'total': _urlCache.length, 'fresh': fresh, 'stale': stale};
  }

  Future<void> dispose() async {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    await _playerStateSub?.cancel();
    await _positionSub?.cancel();
    await _player.dispose();
    await _nowPlaying.close();
    await _recentlyPlayedSubject.close();
    await _currentIndexSubject.close();
    await _queueVersion.close();
    await _trackLoading.close();
    await _sleepTimerSubject.close();
  }

  bool _isLowSignalCandidate(String title, String artist) {
    if (_containsBlockedUploadFormatting(title)) return true;
    final core = _songTitleCore(title, artist);
    if (core.isEmpty) return true;

    final tokens = core.split(' ').where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return true;
    if (tokens.length == 1 && tokens.first.length <= 3) return true;
    return false;
  }

  bool _containsBlockedUploadFormatting(String title) {
    final raw = title.trim();
    if (raw.isEmpty) return true;

    if (raw.contains('|')) return true;

    final dashSepCount = RegExp(
      r'\s(?:-|\u2013|\u2014)\s',
    ).allMatches(raw).length;
    if (dashSepCount >= 2) return true;

    return false;
  }

  void _rememberDynamicSeenKey(String key) {
    if (key.trim().isEmpty) return;
    _dynamicQueueSeenKeys.add(key);
    if (_dynamicQueueSeenKeys.length <= _maxDynamicSeenKeys) return;

    final overflow = _dynamicQueueSeenKeys.length - _maxDynamicSeenKeys;
    for (var i = 0; i < overflow; i++) {
      if (_dynamicQueueSeenKeys.isEmpty) break;
      _dynamicQueueSeenKeys.remove(_dynamicQueueSeenKeys.first);
    }
  }

  String _normalizeText(String input) {
    var value = input.toLowerCase();
    value = value.replaceAll(RegExp(r'[\u2013\u2014\-|_/]+'), ' ');
    value = value.replaceAll(RegExp(r'[\(\)\[\]\{\}]'), ' ');
    value = value.replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ');
    value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return value;
  }

  String _normalizeArtistCore(String artist) {
    var primary = artist.split(RegExp(r',|&|/|;|\|')).first;
    primary = primary.replaceAll(
      RegExp(r'\b(ft|feat|featuring)\b.*', caseSensitive: false),
      ' ',
    );
    return _normalizeText(primary);
  }

  String _songTitleCore(String title, String artist) {
    const noiseTokens = <String>{
      'new',
      'song',
      'songs',
      'official',
      'video',
      'audio',
      'lyric',
      'lyrics',
      'full',
      'hd',
      'hq',
      'latest',
      'trending',
      'music',
      'track',
      'version',
      'mix',
      'edit',
      'release',
    };

    final artistCore = _normalizeArtistCore(artist);
    final artistTokens = artistCore
        .split(' ')
        .where((t) => t.length > 1)
        .toSet();
    String workingTitle = title;
    final splitParts = title
        .split(RegExp(r'\s*(?:\||-|\u2013|\u2014)\s*'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    if (splitParts.length > 1) {
      String bestPart = splitParts.first;
      var bestScore = -1;
      for (final part in splitParts) {
        final tokens = _normalizeText(
          part,
        ).split(' ').where((t) => t.length > 1).toList(growable: false);
        final informative = tokens
            .where(
              (t) =>
                  !artistTokens.contains(t) &&
                  !noiseTokens.contains(t) &&
                  t.length > 2,
            )
            .length;
        if (informative > bestScore) {
          bestScore = informative;
          bestPart = part;
        }
      }
      workingTitle = bestPart;
    }

    final titleTokens = _normalizeText(
      workingTitle,
    ).split(' ').where((t) => t.length > 1).toList(growable: false);

    final filtered = <String>[];
    for (final token in titleTokens) {
      if (artistTokens.contains(token)) continue;
      if (noiseTokens.contains(token)) continue;
      filtered.add(token);
    }

    if (filtered.isNotEmpty) {
      return filtered.join(' ');
    }

    final fallback = titleTokens
        .where((t) => !artistTokens.contains(t))
        .toList(growable: false);
    if (fallback.isNotEmpty) return fallback.join(' ');

    return _normalizeText(title);
  }

  String _songSimilarityKey(String title, String artist) {
    final normalizedTitle = _songTitleCore(title, artist);
    final normalizedArtist = _normalizeArtistCore(artist);
    return '$normalizedTitle|$normalizedArtist';
  }
}

class _CachedUrl {
  final String url;
  final Map<String, String>? headers;
  final DateTime timestamp;

  _CachedUrl({required this.url, this.headers, required this.timestamp});
}

class _ResolvedStream {
  final String url;
  final Map<String, String> headers;

  const _ResolvedStream({required this.url, this.headers = const {}});
}

class SleepTimerStatus {
  final DateTime? endsAt;
  final bool endOfCurrentSong;

  const SleepTimerStatus._({this.endsAt, required this.endOfCurrentSong});
  const SleepTimerStatus.off() : this._(endOfCurrentSong: false);
  const SleepTimerStatus.endOfCurrentSong() : this._(endOfCurrentSong: true);
  const SleepTimerStatus.until({required DateTime endsAt})
    : this._(endsAt: endsAt, endOfCurrentSong: false);

  bool get isActive => endOfCurrentSong || endsAt != null;
}
