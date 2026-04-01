import 'package:hongit/core/utils/app_logger.dart';
import 'package:hongit/data/api/lrclib_api.dart';
import 'package:hongit/data/api/lyricsplus_api.dart';

/// Single entry point for lyrics fetching used by both mobile and desktop UI
class LyricsService {
  LyricsService._();

  static final Map<String, Future<LrcLibLyrics?>> _inFlight = {};

  static Future<LrcLibLyrics?> fetchBestLyrics({
    required String title,
    required String artist,
    int? durationSeconds,
    String? album,
  }) {
    final key = '$title|$artist|${durationSeconds ?? -1}';
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _doFetch(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
      album: album,
    );
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  static Future<LrcLibLyrics?> _doFetch({
    required String title,
    required String artist,
    int? durationSeconds,
    String? album,
  }) async {
    AppLogger.info(
      '[Lyrics] Fetching "$title" by "$artist" — trying LyricsPlus first',
    );
    final plusResult = await LyricsPlusApi.fetchBestLyrics(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
      album: album,
    );
    if (plusResult != null) {
      AppLogger.info(
        '[Lyrics] Source: LyricsPlus — '
        '${plusResult.parsedLines.length} lines for "$title"',
      );
      return plusResult;
    }
    AppLogger.info(
      '[Lyrics] LyricsPlus returned null for "$title" — falling back to LrcLib',
    );
    final lrcResult = await LrcLibApi.fetchBestLyrics(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
      album: album,
    );
    if (lrcResult != null) {
      AppLogger.info(
        '[Lyrics] Source: LrcLib — '
        '${lrcResult.parsedLines.length} lines for "$title" '
        '(synced: ${lrcResult.hasSyncedLyrics})',
      );
    } else {
      AppLogger.warning(
        '[Lyrics] No lyrics found from any source for "$title" by "$artist"',
      );
    }
    return lrcResult;
  }
}
