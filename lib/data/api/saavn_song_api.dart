import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/utils/data_saver_settings.dart';

class SaavnSongApi {
  static const String baseUrl = 'http://127.0.0.1:8080';

  /// Returns a stream URL from downloadUrl[] (quality depends on Data Saver).
  static Future<String> fetchBestStreamUrl(String songId) async {
    final res = await http.get(Uri.parse('$baseUrl/song/saavn/$songId'));

    if (res.statusCode != 200) {
      throw Exception('Failed to fetch song details');
    }

    final decoded = json.decode(res.body);
    final data = decoded['data'] as List;
    if (data.isEmpty) throw Exception('No song data');

    final song = data.first;
    final urls = song['downloadUrl'] as List? ?? [];
    if (urls.isEmpty) throw Exception('No stream URLs');

    final dataSaver = await _isDataSaverEnabled();
    final best = _pickPreferredUrl(urls, dataSaver: dataSaver);
    final url = (best['url'] ?? '').toString().trim();
    if (url.isEmpty) throw Exception('No valid stream URL');
    return url;
  }

  static Future<bool> _isDataSaverEnabled() async {
    if (DataSaverSettings.isEnabled) return true;
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(DataSaverSettings.prefKey) ?? false;
    DataSaverSettings.setInMemory(enabled);
    return enabled;
  }

  static Map<String, dynamic> _pickPreferredUrl(
    List<dynamic> rawUrls, {
    required bool dataSaver,
  }) {
    final entries = <Map<String, dynamic>>[];
    for (final entry in rawUrls) {
      if (entry is Map) {
        entries.add(entry.map((key, value) => MapEntry('$key', value)));
      }
    }

    if (entries.isEmpty) {
      throw Exception('No stream URLs');
    }

    entries.sort((a, b) => _qualityScore(a).compareTo(_qualityScore(b)));

    if (!dataSaver) {
      return entries.last;
    }

    Map<String, dynamic>? preferred;
    for (final entry in entries) {
      final quality = _qualityScore(entry);
      if (quality <= 120 && quality > 0) {
        preferred = entry;
      }
    }

    return preferred ?? entries.first;
  }

  static int _qualityScore(Map<String, dynamic> entry) {
    final raw = (entry['quality'] ?? '').toString().toLowerCase();
    final match = RegExp(r'(\d{2,4})').firstMatch(raw);
    if (match != null) {
      return int.tryParse(match.group(1)!) ?? 0;
    }
    return 0;
  }
}
