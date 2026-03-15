import 'dart:io';

import 'package:path/path.dart' as p;

class DownloadPathHelper {
  static const String folderName = 'Hongeet';

  static List<Directory> candidateDirectories() {
    if (Platform.isAndroid) {
      return <Directory>[
        Directory('/storage/emulated/0/Download/$folderName'),
        Directory('/storage/emulated/0/Downloads/$folderName'),
      ];
    }

    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE']?.trim();
      if (userProfile != null && userProfile.isNotEmpty) {
        return <Directory>[Directory(p.join(userProfile, 'Music', folderName))];
      }
    }

    final home = Platform.environment['HOME']?.trim();
    if (home != null && home.isNotEmpty) {
      return <Directory>[Directory(p.join(home, 'Music', folderName))];
    }

    return <Directory>[Directory(p.join(Directory.systemTemp.path, folderName))];
  }

  static Directory primaryDirectory() {
    final dirs = candidateDirectories();
    return dirs.first;
  }

  static bool isDownloadedPath(String filePath) {
    final normalizedFilePath = _normalizePath(filePath);
    for (final dir in candidateDirectories()) {
      final normalizedDir = _normalizePath(dir.path);
      final prefix = normalizedDir.endsWith('/')
          ? normalizedDir
          : '$normalizedDir/';
      if (normalizedFilePath == normalizedDir ||
          normalizedFilePath.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  static String _normalizePath(String value) {
    return value.replaceAll('\\', '/').toLowerCase();
  }
}

