import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/utils/app_logger.dart';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class WordSegment {
  final Duration start;
  final Duration end;
  final String text;

  const WordSegment({
    required this.start,
    required this.end,
    required this.text,
  });
}

class WordSyncedLine {
  final Duration start;
  final Duration end;
  final String fullText;
  final List<WordSegment> words;

  const WordSyncedLine({
    required this.start,
    required this.end,
    required this.fullText,
    required this.words,
  });
}

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

  final List<WordSyncedLine>? wordLines;

  const LrcLibLyrics({
    required this.trackName,
    required this.artistName,
    required this.albumName,
    required this.durationSeconds,
    required this.instrumental,
    required this.plainLyrics,
    required this.syncedLyrics,
    required this.parsedLines,
    this.wordLines,
  });

  bool get hasWordSyncedLyrics => wordLines != null && wordLines!.isNotEmpty;

  bool get hasSyncedLyrics => parsedLines.isNotEmpty;
}

class LrcLibApi {
  static const Duration _timeout = Duration(seconds: 9);
  static const Duration _cacheTtl = Duration(hours: 12);
  static const Duration _persistedCacheTtl = Duration(days: 14);
  static const String _host = 'lrclib.net';

  static final Map<String, _CachedLyrics> _cache = <String, _CachedLyrics>{};
  static final Map<String, Future<LrcLibLyrics?>> _inFlight =
      <String, Future<LrcLibLyrics?>>{};
  static bool _diskLoaded = false;
  static Future<void>? _diskLoadInFlight;
  static Timer? _persistTimer;

  static Future<LrcLibLyrics?> fetchBestLyrics({
    required String title,
    required String artist,
    int? durationSeconds,
    String? album,
  }) async {
    await _ensureDiskLoaded();

    final normalizedTitle = _normalize(title);
    if (normalizedTitle.isEmpty) return null;

    final normalizedArtist = _normalize(artist);
    final key = '$normalizedTitle|$normalizedArtist|${durationSeconds ?? -1}';
    final cached = _cache[key];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) < _cacheTtl) {
      return cached.lyrics;
    }

    final existing = _inFlight[key];
    if (existing != null) {
      return existing;
    }

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
      if (_cache.length > 400) {
        _trimCache();
      }
      _schedulePersist();
      return result;
    } finally {
      if (identical(_inFlight[key], request)) {
        _inFlight.remove(key);
      }
    }
  }

  static Future<LrcLibLyrics?> _fetchBestLyricsUncached({
    required String title,
    required String artist,
    int? durationSeconds,
    String? album,
  }) async {
    final variants = _buildQueryVariants(
      title: title,
      artist: artist,
      album: album,
    );

    final candidates = <Map<String, dynamic>>[];
    for (final v in variants) {
      final exact = await _tryGet(
        title: v.title,
        artist: v.artist,
        durationSeconds: durationSeconds,
        album: v.album,
      );
      if (exact != null) {
        candidates.add(exact);
      }

      if (durationSeconds != null && durationSeconds > 0) {
        final exactNoDuration = await _tryGet(
          title: v.title,
          artist: v.artist,
          durationSeconds: null,
          album: v.album,
        );
        if (exactNoDuration != null) {
          candidates.add(exactNoDuration);
        }
      }

      final search = await _trySearch(
        query: v.query,
        title: v.title,
        artist: v.artist,
        album: v.album,
      );
      candidates.addAll(search);
    }

    if (candidates.isEmpty) return null;

    final deduped = _dedupeCandidates(candidates);
    if (deduped.isEmpty) return null;

    final normalizedTitle = _normalize(_cleanTitleForQuery(title));
    final normalizedArtist = _normalize(_cleanArtistForQuery(artist));

    AppLogger.info(
      '[LrcLib] Scoring ${deduped.length} candidates for '
      '"$title" by "$artist" '
      '(query title: "$normalizedTitle", query artist: "$normalizedArtist")',
    );

    Map<String, dynamic>? best;
    var bestScore = -1 << 30;
    for (final item in deduped) {
      final score = _candidateScore(
        item: item,
        normalizedTitle: normalizedTitle,
        normalizedArtist: normalizedArtist,
        durationSeconds: durationSeconds,
      );

      final candidateTitle = (item['trackName'] ?? '').toString().trim();
      final candidateArtist = (item['artistName'] ?? '').toString().trim();
      final hasSynced =
          ((item['syncedLyrics'] ?? '').toString().trim()).isNotEmpty;
      AppLogger.info(
        '[LrcLib]   score=$score  '
        '"$candidateTitle" — "$candidateArtist"  '
        '(synced: $hasSynced)',
      );

      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }

    if (best == null) return null;

    final pickedTitle = (best['trackName'] ?? '').toString().trim();
    final pickedArtist = (best['artistName'] ?? '').toString().trim();
    AppLogger.info(
      '[LrcLib] Picked: "$pickedTitle" — "$pickedArtist"  '
      '(score: $bestScore)',
    );

    return _parseLyrics(best);
  }

  static Future<Map<String, dynamic>?> _tryGet({
    required String title,
    String? artist,
    int? durationSeconds,
    String? album,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) return null;

    final query = <String, String>{'track_name': cleanTitle};
    if ((artist ?? '').trim().isNotEmpty) {
      query['artist_name'] = artist!.trim();
    }
    if ((album ?? '').trim().isNotEmpty) {
      query['album_name'] = album!.trim();
    }
    if (durationSeconds != null && durationSeconds > 0) {
      query['duration'] = durationSeconds.toString();
    }

    final uri = Uri.https(_host, '/api/get', query);
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
    required String query,
    String? title,
    String? artist,
    String? album,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return const <Map<String, dynamic>>[];

    final params = <String, String>{'q': cleanQuery};
    if ((title ?? '').trim().isNotEmpty) {
      params['track_name'] = title!.trim();
    }
    if ((artist ?? '').trim().isNotEmpty) {
      params['artist_name'] = artist!.trim();
    }
    if ((album ?? '').trim().isNotEmpty) {
      params['album_name'] = album!.trim();
    }

    final uri = Uri.https(_host, '/api/search', params);
    try {
      final response = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(_timeout);
      if (response.statusCode != 200) return const <Map<String, dynamic>>[];
      final body = _decodeJsonBody(response.bodyBytes);
      if (body is! List) return const <Map<String, dynamic>>[];
      return body.whereType<Map<String, dynamic>>().toList(growable: false);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  static List<_LyricsQueryVariant> _buildQueryVariants({
    required String title,
    required String artist,
    String? album,
  }) {
    final cleanedTitle = _cleanTitleForQuery(title);
    final titleWithoutFeat = _removeFeaturingFromTitle(cleanedTitle);
    final cleanedArtist = _cleanArtistForQuery(artist);
    final cleanedAlbum = (album ?? '').trim();

    final variants = <_LyricsQueryVariant>[];
    final seen = <String>{};

    void add(String t, String? a) {
      final titlePart = t.trim();
      if (titlePart.isEmpty) return;
      final artistPart = (a ?? '').trim();
      final key = '${_normalize(titlePart)}|${_normalize(artistPart)}';
      if (!seen.add(key)) return;
      final queryParts = <String>[
        titlePart,
        if (artistPart.isNotEmpty) artistPart,
      ];
      if (cleanedAlbum.isNotEmpty) {
        queryParts.add(cleanedAlbum);
      }
      variants.add(
        _LyricsQueryVariant(
          title: titlePart,
          artist: artistPart.isEmpty ? null : artistPart,
          album: cleanedAlbum.isEmpty ? null : cleanedAlbum,
          query: queryParts.join(' ').trim(),
        ),
      );
    }

    add(cleanedTitle, cleanedArtist);
    add(titleWithoutFeat, cleanedArtist);
    add(cleanedTitle, null);
    add(titleWithoutFeat, null);

    final dashParts = _splitArtistTitleByDash(title);
    if (dashParts != null) {
      add(
        _cleanTitleForQuery(dashParts.$2),
        _cleanArtistForQuery(dashParts.$1),
      );
      add(_cleanTitleForQuery(dashParts.$2), null);
    }

    return variants;
  }

  static List<Map<String, dynamic>> _dedupeCandidates(
    List<Map<String, dynamic>> candidates,
  ) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final item in candidates) {
      final key = _candidateIdentity(item);
      if (seen.add(key)) {
        out.add(item);
      }
    }
    return out;
  }

  static String _candidateIdentity(Map<String, dynamic> item) {
    final id = (item['id'] ?? '').toString().trim();
    if (id.isNotEmpty) return 'id:$id';
    final title = _normalize((item['trackName'] ?? '').toString());
    final artist = _normalize((item['artistName'] ?? '').toString());
    final duration = _asInt(item['duration']) ?? -1;
    return '$title|$artist|$duration';
  }

  static LrcLibLyrics _parseLyrics(Map<String, dynamic> raw) {
    final plainLyrics = (raw['plainLyrics'] ?? '').toString();
    var syncedLyrics = (raw['syncedLyrics'] ?? '').toString().trim();

    if (syncedLyrics.isEmpty && _looksLikeLrc(plainLyrics)) {
      AppLogger.info(
        '[LrcLib] plainLyrics looks like LRC — promoting to syncedLyrics for '
        '"${(raw["trackName"] ?? "").toString().trim()}"',
      );
      syncedLyrics = plainLyrics.trim();
    }

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

  static bool _looksLikeLrc(String text) {
    if (text.trim().isEmpty) return false;
    final timestampRegex = RegExp(r'^\[\d{1,2}:\d{2}');
    var matches = 0;
    for (final line in text.split('\n')) {
      if (timestampRegex.hasMatch(line.trim())) {
        if (++matches >= 3) return true;
      }
    }
    return false;
  }

  static List<LyricLine> _parseSyncedLyrics(String? syncedLyrics) {
    if (syncedLyrics == null || syncedLyrics.trim().isEmpty) {
      return const <LyricLine>[];
    }

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
        final start = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds,
        );
        lines.add(LyricLine(start: start, text: text));
      }
    }

    if (lines.isEmpty) return const <LyricLine>[];
    lines.sort((a, b) => a.start.compareTo(b.start));

    final seen = <String>{};
    final deduped = <LyricLine>[];
    for (final line in lines) {
      final signature =
          '${line.start.inMilliseconds}|${line.text.toLowerCase().trim()}';
      if (seen.add(signature)) {
        deduped.add(line);
      }
    }
    return deduped;
  }

  static int _candidateScore({
    required Map<String, dynamic> item,
    required String normalizedTitle,
    required String normalizedArtist,
    required int? durationSeconds,
  }) {
    final title = _normalize((item['trackName'] ?? '').toString());
    final artist = _normalize((item['artistName'] ?? '').toString());
    final hasSynced =
        ((item['syncedLyrics'] ?? '').toString().trim()).isNotEmpty;
    final hasPlain = ((item['plainLyrics'] ?? '').toString().trim()).isNotEmpty;
    final isInstrumental = item['instrumental'] == true;

    var score = 0;

    if (title == normalizedTitle) {
      score += 160;
    } else if (title.contains(normalizedTitle) ||
        normalizedTitle.contains(title)) {
      score += 95;
    } else {
      score += (_tokenOverlap(title, normalizedTitle) * 80).round();
    }

    if (normalizedArtist.isNotEmpty) {
      if (artist == normalizedArtist) {
        score += 110;
      } else if (artist.contains(normalizedArtist) ||
          normalizedArtist.contains(artist)) {
        score += 65;
      } else {
        score += (_tokenOverlap(artist, normalizedArtist) * 60).round();
      }
    }

    if (hasSynced) score += 70;
    if (hasPlain) score += 12;
    if (isInstrumental) score -= 90;

    final duration = _asInt(item['duration']);
    if (durationSeconds != null && duration != null) {
      final diff = (duration - durationSeconds).abs();
      if (diff <= 1) {
        score += 40;
      } else if (diff <= 4) {
        score += 26;
      } else if (diff <= 8) {
        score += 14;
      } else if (diff >= 20) {
        score -= 24;
      }
    }

    return score;
  }

  static double _tokenOverlap(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final aTokens = a
        .split(' ')
        .map((e) => e.trim())
        .where((e) => e.length > 1)
        .toSet();
    final bTokens = b
        .split(' ')
        .map((e) => e.trim())
        .where((e) => e.length > 1)
        .toSet();
    if (aTokens.isEmpty || bTokens.isEmpty) return 0;
    final intersection = aTokens.intersection(bTokens).length;
    final denominator = aTokens.length > bTokens.length
        ? aTokens.length
        : bTokens.length;
    return denominator == 0 ? 0 : intersection / denominator;
  }

  static dynamic _decodeJsonBody(List<int> bodyBytes) {
    final decoded = utf8.decode(bodyBytes);
    return jsonDecode(decoded);
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
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return _stripLeadingArtistFromTitle(text);
  }

  static String _removeFeaturingFromTitle(String value) {
    var text = value.trim();
    if (text.isEmpty) return text;
    text = text.replaceAll(
      RegExp(r'\((feat\.?|ft\.?).*?\)', caseSensitive: false),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'\b(feat\.?|ft\.?)\b.*$', caseSensitive: false),
      ' ',
    );
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  static String _cleanArtistForQuery(String value) {
    var text = value.trim();
    if (text.isEmpty) return text;
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    final splitter = RegExp(
      r'\s*(,|&|feat\.?|ft\.?|x|and)\s*',
      caseSensitive: false,
    );
    final primary = text.split(splitter).first.trim();
    return primary.isEmpty ? text : primary;
  }

  static (String, String)? _splitArtistTitleByDash(String value) {
    final match = RegExp(
      r'^\s*([^-\u2013\u2014]{2,120})\s*[-\u2013\u2014]\s*(.{2,180})\s*$',
    ).firstMatch(value);
    if (match == null) return null;
    final left = match.group(1)?.trim() ?? '';
    final right = match.group(2)?.trim() ?? '';
    if (left.isEmpty || right.isEmpty) return null;
    return (left, right);
  }

  static String _stripLeadingArtistFromTitle(String value) {
    final split = _splitArtistTitleByDash(value);
    if (split == null) return value.trim();
    final candidate = split.$2.trim();
    if (candidate.length < 2) return value.trim();
    return candidate;
  }

  static String _normalize(String value) {
    var text = value.toLowerCase();
    text = text.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    text = text.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    text = text.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    text = text.replaceAll(
      RegExp(
        r'\b(official|video|audio|lyrics?|lyric|visualizer|remastered|remaster|full|song)\b',
      ),
      ' ',
    );
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  static void _trimCache() {
    final entries = _cache.entries.toList(growable: false)
      ..sort((a, b) => a.value.cachedAt.compareTo(b.value.cachedAt));
    final removeCount = (_cache.length * 0.35).round().clamp(30, _cache.length);
    for (var i = 0; i < removeCount; i++) {
      _cache.remove(entries[i].key);
    }
  }

  static Future<void> _ensureDiskLoaded() async {
    if (_diskLoaded) return;
    final inFlight = _diskLoadInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final task = _loadFromDisk();
    _diskLoadInFlight = task;
    try {
      await task;
      _diskLoaded = true;
    } finally {
      if (identical(_diskLoadInFlight, task)) {
        _diskLoadInFlight = null;
      }
    }
  }

  static Future<void> _loadFromDisk() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final now = DateTime.now();
      for (final entry in decoded.entries) {
        final cacheEntry = _CachedLyrics.fromJson(entry.value);
        if (cacheEntry == null) continue;
        final age = now.difference(cacheEntry.cachedAt);
        if (age > _persistedCacheTtl) continue;
        _cache[entry.key] = cacheEntry;
      }
    } catch (_) {
      // ignore disk cache errors
    }
  }

  static void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 450), () {
      unawaited(_persistToDisk());
    });
  }

  static Future<void> _persistToDisk() async {
    try {
      final now = DateTime.now();
      final payload = <String, dynamic>{};
      for (final entry in _cache.entries) {
        final cacheEntry = entry.value;
        if (cacheEntry.lyrics == null) continue;
        if (now.difference(cacheEntry.cachedAt) > _persistedCacheTtl) continue;
        payload[entry.key] = cacheEntry.toJson();
      }
      final file = await _cacheFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (_) {
      // ignore disk cache errors
    }
  }

  static Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'lyrics_cache_v1.json');
    return File(path);
  }
}

class _CachedLyrics {
  final LrcLibLyrics? lyrics;
  final DateTime cachedAt;

  const _CachedLyrics({required this.lyrics, required this.cachedAt});

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'cachedAt': cachedAt.toIso8601String(),
      'lyrics': lyrics == null
          ? null
          : <String, dynamic>{
              'trackName': lyrics!.trackName,
              'artistName': lyrics!.artistName,
              'albumName': lyrics!.albumName,
              'duration': lyrics!.durationSeconds,
              'instrumental': lyrics!.instrumental,
              'plainLyrics': lyrics!.plainLyrics,
              'syncedLyrics': lyrics!.syncedLyrics,
            },
    };
  }

  static _CachedLyrics? fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) return null;
    final cachedAtRaw = json['cachedAt'];
    final cachedAt = DateTime.tryParse((cachedAtRaw ?? '').toString());
    if (cachedAt == null) return null;

    final lyricsMap = json['lyrics'];
    if (lyricsMap is! Map<String, dynamic>) {
      return _CachedLyrics(lyrics: null, cachedAt: cachedAt);
    }
    final synced = (lyricsMap['syncedLyrics'] ?? '').toString().trim();
    final parsed = LrcLibApi._parseSyncedLyrics(synced.isEmpty ? null : synced);
    final lyrics = LrcLibLyrics(
      trackName: (lyricsMap['trackName'] ?? '').toString(),
      artistName: (lyricsMap['artistName'] ?? '').toString(),
      albumName: (lyricsMap['albumName'] ?? '').toString(),
      durationSeconds: _asIntStatic(lyricsMap['duration']),
      instrumental: lyricsMap['instrumental'] == true,
      plainLyrics: (lyricsMap['plainLyrics'] ?? '').toString(),
      syncedLyrics: synced.isEmpty ? null : synced,
      parsedLines: parsed,
      // wordLines intentionally omitted
    );
    return _CachedLyrics(lyrics: lyrics, cachedAt: cachedAt);
  }

  static int? _asIntStatic(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }
}

class _LyricsQueryVariant {
  final String title;
  final String? artist;
  final String? album;
  final String query;

  const _LyricsQueryVariant({
    required this.title,
    required this.artist,
    required this.album,
    required this.query,
  });
}
