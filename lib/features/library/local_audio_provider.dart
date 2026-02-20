import 'dart:io';
import 'dart:async';

import 'package:path/path.dart' as p;

import '../../core/utils/app_logger.dart';

class LocalAudioTrack {
  final String path;
  final String name;
  final DateTime modifiedAt;

  const LocalAudioTrack({
    required this.path,
    required this.name,
    required this.modifiedAt,
  });
}

class LocalAudioProvider {
  static final StreamController<int> _changes =
      StreamController<int>.broadcast();
  static int _changeTick = 0;

  static Stream<int> get changes => _changes.stream;

  static void notifyChanged() {
    if (_changes.isClosed) return;
    _changes.add(++_changeTick);
  }

  static const Set<String> _supportedExtensions = {
    '.mp3',
    '.m4a',
    '.aac',
    '.wav',
    '.flac',
    '.ogg',
    '.opus',
    '.webm',
  };

  static const List<String> _scanRoots = [
    '/storage/emulated/0/Music',
    '/storage/emulated/0/Download',
    '/storage/emulated/0/Downloads',
    '/storage/emulated/0/Podcasts',
    '/storage/emulated/0/Audiobooks',
  ];
  static const List<String> _excludedRoots = [
    '/storage/emulated/0/Download/Hongeet',
    '/storage/emulated/0/Downloads/Hongeet',
  ];
  static const int _maxDisplayNameLength = 90;

  static String _normalizePath(String path) {
    return p.normalize(path).replaceAll('\\', '/').toLowerCase();
  }

  static bool _isExcluded(String filePath) {
    final normalizedFile = _normalizePath(filePath);
    for (final excluded in _excludedRoots) {
      final normalizedExcluded = _normalizePath(excluded);
      if (normalizedFile == normalizedExcluded ||
          normalizedFile.startsWith('$normalizedExcluded/')) {
        return true;
      }
    }
    return false;
  }

  static String _toDisplayName(String path) {
    var base = p.basenameWithoutExtension(path);
    base = base.replaceAll(RegExp(r'[_]+'), ' ');
    base = base.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (base.length <= _maxDisplayNameLength) return base;
    return '${base.substring(0, _maxDisplayNameLength - 1)}…';
  }

  static Future<List<LocalAudioTrack>> load({int maxItems = 500}) async {
    final tracks = <LocalAudioTrack>[];
    final seenPaths = <String>{};

    for (final root in _scanRoots) {
      if (tracks.length >= maxItems) break;
      final dir = Directory(root);
      if (!await dir.exists()) continue;

      try {
        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (tracks.length >= maxItems) break;
          if (entity is! File) continue;

          final ext = p.extension(entity.path).toLowerCase();
          if (!_supportedExtensions.contains(ext)) continue;
          if (_isExcluded(entity.path)) continue;
          if (!seenPaths.add(entity.path)) continue;

          try {
            final stat = await entity.stat();
            tracks.add(
              LocalAudioTrack(
                path: entity.path,
                name: _toDisplayName(entity.path),
                modifiedAt: stat.modified,
              ),
            );
          } catch (_) {
            // Skip files that cannot be read/stat'ed.
          }
        }
      } catch (e) {
        AppLogger.warning('Local audio scan failed for $root: $e', error: e);
      }
    }

    tracks.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return tracks;
  }
}
