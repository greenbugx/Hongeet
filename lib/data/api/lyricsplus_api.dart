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

  static const String _searchApiHost = 'lyrics-api.binimum.org';

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
    final ttmlResult = await _tryTtmlPath(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
      album: album,
    );
    if (ttmlResult != null) return ttmlResult;

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

  static Future<LrcLibLyrics?> _tryTtmlPath({
    required String title,
    required String artist,
    int? durationSeconds,
    String? album,
  }) async {
    try {
      final params = <String, String>{
        'track': title.trim(),
        'artist': artist.trim(),
      };
      if ((album ?? '').trim().isNotEmpty) {
        params['album'] = album!.trim();
      }
      if (durationSeconds != null && durationSeconds > 0) {
        params['duration'] = durationSeconds.toString();
      }

      final uri = Uri.https(_searchApiHost, '/', params);
      AppLogger.info(
        '[LyricsPlus] Trying TTML search for "$title" by "$artist"',
      );

      final searchResponse = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(_timeout);

      if (searchResponse.statusCode != 200) return null;

      final searchBody = jsonDecode(utf8.decode(searchResponse.bodyBytes));
      if (searchBody is! Map<String, dynamic>) return null;

      final results = searchBody['results'];
      if (results is! List || results.isEmpty) return null;

      final first = results.first;
      if (first is! Map<String, dynamic>) return null;

      final timingType = (first['timing_type'] ?? '').toString();
      final lyricsUrl = (first['lyricsUrl'] ?? '').toString().trim();

      if ((timingType != 'word' && timingType != 'line') || lyricsUrl.isEmpty) {
        AppLogger.info(
          '[LyricsPlus] TTML search: no usable result for "$title" '
          '(timing_type: "$timingType")',
        );
        return null;
      }

      AppLogger.info(
        '[LyricsPlus] TTML match: "${(first['track_name'] ?? '').toString().trim()}" '
        'by "${(first['artist_name'] ?? '').toString().trim()}" '
        '— timing: $timingType — url: $lyricsUrl',
      );

      final ttmlResponse = await http
          .get(Uri.parse(lyricsUrl))
          .timeout(_timeout);

      if (ttmlResponse.statusCode != 200) return null;

      final ttmlContent = utf8.decode(ttmlResponse.bodyBytes);

      if (timingType == 'word') {
        final wordLines = _parseTtml(ttmlContent);
        if (wordLines.isEmpty) return null;

        final plainParts = wordLines.map((l) => l.fullText).toList();
        final lines = wordLines
            .map((l) => LyricLine(start: l.start, text: l.fullText))
            .toList();

        AppLogger.info(
          '[LyricsPlus] TTML word-level: ${wordLines.length} lines for "$title" '
          '(source url: $lyricsUrl)',
        );

        return LrcLibLyrics(
          trackName: (first['track_name'] ?? title).toString().trim(),
          artistName: (first['artist_name'] ?? artist).toString().trim(),
          albumName: (first['album_name'] ?? '').toString().trim(),
          durationSeconds: durationSeconds,
          instrumental: false,
          plainLyrics: plainParts.join('\n'),
          syncedLyrics: null,
          parsedLines: lines,
          wordLines: wordLines,
        );
      } else {
        // line-level TTML — apply leadingSilence correction
        final lines = _parseTtmlLineLevel(ttmlContent);
        if (lines.isEmpty) return null;

        AppLogger.info(
          '[LyricsPlus] TTML line-level: ${lines.length} lines for "$title" '
          '(source url: $lyricsUrl)',
        );

        return LrcLibLyrics(
          trackName: (first['track_name'] ?? title).toString().trim(),
          artistName: (first['artist_name'] ?? artist).toString().trim(),
          albumName: (first['album_name'] ?? '').toString().trim(),
          durationSeconds: durationSeconds,
          instrumental: false,
          plainLyrics: lines.map((l) => l.text).join('\n'),
          syncedLyrics: null,
          parsedLines: lines,
          wordLines: null,
        );
      }
    } catch (e) {
      AppLogger.warning(
        '[LyricsPlus] TTML path failed for "$title": $e',
        error: e,
      );
      return null;
    }
  }

  /// Parses word-level TTML (itunes:timing="Word") into [WordSyncedLine] list.
  /// Applies leadingSilence offset so Apple Music timestamps align with YouTube.
  static List<WordSyncedLine> _parseTtml(String ttml) {
    final wordLines = <WordSyncedLine>[];

    final leadingSilenceMs = _parseLeadingSilence(ttml);
    if (leadingSilenceMs > 0) {
      AppLogger.info(
        '[LyricsPlus] TTML leadingSilence=${leadingSilenceMs}ms — subtracting from all timestamps',
      );
    } else {
      AppLogger.info(
        '[LyricsPlus] TTML leadingSilence=0 — no offset correction needed',
      );
    }

    final pPattern = RegExp(
      r'<p\b[^>]*begin="([^"]+)"[^>]*end="([^"]+)"[^>]*>([\s\S]*?)</p>',
      caseSensitive: false,
    );
    final spanPattern = RegExp(
      r'<span\b[^>]*begin="([^"]+)"[^>]*end="([^"]+)"[^>]*>(.*?)</span>',
      caseSensitive: false,
    );

    for (final pMatch in pPattern.allMatches(ttml)) {
      var lineStart = _parseTtmlTime(pMatch.group(1) ?? '');
      var lineEnd = _parseTtmlTime(pMatch.group(2) ?? '');
      final innerContent = pMatch.group(3) ?? '';

      if (lineStart == null || lineEnd == null) continue;

      if (leadingSilenceMs > 0) {
        final startMs = (lineStart.inMilliseconds - leadingSilenceMs).clamp(
          0,
          double.maxFinite.toInt(),
        );
        final endMs = (lineEnd.inMilliseconds - leadingSilenceMs).clamp(
          0,
          double.maxFinite.toInt(),
        );
        lineStart = Duration(milliseconds: startMs);
        lineEnd = Duration(milliseconds: endMs);
      }

      final words = <WordSegment>[];
      final textParts = <String>[];

      for (final spanMatch in spanPattern.allMatches(innerContent)) {
        var wordStart = _parseTtmlTime(spanMatch.group(1) ?? '');
        var wordEnd = _parseTtmlTime(spanMatch.group(2) ?? '');
        final wordText = spanMatch.group(3)?.trim() ?? '';

        if (wordStart == null || wordEnd == null || wordText.isEmpty) continue;

        if (leadingSilenceMs > 0) {
          final wsMs = (wordStart.inMilliseconds - leadingSilenceMs).clamp(
            0,
            double.maxFinite.toInt(),
          );
          final weMs = (wordEnd.inMilliseconds - leadingSilenceMs).clamp(
            0,
            double.maxFinite.toInt(),
          );
          wordStart = Duration(milliseconds: wsMs);
          wordEnd = Duration(milliseconds: weMs);
        }

        words.add(WordSegment(start: wordStart, end: wordEnd, text: wordText));
        textParts.add(wordText);
      }

      if (words.isEmpty) continue;

      wordLines.add(
        WordSyncedLine(
          start: lineStart,
          end: lineEnd,
          fullText: textParts.join(' '),
          words: words,
        ),
      );
    }

    return wordLines;
  }

  /// Parses line-level TTML (itunes:timing="Line") into [LyricLine] list.
  /// Applies leadingSilence offset so Apple Music timestamps align with YouTube.
  static List<LyricLine> _parseTtmlLineLevel(String ttml) {
    final leadingSilenceMs = _parseLeadingSilence(ttml);
    AppLogger.info(
      '[LyricsPlus] TTML line-level leadingSilence=${leadingSilenceMs}ms',
    );

    final pPattern = RegExp(
      r'<p\b[^>]*begin="([^"]+)"[^>]*end="([^"]+)"[^>]*>([\s\S]*?)</p>',
      caseSensitive: false,
    );

    final lines = <LyricLine>[];
    for (final pMatch in pPattern.allMatches(ttml)) {
      var lineStart = _parseTtmlTime(pMatch.group(1) ?? '');
      if (lineStart == null) continue;

      final innerContent = pMatch.group(3) ?? '';
      // Strip all XML tags to get plain text
      final text = innerContent.replaceAll(RegExp(r'<[^>]+>'), '').trim();
      if (text.isEmpty) continue;

      if (leadingSilenceMs > 0) {
        final startMs = (lineStart.inMilliseconds - leadingSilenceMs).clamp(
          0,
          double.maxFinite.toInt(),
        );
        lineStart = Duration(milliseconds: startMs);
      }

      lines.add(LyricLine(start: lineStart, text: text));
    }

    lines.sort((a, b) => a.start.compareTo(b.start));
    return lines;
  }

  static int _parseLeadingSilence(String ttml) {
    final match = RegExp(
      r'leadingSilence="([0-9]+(?:\.[0-9]+)?)"',
      caseSensitive: false,
    ).firstMatch(ttml);
    if (match == null) return 0;
    final seconds = double.tryParse(match.group(1) ?? '') ?? 0.0;
    return (seconds * 1000).round();
  }

  static Duration? _parseTtmlTime(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    final parts = trimmed.split(':');
    try {
      if (parts.length == 1) {
        final seconds = double.parse(parts[0]);
        return Duration(milliseconds: (seconds * 1000).round());
      } else if (parts.length == 2) {
        final minutes = int.parse(parts[0]);
        final seconds = double.parse(parts[1]);
        return Duration(
          milliseconds: (minutes * 60 * 1000) + (seconds * 1000).round(),
        );
      } else if (parts.length == 3) {
        final hours = int.parse(parts[0]);
        final minutes = int.parse(parts[1]);
        final seconds = double.parse(parts[2]);
        return Duration(
          milliseconds:
              (hours * 3600 * 1000) +
              (minutes * 60 * 1000) +
              (seconds * 1000).round(),
        );
      }
    } catch (_) {
      return null;
    }
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

      lines.add(
        LyricLine(
          start: Duration(milliseconds: timeMs),
          text: text,
        ),
      );
      plainParts.add(text);

      final syllabusRaw = item['syllabus'];
      if (syllabusRaw is List && syllabusRaw.isNotEmpty) {
        final words = <WordSegment>[];

        for (final syl in syllabusRaw) {
          if (syl is! Map<String, dynamic>) continue;
          final sylTimeMs = _asInt(syl['time']);
          final sylDurationMs = _asInt(syl['duration']);
          final sylText = (syl['text'] ?? '').toString();
          if (sylTimeMs == null || sylText.isEmpty) continue;

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

  static void clearCache() {
    _cache.clear();
  }
}

class _CachedEntry {
  final LrcLibLyrics? lyrics;
  final DateTime cachedAt;

  const _CachedEntry({required this.lyrics, required this.cachedAt});
}
