import 'data_saver_settings.dart';

class YoutubeThumbnailUtils {
  static final RegExp _ytImgVideoRegExp = RegExp(
    r'/(?:vi|vi_webp)/([A-Za-z0-9_-]{11})/',
  );
  static final RegExp _watchVideoRegExp = RegExp(r'[?&]v=([A-Za-z0-9_-]{11})');
  static final RegExp _shortUrlRegExp = RegExp(
    r'youtu\.be/([A-Za-z0-9_-]{11})',
  );
  static final RegExp _embedVideoRegExp = RegExp(r'/embed/([A-Za-z0-9_-]{11})');
  static final RegExp _videoIdRegExp = RegExp(r'^[A-Za-z0-9_-]{11}$');

  static String bestInitialUrl({
    required String videoId,
    String? preferredUrl,
    bool? lowQuality,
  }) {
    final candidates = candidateUrls(
      songId: 'yt:$videoId',
      imageUrl: preferredUrl,
      lowQuality: lowQuality,
    );
    if (candidates.isEmpty) return '';

    for (final url in candidates) {
      if (url.contains('/sddefault.jpg')) return url;
    }
    for (final url in candidates) {
      if (url.contains('/hqdefault.jpg')) return url;
    }
    return candidates.first;
  }

  static bool isYtmArtworkUrl(String? raw) {
    final url = _normalizeUrl(raw).toLowerCase();
    if (url.isEmpty) return false;
    return url.contains('lh3.googleusercontent.com') ||
        (url.contains('googleusercontent.com') && !url.contains('ytimg.com'));
  }

  static double preferredArtworkScale({
    String? songId,
    String? imageUrl,
    double youtubeVideoScale = 1.9,
    double normalScale = 1.0,
  }) {
    final hasYoutubeVideoRef =
        videoIdFromSongId(songId) != null || videoIdFromUrl(imageUrl) != null;
    if (!hasYoutubeVideoRef) return normalScale;
    if (isYtmArtworkUrl(imageUrl)) return normalScale;
    return youtubeVideoScale;
  }

  static List<String> candidateUrls({
    String? songId,
    String? imageUrl,
    bool? lowQuality,
  }) {
    final isLowQualityMode = lowQuality ?? DataSaverSettings.isEnabled;
    final videoId = videoIdFromSongId(songId) ?? videoIdFromUrl(imageUrl);
    final ordered = <String>{};
    final normalizedImageUrl = _normalizeUrl(imageUrl);
    final preferProvidedFirst = isYtmArtworkUrl(normalizedImageUrl);

    void add(String? raw) {
      final normalized = _normalizeUrl(raw);
      if (normalized.isNotEmpty) ordered.add(normalized);
    }

    if (preferProvidedFirst) {
      for (final variant in _ytmHighResVariants(
        normalizedImageUrl,
        lowQuality: isLowQualityMode,
      )) {
        add(variant);
      }
    }

    if (videoId != null) {
      if (isLowQualityMode) {
        add('https://i.ytimg.com/vi/$videoId/hqdefault.jpg');
        add('https://i.ytimg.com/vi/$videoId/mqdefault.jpg');
      } else {
        add('https://i.ytimg.com/vi/$videoId/maxresdefault.jpg');
        add('https://i.ytimg.com/vi/$videoId/sddefault.jpg');
        add('https://i.ytimg.com/vi/$videoId/hq720.jpg');
        add('https://i.ytimg.com/vi/$videoId/hqdefault.jpg');
      }
      add('https://i.ytimg.com/vi/$videoId/mqdefault.jpg');
      add('https://i.ytimg.com/vi/$videoId/default.jpg');
    }

    if (!preferProvidedFirst) {
      add(normalizedImageUrl);
    }

    if (videoId != null) {
      if (!isLowQualityMode) {
        add('https://i.ytimg.com/vi_webp/$videoId/maxresdefault.webp');
        add('https://i.ytimg.com/vi_webp/$videoId/sddefault.webp');
      }
      add('https://i.ytimg.com/vi_webp/$videoId/hqdefault.webp');
    }

    return ordered.toList(growable: false);
  }

  static List<String> _ytmHighResVariants(
    String imageUrl, {
    required bool lowQuality,
  }) {
    if (!isYtmArtworkUrl(imageUrl)) return const [];

    final base = _ytmResizeBase(imageUrl);
    if (base.isEmpty) return const [];

    final out = <String>{};
    void add(String suffix) {
      out.add('$base$suffix');
    }

    if (lowQuality) {
      add('w360-h360-l90-rj');
      add('w240-h240-l90-rj');
      add('w180-h180-l90-rj');
      add('s360');
    } else {
      add('w1024-h1024-l90-rj');
      add('w720-h720-l90-rj');
      add('w544-h544-l90-rj');
      add('w480-h480-l90-rj');
      add('w360-h360-l90-rj');
      add('s1024');
      add('s720');
      add('s544');
      add('s360');
    }
    out.add(imageUrl);

    return out.toList(growable: false);
  }

  static String _ytmResizeBase(String url) {
    final normalized = _normalizeUrl(url);
    if (normalized.isEmpty) return '';

    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return '';

    final plain = uri.hasQuery ? uri.replace(query: '').toString() : normalized;
    final eqIndex = plain.lastIndexOf('=');
    if (eqIndex >= 0 && eqIndex < plain.length - 1) {
      return plain.substring(0, eqIndex + 1);
    }
    if (eqIndex == plain.length - 1) {
      return plain;
    }
    return '$plain=';
  }

  static String? videoIdFromSongId(String? songId) {
    if (songId == null) return null;
    final raw = songId.trim();
    if (raw.isEmpty) return null;

    if (raw.startsWith('yt:')) {
      final id = raw.substring(3).trim();
      return _isVideoId(id) ? id : null;
    }

    final lower = raw.toLowerCase();
    final looksLikeYoutubeRef =
        lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('ytimg.com') ||
        lower.contains('/vi/') ||
        lower.contains('/vi_webp/');
    if (!looksLikeYoutubeRef) return null;

    return videoIdFromUrl(raw);
  }

  static String? videoIdFromUrl(String? raw) {
    if (raw == null) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (_isVideoId(text)) return text;

    final ytImgMatch = _ytImgVideoRegExp.firstMatch(text);
    if (ytImgMatch != null) {
      final id = ytImgMatch.group(1);
      if (_isVideoId(id)) return id;
    }

    final watchMatch = _watchVideoRegExp.firstMatch(text);
    if (watchMatch != null) {
      final id = watchMatch.group(1);
      if (_isVideoId(id)) return id;
    }

    final shortMatch = _shortUrlRegExp.firstMatch(text);
    if (shortMatch != null) {
      final id = shortMatch.group(1);
      if (_isVideoId(id)) return id;
    }

    final embedMatch = _embedVideoRegExp.firstMatch(text);
    if (embedMatch != null) {
      final id = embedMatch.group(1);
      if (_isVideoId(id)) return id;
    }

    return null;
  }

  static bool _isVideoId(String? value) {
    if (value == null) return false;
    return _videoIdRegExp.hasMatch(value);
  }

  static String _normalizeUrl(String? raw) {
    if (raw == null) return '';
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('http://')) {
      return trimmed.replaceFirst('http://', 'https://');
    }
    return trimmed;
  }
}
