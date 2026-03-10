import 'dart:async';
import 'dart:convert';
import 'dart:math';
// import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../../core/utils/presence_bridge.dart';
import '../../../core/utils/app_logger.dart';
import 'discord_token_manager.dart';

/// Experimental Discord Rich Presence adapter for Hongeet
///
/// Uses Discord's headless-sessions API with a PKCE OAuth bearer token
///
/// ⚠️  Uses unofficial endpoints. Breakage risk is real, very real LMAO
class DiscordRpcAdapter implements PresenceAdapter {
  static const _clientId = '503557087041683458';
  static const _redirectUri = 'https://login.premid.app';
  static const _tag = '[DiscordRPC]';
  static const _debounce = Duration(seconds: 2);
  static const _maxArtCache = 100;
  static const _maxArtBytes = 10 * 1024 * 1024;
  String? _bearerToken;
  DateTime? _bearerExpiry;
  Future<String?>? _bearerInFlight;
  String? _sessionToken;
  bool _disposed = false;
  bool _cleared = false;
  Timer? _debounceTimer;
  NowPlayingState? _pendingState;
  Future<void>? _pushInFlight;
  final Map<String, String> _artCache = {};
  final Map<String, Future<String?>> _artInFlight = {};

  @override
  Future<void> onStateChanged(NowPlayingState state) async {
    if (_disposed) return;
    _cleared = false;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
      if (!_cleared && !_disposed) _push(state);
    });
  }

  @override
  Future<void> onCleared() async {
    if (_disposed) return;
    _cleared = true;
    _debounceTimer?.cancel();
    _pendingState = null;
    await _pushInFlight;
    await _deleteSession();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _debounceTimer?.cancel();
    await _pushInFlight;
    await _deleteSession();
  }

  Future<String?> _getBearerToken() async {
    if (_bearerToken != null &&
        _bearerExpiry != null &&
        DateTime.now().isBefore(_bearerExpiry!)) {
      return _bearerToken;
    }
    _bearerToken = null;
    _bearerInFlight ??= _doBearerFlow();
    try {
      return await _bearerInFlight;
    } finally {
      _bearerInFlight = null;
    }
  }

  Future<String?> _doBearerFlow() async {
    final userToken = await DiscordTokenManager.getUserToken();
    if (userToken == null) {
      debugPrint('$_tag No user token');
      return null;
    }
    try {
      final verifier = _randomString(128);
      final challenge = _pkceChallenge(verifier);
      final authRes = await http
          .post(
            Uri.parse(
              'https://discord.com/api/v9/oauth2/authorize'
              '?client_id=$_clientId'
              '&response_type=code'
              '&redirect_uri=${Uri.encodeComponent(_redirectUri)}'
              '&code_challenge=$challenge'
              '&code_challenge_method=S256'
              '&scope=identify%20activities.write'
              '&state=undefined',
            ),
            headers: {
              'Authorization': userToken,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'authorize': true}),
          )
          .timeout(const Duration(seconds: 10));
      debugPrint('$_tag OAuth authorize ${authRes.statusCode}');
      if (authRes.statusCode == 401 || authRes.statusCode == 403) {
        debugPrint('$_tag Invalid credentials -> clearing token');
        await DiscordTokenManager.clearAll();
        return null;
      }
      if (authRes.statusCode != 200) {
        debugPrint(
          '$_tag OAuth authorize failed (transient): HTTP ${authRes.statusCode}',
        );
        return null;
      }
      final location =
          (jsonDecode(authRes.body) as Map<String, dynamic>)['location']
              as String?;
      final code = location != null
          ? Uri.parse(location).queryParameters['code']
          : null;
      if (code == null) {
        debugPrint('$_tag No code in location: $location');
        return null;
      }
      final tokenRes = await http
          .post(
            Uri.parse('https://discord.com/api/v10/oauth2/token'),
            body: {
              'client_id': _clientId,
              'code': code,
              'code_verifier': verifier,
              'grant_type': 'authorization_code',
              'redirect_uri': _redirectUri,
            },
          )
          .timeout(const Duration(seconds: 10));
      debugPrint('$_tag Token exchange ${tokenRes.statusCode}');
      if (tokenRes.statusCode != 200) return null;
      final body = jsonDecode(tokenRes.body) as Map<String, dynamic>;
      _bearerToken = body['access_token'] as String?;
      final expiresIn = body['expires_in'] as int? ?? 604800;
      _bearerExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));
      debugPrint('$_tag Bearer obtained (expires in ${expiresIn}s)');
      return _bearerToken;
    } catch (e) {
      debugPrint('$_tag OAuth error: $e');
      AppLogger.warning('$_tag OAuth error: $e', error: e);
      return null;
    }
  }

  static const _chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  String _randomString([int len = 128]) {
    final rng = Random.secure();
    return List.generate(len, (_) => _chars[rng.nextInt(_chars.length)]).join();
  }

  String _pkceChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url
        .encode(Uint8List.fromList(digest.bytes))
        .replaceAll('=', '');
  }

  Future<void> _push(NowPlayingState state) async {
    if (_disposed || _cleared) return;
    if (_pushInFlight != null) {
      _pendingState = state;
      return;
    }
    _pendingState = null;
    final current = _doPush(state);
    _pushInFlight = current;
    await current;
    if (identical(_pushInFlight, current)) {
      _pushInFlight = null;
      final pending = _pendingState;
      if (pending != null && !_cleared) {
        _pendingState = null;
        unawaited(_push(pending));
      }
    }
  }

  Future<void> _doPush(NowPlayingState state) async {
    if (_disposed || _cleared) return;
    debugPrint('$_tag push: ${state.title} -> ${state.artist}');
    try {
      final bearer = await _getBearerToken();
      if (bearer == null || _disposed || _cleared) return;
      final artUrl = await _resolveArtUrl(state.imageUrl);
      if (_disposed || _cleared) return;
      await _postSession(bearer, _buildPayload(state, artUrl));
    } catch (e) {
      debugPrint('$_tag push error: $e');
    }
  }

  Map<String, dynamic> _buildPayload(NowPlayingState state, String? artUrl) => {
    'activities': [
      {
        'application_id': _clientId,
        'platform': 'desktop',
        'type': 2,
        'name': 'Hongeet',
        'details': state.title,
        'state': state.artist,
        'assets': {
          if (artUrl != null) 'large_image': artUrl,
          // 'large_text': state.isPlaying ? 'Playing' : 'Paused',
          'small_image': state.isPlaying
              ? 'https://files.catbox.moe/t5lvej.png'
              : 'https://files.catbox.moe/y5fb9p.png',
          'small_text': state.isPlaying ? 'Hongeet' : 'Paused',
        },
        'buttons': [
          {'label': 'Listen on Hongeet', 'url': 'https://greenbugx.github.io'},
          {
            'label': 'View Hongeet on GitHub',
            'url': 'https://github.com/greenbugx/Hongeet',
          },
        ],
        if (state.isPlaying) 'timestamps': _buildTimestamps(state),
      },
    ],
  };
  Map<String, dynamic> _buildTimestamps(NowPlayingState state) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final start = now - state.position.inMilliseconds;
    final end = state.duration != null
        ? start + state.duration!.inMilliseconds
        : null;
    return {'start': start, if (end != null) 'end': end};
  }

  Future<void> _postSession(String bearer, Map<String, dynamic> payload) async {
    await _deleteSession();
    if (_disposed || _cleared) return;
    final response = await http
        .post(
          Uri.parse('https://discord.com/api/v10/users/@me/headless-sessions'),
          headers: {
            'Authorization': 'Bearer $bearer',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 10));
    debugPrint('$_tag Session HTTP ${response.statusCode}: ${response.body}');
    if (_disposed || _cleared) return;
    if (response.statusCode == 200 || response.statusCode == 201) {
      _sessionToken =
          (jsonDecode(response.body) as Map<String, dynamic>)['token']
              as String?;
      debugPrint('$_tag Presence set');
    } else if (response.statusCode == 401) {
      _bearerToken = null;
      _sessionToken = null;
      debugPrint('$_tag 401 -> retrying with fresh bearer');
      final newBearer = await _getBearerToken();
      if (newBearer == null || _disposed || _cleared) return;
      final retry = await http
          .post(
            Uri.parse(
              'https://discord.com/api/v10/users/@me/headless-sessions',
            ),
            headers: {
              'Authorization': 'Bearer $newBearer',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));
      debugPrint('$_tag Session retry HTTP ${retry.statusCode}');
      if (_disposed || _cleared) return;
      if (retry.statusCode == 200 || retry.statusCode == 201) {
        _sessionToken =
            (jsonDecode(retry.body) as Map<String, dynamic>)['token']
                as String?;
        debugPrint('$_tag Presence set (retry)');
      }
    } else if (response.statusCode == 429) {
      final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
      debugPrint('$_tag Rate limited -> retry-after: ${retryAfter}s');
      if (retryAfter != null && retryAfter <= 10 && !_disposed && !_cleared) {
        await Future.delayed(Duration(seconds: retryAfter));
        if (_disposed || _cleared) return; // already existed
        final retry = await http
            .post(
              Uri.parse(
                'https://discord.com/api/v10/users/@me/headless-sessions',
              ),
              headers: {
                'Authorization': 'Bearer $bearer',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 10));
        if (_disposed || _cleared) return;
        if (retry.statusCode == 200 || retry.statusCode == 201) {
          _sessionToken =
              (jsonDecode(retry.body) as Map<String, dynamic>)['token']
                  as String?;
          debugPrint('$_tag Presence set (after rate limit)');
        }
      }
    }
  }

  Future<void> _deleteSession() async {
    final bearer = _bearerToken;
    final session = _sessionToken;
    if (bearer == null || session == null) return;
    // don't null out token before HTTP call
    try {
      debugPrint('$_tag Deleting session...');
      final res = await http
          .post(
            Uri.parse(
              'https://discord.com/api/v10/users/@me/headless-sessions/delete',
            ),
            headers: {
              'Authorization': 'Bearer $bearer',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'token': session}),
          )
          .timeout(const Duration(seconds: 5));
      debugPrint('$_tag Delete session HTTP ${res.statusCode}');
      _sessionToken = null; // clear after success
    } catch (e) {
      debugPrint('$_tag Delete session error: $e');
      // Keep _sessionToken so a future call can retry
    }
  }

  Future<String?> _resolveArtUrl(String imageUrl) async {
    if (imageUrl.isEmpty) return null;
    // promote to most-recent on hit for true LRU
    if (_artCache.containsKey(imageUrl)) {
      debugPrint('$_tag Art cache hit');
      final cached = _artCache.remove(imageUrl)!;
      _artCache[imageUrl] = cached;
      return cached;
    }
    if (_artInFlight.containsKey(imageUrl)) {
      debugPrint('$_tag Art in-flight');
      return _artInFlight[imageUrl];
    }
    final future = _uploadArt(imageUrl);
    _artInFlight[imageUrl] = future;
    try {
      final result = await future;
      if (result != null) {
        if (_artCache.length >= _maxArtCache) {
          _artCache.remove(_artCache.keys.first);
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
      // stream + size-limit the download
      final request = http.Request('GET', Uri.parse(sourceUrl));
      final streamedRes = await http.Client()
          .send(request)
          .timeout(const Duration(seconds: 10));
      final contentLength = streamedRes.contentLength ?? 0;
      if (streamedRes.statusCode != 200 || contentLength > _maxArtBytes) {
        streamedRes.stream.drain();
        return null;
      }
      // single access to bytes
      final bytes = await streamedRes.stream.toBytes().timeout(
        const Duration(seconds: 15),
      );
      if (bytes.length < 1024 || bytes.length > _maxArtBytes) {
        debugPrint('$_tag Art size out of range (${bytes.length}B), skipping');
        return null;
      }
      final first = await _tryLitterbox(bytes);
      if (first != null) return first;
      final completer = Completer<String?>();
      var pending = 2;
      void onResult(String? url) {
        if (url != null && !completer.isCompleted) {
          completer.complete(url);
        } else if (--pending == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }

      _tryCatbox(bytes).then(onResult);
      _tryUguu(bytes).then(onResult);
      return await completer.future;
    } catch (e) {
      debugPrint('$_tag Art upload error: $e');
      return null;
    }
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
      final streamed = await req.send().timeout(const Duration(seconds: 15));
      final res = await http.Response.fromStream(streamed);
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
      final streamed = await req.send().timeout(const Duration(seconds: 15));
      final res = await http.Response.fromStream(streamed);
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
      final streamed = await req.send().timeout(const Duration(seconds: 15));
      final res = await http.Response.fromStream(streamed);
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
