import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class LyricLine {
  final Duration start;
  final String text;

  const LyricLine({required this.start, required this.text});
}

class LrcLibLyrics {
  final String trackName;
  final String artistName;
  final String albumName;
  final int? durationSeconds;
  final bool instrumental;
  final String plainLyrics;
  final String? syncedLyrics;
  final List<LyricLine> parsedLines;

  const LrcLibLyrics({
    required this.trackName,
    required this.artistName,
    required this.albumName,
    required this.durationSeconds,
    required this.instrumental,
    required this.plainLyrics,
    required this.syncedLyrics,
    required this.parsedLines,
  });

  bool get hasSyncedLyrics => parsedLines.isNotEmpty;
}

class LrcLibApi {
  static const Duration _timeout = Duration(seconds: 9);
  static const Duration _cacheTtl = Duration(hours: 12);
  static const String _host = 'lrclib.net';

  static final Map<String, _CachedLyrics> _cache = {};
  static final Map<String, Future<LrcLibLyrics?>> _inFlight = {};

  static Future<LrcLibLyrics?> fetchBestLyrics({
    required String title,
    required String artist,
    int? durationSeconds,
    String? album,
  }) async {
    if (title.trim().isEmpty) return null;

    final key = '${title.trim().toLowerCase()}|${artist.trim().toLowerCase()}';

    final cached = _cache[key];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) < _cacheTtl) {
      return cached.lyrics;
    }

    final existing = _inFlight[key];
    if (existing != null) return existing;

    final request = _fetchBestLyricsUncached(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
      album: album,
    );

    _inFlight[key] = request;
    try {
      final result = await request;
      _cache[key] = _CachedLyrics(lyrics: result, cachedAt: DateTime.now());
      if (_cache.length > 300) _trimCache();
      return result;
    } finally {
      if (identical(_inFlight[key], request)) _inFlight.remove(key);
    }
  }

  static Future<LrcLibLyrics?> _fetchBestLyricsUncached({
    required String title,
    required String artist,
    int? durationSeconds,
    String? album,
  }) async {
    final cleanedArtist = _cleanArtistForQuery(artist);
    final cleanedAlbum = (album ?? '').trim();

    final variants = _titleVariants(title);

    final seenIds = <String>{};
    final candidates = <Map<String, dynamic>>[];

    for (final variant in variants) {
      if (variant.isEmpty) continue;

      final exact = await _tryGet(
        title: variant,
        artist: cleanedArtist,
        durationSeconds: durationSeconds,
        album: cleanedAlbum.isEmpty ? null : cleanedAlbum,
      );
      if (exact != null) {
        final id = exact['id']?.toString() ?? '';
        if (id.isEmpty || seenIds.add(id)) candidates.add(exact);
      }

      final results = await _trySearch(
        title: variant,
        artist: cleanedArtist,
        album: cleanedAlbum,
      );
      for (final r in results) {
        final id = r['id']?.toString() ?? '';
        if (id.isEmpty || seenIds.add(id)) candidates.add(r);
      }

      if (candidates.isNotEmpty) break;
    }

    if (candidates.isEmpty) {
      final broadResults = await _trySearchBroad(
        title: variants.first,
        artist: cleanedArtist,
      );
      for (final r in broadResults) {
        final id = r['id']?.toString() ?? '';
        if (id.isEmpty || seenIds.add(id)) candidates.add(r);
      }
    }

    if (candidates.isEmpty) return null;

    final scoringTitle = _normalizeForScoring(title);
    final scoringArtist = _normalizeForScoring(cleanedArtist);

    Map<String, dynamic>? best;
    var bestScore = -1 << 30;
    for (final item in candidates) {
      final score = _candidateScore(
        item: item,
        normalizedTitle: scoringTitle,
        normalizedArtist: scoringArtist,
        durationSeconds: durationSeconds,
      );
      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }

    if (best == null) return null;
    return _parseLyrics(best);
  }

  static List<String> _titleVariants(String title) {
    final variants = <String>[];
    final full = title.trim();

    variants.add(full);

    final lightCleaned = full
        .replaceAll(
          RegExp(
            r'\[(official\s*(video|audio|mv|lyric)?|lyrics?|audio|video)\]',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (lightCleaned != full && lightCleaned.isNotEmpty) {
      variants.add(lightCleaned);
    }

    final hasNonLatin = full.contains(RegExp(r'[^\x00-\x7F]'));
    if (hasNonLatin) {
      final nonLatinPart = full
          .replaceAll(RegExp(r'[\x00-\x7F]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (nonLatinPart.isNotEmpty && !variants.contains(nonLatinPart)) {
        variants.add(nonLatinPart);
      }

      final latinPart = full
          .replaceAll(RegExp(r'[^\x00-\x7F]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (latinPart.isNotEmpty && !variants.contains(latinPart)) {
        variants.add(latinPart);
      }
    }

    final aggressiveCleaned = _cleanTitleForQuery(full);
    final aggressiveLatin = aggressiveCleaned
        .replaceAll(RegExp(r'[^\x00-\x7F]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (aggressiveLatin.isNotEmpty && !variants.contains(aggressiveLatin)) {
      variants.add(aggressiveLatin);
    }

    return variants.where((v) => v.isNotEmpty).toList();
  }

  static Future<Map<String, dynamic>?> _tryGet({
    required String title,
    required String artist,
    int? durationSeconds,
    String? album,
  }) async {
    final uri = Uri.https(_host, '/api/get', <String, String>{
      'track_name': title,
      'artist_name': artist,
      if (album != null && album.trim().isNotEmpty) 'album_name': album.trim(),
      if (durationSeconds != null && durationSeconds > 0)
        'duration': durationSeconds.toString(),
    });

    try {
      final response = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      final body = _decodeJsonBody(response.bodyBytes);
      if (body is Map<String, dynamic>) return body;
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> _trySearch({
    required String title,
    required String artist,
    required String album,
  }) async {
    final query = '$title $artist ${album.trim()}'.trim();
    final uri = Uri.https(_host, '/api/search', <String, String>{
      'q': query,
      'track_name': title,
      'artist_name': artist,
      if (album.trim().isNotEmpty) 'album_name': album.trim(),
    });

    try {
      final response = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(_timeout);
      if (response.statusCode != 200) return const [];
      final body = _decodeJsonBody(response.bodyBytes);
      if (body is! List) return const [];
      return body.whereType<Map<String, dynamic>>().toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<List<Map<String, dynamic>>> _trySearchBroad({
    required String title,
    required String artist,
  }) async {
    final query = '$title $artist'.trim();
    final uri = Uri.https(_host, '/api/search', <String, String>{'q': query});

    try {
      final response = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(_timeout);
      if (response.statusCode != 200) return const [];
      final body = _decodeJsonBody(response.bodyBytes);
      if (body is! List) return const [];
      return body.whereType<Map<String, dynamic>>().toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static LrcLibLyrics _parseLyrics(Map<String, dynamic> raw) {
    final plainLyrics = (raw['plainLyrics'] ?? '').toString();
    final syncedLyrics = (raw['syncedLyrics'] ?? '').toString().trim();
    final parsed = _parseSyncedLyrics(
      syncedLyrics.isEmpty ? null : syncedLyrics,
    );
    return LrcLibLyrics(
      trackName: (raw['trackName'] ?? '').toString().trim(),
      artistName: (raw['artistName'] ?? '').toString().trim(),
      albumName: (raw['albumName'] ?? '').toString().trim(),
      durationSeconds: _asInt(raw['duration']),
      instrumental: raw['instrumental'] == true,
      plainLyrics: plainLyrics,
      syncedLyrics: syncedLyrics.isEmpty ? null : syncedLyrics,
      parsedLines: parsed,
    );
  }

  static List<LyricLine> _parseSyncedLyrics(String? syncedLyrics) {
    if (syncedLyrics == null || syncedLyrics.trim().isEmpty) return const [];

    final timestampRegex = RegExp(r'\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]');
    final lines = <LyricLine>[];

    for (final raw in syncedLyrics.split('\n')) {
      final matches = timestampRegex.allMatches(raw).toList(growable: false);
      if (matches.isEmpty) continue;

      final text = raw.replaceAll(timestampRegex, '').trim();
      if (text.isEmpty) continue;

      for (final match in matches) {
        final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
        final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
        final fractionRaw = match.group(3) ?? '0';
        final milliseconds = _fractionToMilliseconds(fractionRaw);
        lines.add(
          LyricLine(
            start: Duration(
              minutes: minutes,
              seconds: seconds,
              milliseconds: milliseconds,
            ),
            text: text,
          ),
        );
      }
    }

    if (lines.isEmpty) return const [];
    lines.sort((a, b) => a.start.compareTo(b.start));

    final seen = <String>{};
    final deduped = <LyricLine>[];
    for (final line in lines) {
      final sig =
          '${line.start.inMilliseconds}|${line.text.toLowerCase().trim()}';
      if (seen.add(sig)) deduped.add(line);
    }
    return deduped;
  }

  static int _candidateScore({
    required Map<String, dynamic> item,
    required String normalizedTitle,
    required String normalizedArtist,
    required int? durationSeconds,
  }) {
    final title = _normalizeForScoring((item['trackName'] ?? '').toString());
    final artist = _normalizeForScoring((item['artistName'] ?? '').toString());
    final hasSynced =
        ((item['syncedLyrics'] ?? '').toString().trim()).isNotEmpty;
    final isInstrumental = item['instrumental'] == true;

    var score = 0;

    if (title == normalizedTitle) {
      score += 130;
    } else if (title.contains(normalizedTitle) ||
        normalizedTitle.contains(title)) {
      score += 75;
    }

    if (artist == normalizedArtist) {
      score += 95;
    } else if (artist.contains(normalizedArtist) ||
        normalizedArtist.contains(artist)) {
      score += 50;
    }

    if (hasSynced) score += 70;
    if (isInstrumental) score -= 80;

    final duration = _asInt(item['duration']);
    if (durationSeconds != null && duration != null) {
      final diff = (duration - durationSeconds).abs();
      if (diff <= 1) {
        score += 40;
      } else if (diff <= 4) {
        score += 25;
      } else if (diff <= 8) {
        score += 12;
      } else if (diff >= 20) {
        score -= 24;
      }
    }

    return score;
  }

  static dynamic _decodeJsonBody(List<int> bodyBytes) {
    return jsonDecode(utf8.decode(bodyBytes));
  }

  static int _fractionToMilliseconds(String value) {
    if (value.isEmpty) return 0;
    if (value.length == 1) return (int.tryParse(value) ?? 0) * 100;
    if (value.length == 2) return (int.tryParse(value) ?? 0) * 10;
    return int.tryParse(value.substring(0, 3)) ?? 0;
  }

  static int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static String _cleanTitleForQuery(String value) {
    var text = value.trim();
    if (text.isEmpty) return text;
    text = text.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    text = text.replaceAll(
      RegExp(r'\((official|video|audio|lyrics?)\)', caseSensitive: false),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'\b(official|video|audio|lyrics?)\b', caseSensitive: false),
      ' ',
    );
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _cleanArtistForQuery(String value) {
    var text = value.trim();
    if (text.isEmpty) return text;
    final splitter = RegExp(r'\s*(,|&|feat\.?|ft\.?)\s*', caseSensitive: false);
    final primary = text.split(splitter).first.trim();
    return primary.isEmpty ? text : primary;
  }

  static String _normalizeForScoring(String value) {
    var text = value.toLowerCase();
    text = text.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    text = text.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    text = text.replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ');
    text = text.replaceAll(
      RegExp(
        r'\b(official|video|audio|lyrics?|lyric|visualizer|remastered|remaster|full|song)\b',
      ),
      ' ',
    );
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static void _trimCache() {
    final entries = _cache.entries.toList()
      ..sort((a, b) => a.value.cachedAt.compareTo(b.value.cachedAt));
    final removeCount = (_cache.length * 0.35).round().clamp(20, _cache.length);
    for (var i = 0; i < removeCount; i++) {
      _cache.remove(entries[i].key);
    }
  }
}

class _CachedLyrics {
  final LrcLibLyrics? lyrics;
  final DateTime cachedAt;

  const _CachedLyrics({required this.lyrics, required this.cachedAt});
}
