import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/utils/app_logger.dart';
import 'lrclib_api.dart';

/// Fetches lyrics from the LyricsPlus API

class LyricsPlusApi {
  LyricsPlusApi._();

  static const Duration _timeout = Duration(seconds: 9);
  static const Duration _cacheTtl = Duration(hours: 6);

  static const List<String> _hosts = [
    'lyricsplus.atomix.one',
    'lyricsplus.binimum.org',
  ];

  static const String _sources =
      'apple,lyricsplus,musixmatch,spotify,musixmatch-word';

  static final Map<String, _CachedEntry> _cache = {};
  static final Map<String, Future<LrcLibLyrics?>> _inFlight = {};

  static Future<LrcLibLyrics?> fetchBestLyrics({
    required String title,
    required String artist,
    int? durationSeconds,
    String? album,
  }) async {
    final normalizedTitle = _normalize(title);
    if (normalizedTitle.isEmpty) return null;

    final key =
        '$normalizedTitle|${_normalize(artist)}|${durationSeconds ?? -1}';

    final cached = _cache[key];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) < _cacheTtl) {
      AppLogger.info('[LyricsPlus] Cache hit for "$title" by "$artist"');
      return cached.lyrics;
    }

    final existing = _inFlight[key];
    if (existing != null) {
      AppLogger.info('[LyricsPlus] In-flight dedup for "$title" by "$artist"');
      return existing;
    }

    final request = _fetchUncached(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
      album: album,
    );
    _inFlight[key] = request;

    try {
      final result = await request;
      _cache[key] = _CachedEntry(lyrics: result, cachedAt: DateTime.now());
      if (_cache.length > 300) _trimCache();
      return result;
    } finally {
      if (identical(_inFlight[key], request)) {
        _inFlight.remove(key);
      }
    }
  }

  static Future<LrcLibLyrics?> _fetchUncached({
    required String title,
    required String artist,
    int? durationSeconds,
    String? album,
  }) async {
    final params = <String, String>{
      'title': title.trim(),
      'artist': artist.trim(),
      'source': _sources,
    };
    if ((album ?? '').trim().isNotEmpty) {
      params['album'] = album!.trim();
    }
    if (durationSeconds != null && durationSeconds > 0) {
      params['duration'] = durationSeconds.toString();
    }

    for (final host in _hosts) {
      final uri = Uri.https(host, '/v2/lyrics/get', params);
      AppLogger.info(
        '[LyricsPlus] Trying host "$host" for "$title" by "$artist"',
      );

      try {
        final response = await http
            .get(uri, headers: const {'Accept': 'application/json'})
            .timeout(_timeout);

        AppLogger.info(
          '[LyricsPlus] "$host" responded HTTP ${response.statusCode} '
          'for "$title" by "$artist"',
        );

        if (response.statusCode != 200) {
          AppLogger.warning(
            '[LyricsPlus] Non-200 from "$host" (${response.statusCode}), '
            'trying next host',
          );
          continue;
        }

        final body = jsonDecode(utf8.decode(response.bodyBytes));
        if (body is! Map<String, dynamic>) {
          AppLogger.warning(
            '[LyricsPlus] Unexpected body type from "$host", trying next host',
          );
          continue;
        }

        final reportedSource =
            body['metadata']?['source'] ?? body['source'] ?? 'unknown';
        AppLogger.info(
          '[LyricsPlus] "$host" — API reported source: "$reportedSource"',
        );

        final result = _parse(
          body,
          title: title,
          artist: artist,
          durationSeconds: durationSeconds,
        );

        if (result == null) {
          AppLogger.warning(
            '[LyricsPlus] No usable lyric lines from "$host" for "$title"',
          );
          continue;
        }

        if (result.hasWordSyncedLyrics) {
          AppLogger.info(
            '[LyricsPlus] Word-level: ${result.wordLines!.length} lines '
            'from "$host" for "$title"',
          );
        } else {
          AppLogger.info(
            '[LyricsPlus] Line-level: ${result.parsedLines.length} lines '
            'from "$host" for "$title"',
          );
        }

        return result;
      } catch (e) {
        AppLogger.warning(
          '[LyricsPlus] Error on "$host" for "$title": $e — trying next host',
          error: e,
        );
      }
    }

    AppLogger.warning(
      '[LyricsPlus] All hosts exhausted for "$title" by "$artist"',
    );
    return null;
  }

  static LrcLibLyrics? _parse(
    Map<String, dynamic> body, {
    required String title,
    required String artist,
    int? durationSeconds,
  }) {
    final lyricsRaw = body['lyrics'];
    if (lyricsRaw is! List || lyricsRaw.isEmpty) return null;

    final lines = <LyricLine>[];
    final plainParts = <String>[];
    final wordLines = <WordSyncedLine>[];
    var hasAnyWordData = false;

    for (final item in lyricsRaw) {
      if (item is! Map<String, dynamic>) continue;

      final timeMs = _asInt(item['time']);
      final text = (item['text'] ?? '').toString().trim();
      if (timeMs == null || text.isEmpty) continue;

      // Always build the line-level entry as a fallback
      lines.add(
        LyricLine(
          start: Duration(milliseconds: timeMs),
          text: text,
        ),
      );
      plainParts.add(text);

      // Try to build word-level entry from the syllabus array
      final syllabusRaw = item['syllabus'];
      if (syllabusRaw is List && syllabusRaw.isNotEmpty) {
        final words = <WordSegment>[];

        for (final syl in syllabusRaw) {
          if (syl is! Map<String, dynamic>) continue;
          final sylTimeMs = _asInt(syl['time']);
          final sylDurationMs = _asInt(syl['duration']);
          final sylText = (syl['text'] ?? '').toString();
          if (sylTimeMs == null || sylText.isEmpty) continue;

          // Fall back to 200 ms if no duration provided
          final durationMs = (sylDurationMs != null && sylDurationMs > 0)
              ? sylDurationMs
              : 200;

          words.add(
            WordSegment(
              start: Duration(milliseconds: sylTimeMs),
              end: Duration(milliseconds: sylTimeMs + durationMs),
              text: sylText,
            ),
          );
        }

        if (words.isNotEmpty) {
          hasAnyWordData = true;
          wordLines.add(
            WordSyncedLine(
              start: Duration(milliseconds: timeMs),
              end: words.last.end,
              fullText: text,
              words: words,
            ),
          );
        }
      }
    }

    if (lines.isEmpty) return null;
    lines.sort((a, b) => a.start.compareTo(b.start));
    wordLines.sort((a, b) => a.start.compareTo(b.start));

    final resolvedWordLines =
        (hasAnyWordData && wordLines.length == lines.length) ? wordLines : null;

    return LrcLibLyrics(
      trackName: title.trim(),
      artistName: artist.trim(),
      albumName: '',
      durationSeconds: durationSeconds,
      instrumental: false,
      plainLyrics: plainParts.join('\n'),

      syncedLyrics: null,
      parsedLines: lines,
      wordLines: resolvedWordLines,
    );
  }

  static int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  static String _normalize(String value) {
    var text = value.toLowerCase();
    text = text.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  static void _trimCache() {
    final entries = _cache.entries.toList(growable: false)
      ..sort((a, b) => a.value.cachedAt.compareTo(b.value.cachedAt));
    final removeCount = (_cache.length * 0.35).round().clamp(20, _cache.length);
    for (var i = 0; i < removeCount; i++) {
      _cache.remove(entries[i].key);
    }
  }
}

class _CachedEntry {
  final LrcLibLyrics? lyrics;
  final DateTime cachedAt;

  const _CachedEntry({required this.lyrics, required this.cachedAt});
}
