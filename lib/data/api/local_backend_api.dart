import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../core/utils/download_path_helper.dart';
import 'saavn_song_api.dart';

class LocalBackendApi {
  static const String baseUrl = 'http://127.0.0.1:8080';

  static Future<Map<String, dynamic>> health() async {
    final res = await http.get(Uri.parse('$baseUrl/health'));

    if (res.statusCode != 200) {
      throw Exception('Backend not reachable');
    }

    return json.decode(res.body);
  }

  static Future<void> downloadSaavn({
    required String title,
    required String songId,
  }) async {
    if (Platform.isAndroid) {
      final res = await http.post(
        Uri.parse('$baseUrl/download/saavn'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'title': title,
          'songId': songId,
        }),
      );

      if (res.statusCode != 200) {
        throw Exception('Download failed: ${res.body}');
      }
      return;
    }

    final streamUrl = await SaavnSongApi.fetchBestStreamUrl(songId);
    await _downloadToFile(title: title, url: streamUrl, headers: const {});
  }

  static Future<void> downloadDirect({
    required String title,
    required String url,
    Map<String, String> headers = const {},
  }) async {
    if (Platform.isAndroid) {
      final res = await http.post(
        Uri.parse('$baseUrl/download/direct'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'title': title,
          'url': url,
          'headers': headers,
        }),
      );

      if (res.statusCode != 200) {
        throw Exception('Direct download failed: ${res.body}');
      }
      return;
    }

    await _downloadToFile(title: title, url: url, headers: headers);
  }

  static Future<void> _downloadToFile({
    required String title,
    required String url,
    required Map<String, String> headers,
  }) async {
    final dir = DownloadPathHelper.primaryDirectory();
    await dir.create(recursive: true);

    final uri = Uri.parse(url);
    final request = http.Request('GET', uri);
    request.headers.addAll(headers);

    final client = http.Client();
    try {
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode} while downloading');
      }

      final ext = _resolveExtension(
        contentType: response.headers['content-type'],
        urlPath: uri.path,
      );
      final baseName = _sanitizeFileName(title);
      final file = await _nextAvailableFile(
        directoryPath: dir.path,
        baseName: baseName,
        extension: ext,
      );

      final sink = file.openWrite();
      try {
        await response.stream.pipe(sink);
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }

  static Future<File> _nextAvailableFile({
    required String directoryPath,
    required String baseName,
    required String extension,
  }) async {
    var candidate = File(p.join(directoryPath, '$baseName$extension'));
    var count = 2;
    while (await candidate.exists()) {
      candidate = File(p.join(directoryPath, '$baseName ($count)$extension'));
      count++;
    }
    return candidate;
  }

  static String _resolveExtension({
    required String? contentType,
    required String urlPath,
  }) {
    final extFromPath = p.extension(Uri.decodeComponent(urlPath)).toLowerCase();
    if (_isKnownAudioExtension(extFromPath)) return extFromPath;

    final type = (contentType ?? '').toLowerCase();
    if (type.contains('audio/webm')) return '.webm';
    if (type.contains('audio/mp4') || type.contains('audio/m4a')) return '.m4a';
    if (type.contains('audio/ogg')) return '.ogg';
    if (type.contains('audio/aac')) return '.aac';
    if (type.contains('audio/mpeg')) return '.mp3';

    return '.mp3';
  }

  static bool _isKnownAudioExtension(String extension) {
    return extension == '.mp3' ||
        extension == '.m4a' ||
        extension == '.webm' ||
        extension == '.ogg' ||
        extension == '.aac' ||
        extension == '.wav' ||
        extension == '.flac' ||
        extension == '.opus';
  }

  static String _sanitizeFileName(String input) {
    var name = input.trim();
    if (name.isEmpty) {
      name = 'track_${DateTime.now().millisecondsSinceEpoch}';
    }

    name = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();

    while (name.endsWith('.') || name.endsWith(' ')) {
      name = name.substring(0, name.length - 1).trimRight();
      if (name.isEmpty) break;
    }

    if (name.isEmpty) {
      name = 'track_${DateTime.now().millisecondsSinceEpoch}';
    }

    if (name.length > 120) {
      name = name.substring(0, 120).trim();
    }

    const reserved = <String>{
      'CON',
      'PRN',
      'AUX',
      'NUL',
      'COM1',
      'COM2',
      'COM3',
      'COM4',
      'COM5',
      'COM6',
      'COM7',
      'COM8',
      'COM9',
      'LPT1',
      'LPT2',
      'LPT3',
      'LPT4',
      'LPT5',
      'LPT6',
      'LPT7',
      'LPT8',
      'LPT9',
    };

    if (reserved.contains(name.toUpperCase())) {
      name = '_$name';
    }

    return name;
  }
}
