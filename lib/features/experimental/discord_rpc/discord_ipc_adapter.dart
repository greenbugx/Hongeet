import 'dart:async';
import 'dart:convert';

import 'package:dart_discord_presence/dart_discord_presence.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/utils/presence_bridge.dart';

/// Windows Discord Rich Presence adapter backed by [dart_discord_presence].
///
/// Connects to the local Discord client over IPC
class DiscordIpcAdapter implements PresenceAdapter {
  static const _clientId = '1482120624909324471';
  static const _tag = '[DiscordIPC]';
  static const _debounce = Duration(seconds: 2);
  static const _reconnectDelay = Duration(seconds: 5);
  static const _maxArtCache = 50;
  static const _maxArtBytes = 10 * 1024 * 1024; // 10 MB

  late final DiscordRPC _rpc;

  bool _ready = false;
  bool _disposed = false;
  bool _cleared = false;
  bool _initializing = false;

  Timer? _debounceTimer;
  Timer? _reconnectTimer;
  NowPlayingState? _lastState;

  StreamSubscription<DiscordReadyEvent>? _readySub;
  StreamSubscription<DiscordDisconnectedEvent>? _disconnectSub;
  StreamSubscription<DiscordErrorEvent>? _errorSub;

  final Map<String, String> _artCache = {};
  final Map<String, Future<String?>> _artInFlight = {};

  DiscordIpcAdapter() {
    _rpc = DiscordRPC();
    unawaited(_init());
  }

  Future<void> _init() async {
    if (_disposed || _initializing) return;
    _initializing = true;

    if (!DiscordRPC.isAvailable) {
      debugPrint('$_tag Platform not supported by dart_discord_presence');
      _initializing = false;
      return;
    }

    _readySub ??= _rpc.onReady.listen((event) {
      debugPrint('$_tag READY — ${event.user.username}');
      _ready = true;
      final state = _lastState;
      if (state != null && !_cleared) unawaited(_push(state));
    });

    _disconnectSub ??= _rpc.onDisconnected.listen((event) {
      debugPrint(
        '$_tag Disconnected: ${event.message} (code: ${event.errorCode})',
      );
      _ready = false;
      if (!_disposed) _scheduleReconnect();
    });

    _errorSub ??= _rpc.onError.listen((event) {
      debugPrint(
        '$_tag RPC error: ${event.message} (code: ${event.errorCode})',
      );
    });

    try {
      await _rpc.initialize(_clientId);
      debugPrint('$_tag initialize() done — waiting for READY');
    } on DiscordNotRunningException {
      debugPrint('$_tag Discord not running — retry in $_reconnectDelay');
      _scheduleReconnect();
    } on DiscordConnectionException catch (e) {
      debugPrint(
        '$_tag Connection failed: ${e.message} — retry in $_reconnectDelay',
      );
      _scheduleReconnect();
    } catch (e) {
      debugPrint('$_tag Unexpected init error: $e');
      _scheduleReconnect();
    } finally {
      _initializing = false;
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, () {
      if (!_disposed && !_ready && !_initializing) unawaited(_init());
    });
  }

  @override
  Future<void> onStateChanged(NowPlayingState state) async {
    if (_disposed) return;
    _cleared = false;
    _lastState = state;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
      if (!_cleared && !_disposed) unawaited(_push(state));
    });
    if (!_ready && !_initializing) unawaited(_init());
  }

  @override
  Future<void> onCleared() async {
    if (_disposed) return;
    _cleared = true;
    _lastState = null;
    _debounceTimer?.cancel();
    if (_ready) {
      try {
        await _rpc.clearPresence();
        debugPrint('$_tag Activity cleared');
      } catch (e) {
        debugPrint('$_tag Clear error: $e');
      }
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _debounceTimer?.cancel();
    _reconnectTimer?.cancel();
    await _readySub?.cancel();
    await _disconnectSub?.cancel();
    await _errorSub?.cancel();
    _readySub = null;
    _disconnectSub = null;
    _errorSub = null;
    try {
      await _rpc.dispose();
    } catch (_) {}
  }

  Future<void> _push(NowPlayingState state) async {
    if (_disposed || _cleared || !_ready) return;
    debugPrint('$_tag push: ${state.title} — ${state.artist}');
    try {
      final artUrl = await _resolveArtUrl(state.imageUrl);
      if (_disposed || _cleared || !_ready) return;

      final now = DateTime.now();
      final start = now.subtract(state.position);
      final end = state.duration != null ? start.add(state.duration!) : null;

      await _rpc.setPresence(
        DiscordPresence(
          type: DiscordActivityType.listening,
          details: state.title,
          state: state.artist,
          statusDisplayType: DiscordStatusDisplayType.details,
          largeAsset: artUrl != null ? DiscordAsset.fromUrl(artUrl) : null,
          smallAsset: DiscordAsset.fromKey(
            state.isPlaying ? 'playing' : 'paused',
            text: state.isPlaying ? 'Playing' : 'Paused',
          ),
          timestamps: state.isPlaying
              ? (end != null
                    ? DiscordTimestamps.range(start, end) // progress bar
                    : DiscordTimestamps.started(start)) // elapsed time
              : null,
          buttons: [
            DiscordButton(
              label: 'Listen on Hongeet',
              url: 'https://greenbugx.github.io',
            ),
            DiscordButton(
              label: 'View on GitHub',
              url: 'https://github.com/greenbugx/Hongeet',
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('$_tag Push error: $e');
    }
  }

  Future<String?> _resolveArtUrl(String imageUrl) async {
    if (imageUrl.isEmpty) return null;

    if (_artCache.containsKey(imageUrl)) {
      final cached = _artCache.remove(imageUrl)!;
      _artCache[imageUrl] = cached;
      return cached;
    }

    if (_artInFlight.containsKey(imageUrl)) return _artInFlight[imageUrl];

    final future = _uploadArt(imageUrl);
    _artInFlight[imageUrl] = future;
    try {
      final result = await future;
      if (result != null) {
        if (_artCache.length >= _maxArtCache) {
          _artCache.remove(_artCache.keys.first); // evict oldest
        }
        _artCache[imageUrl] = result;
      }
      return result;
    } finally {
      _artInFlight.remove(imageUrl);
    }
  }

  Future<String?> _uploadArt(String sourceUrl) async {
    try {
      final request = http.Request('GET', Uri.parse(sourceUrl));
      final streamed = await http.Client()
          .send(request)
          .timeout(const Duration(seconds: 10));

      if (streamed.statusCode != 200) {
        await streamed.stream.drain<void>();
        return null;
      }

      final bytes = await streamed.stream.toBytes().timeout(
        const Duration(seconds: 15),
      );

      if (bytes.length < 1024 || bytes.length > _maxArtBytes) {
        debugPrint('$_tag Art size out of range (${bytes.length} B) — skip');
        return null;
      }

      return await _raceUploads(bytes);
    } catch (e) {
      debugPrint('$_tag Art upload error: $e');
      return null;
    }
  }

  Future<String?> _raceUploads(List<int> bytes) async {
    final litterbox = await _tryLitterbox(bytes).timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        debugPrint('$_tag litterbox timed out — falling back');
        return null;
      },
    );
    if (litterbox != null) return litterbox;

    debugPrint('$_tag litterbox failed — racing catbox + uguu');
    final completer = Completer<String?>();
    var pending = 2;

    void onResult(String? url) {
      if (url != null && !completer.isCompleted) {
        completer.complete(url);
      } else if (--pending == 0 && !completer.isCompleted) {
        completer.complete(null); // both failed
      }
    }

    _tryCatbox(bytes).then(onResult);
    _tryUguu(bytes).then(onResult);

    return completer.future;
  }

  Future<String?> _tryLitterbox(List<int> bytes) async {
    try {
      final req =
          http.MultipartRequest(
              'POST',
              Uri.parse(
                'https://litterbox.catbox.moe/resources/internals/api.php',
              ),
            )
            ..fields['reqtype'] = 'fileupload'
            ..fields['time'] = '1h'
            ..files.add(
              http.MultipartFile.fromBytes(
                'fileToUpload',
                bytes,
                filename: 'art.jpg',
              ),
            );

      final res = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 15)),
      );
      final body = res.body.trim();
      debugPrint('$_tag litterbox HTTP ${res.statusCode}: $body');
      if (res.statusCode == 200 && body.startsWith('https://')) return body;
    } catch (e) {
      debugPrint('$_tag litterbox error: $e');
    }
    return null;
  }

  Future<String?> _tryCatbox(List<int> bytes) async {
    try {
      final req =
          http.MultipartRequest(
              'POST',
              Uri.parse('https://catbox.moe/user/api.php'),
            )
            ..fields['reqtype'] = 'fileupload'
            ..files.add(
              http.MultipartFile.fromBytes(
                'fileToUpload',
                bytes,
                filename: 'art.jpg',
              ),
            );

      final res = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 15)),
      );
      final body = res.body.trim();
      debugPrint('$_tag catbox HTTP ${res.statusCode}: $body');
      if (res.statusCode == 200 && body.startsWith('https://')) return body;
    } catch (e) {
      debugPrint('$_tag catbox error: $e');
    }
    return null;
  }

  Future<String?> _tryUguu(List<int> bytes) async {
    try {
      final req =
          http.MultipartRequest('POST', Uri.parse('https://uguu.se/upload'))
            ..files.add(
              http.MultipartFile.fromBytes(
                'files[]',
                bytes,
                filename: 'art.jpg',
              ),
            );

      final res = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 15)),
      );
      final body = res.body.trim();
      debugPrint('$_tag uguu HTTP ${res.statusCode}: $body');
      if (res.statusCode == 200) {
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) {
            final files = decoded['files'];
            if (files is List && files.isNotEmpty) {
              final first = files.first;
              if (first is Map<String, dynamic>) {
                final url = first['url'] as String?;
                if (url != null && url.startsWith('https://')) return url;
              }
            }
          }
        } catch (_) {
          debugPrint('$_tag uguu unexpected body: $body');
        }
      }
    } catch (e) {
      debugPrint('$_tag uguu error: $e');
    }
    return null;
  }
}
