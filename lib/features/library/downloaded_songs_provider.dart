import 'dart:io';
import 'dart:async';
import 'package:path/path.dart' as p;
import '../../core/utils/app_logger.dart';

class DownloadedSong {
  final String path;
  final String name;

  DownloadedSong(this.path, this.name);
}

class DownloadedSongsProvider {
  static final StreamController<int> _changes =
      StreamController<int>.broadcast();
  static int _changeTick = 0;

  static Stream<int> get changes => _changes.stream;

  static void _notifyChanged() {
    if (_changes.isClosed) return;
    _changes.add(++_changeTick);
  }

  static Future<List<DownloadedSong>> load() async {
    final dir = Directory('/storage/emulated/0/Download/Hongeet');

    if (!await dir.exists()) return [];

    final files = dir.listSync().whereType<File>().where((f) {
      final ext = p.extension(f.path).toLowerCase();
      return ['.mp3', '.m4a', '.webm'].contains(ext);
    }).toList();

    return files
        .map((f) => DownloadedSong(f.path, p.basenameWithoutExtension(f.path)))
        .toList();
  }

  static Future<void> delete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        _notifyChanged();
      }
    } catch (e) {
      AppLogger.warning('Error deleting file: $e', error: e);
    }
  }
}
