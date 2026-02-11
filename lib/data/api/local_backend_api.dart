import 'dart:convert';
import 'package:http/http.dart' as http;

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
  }

  static Future<void> downloadDirect({
    required String title,
    required String url,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/download/direct'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'title': title,
        'url': url,
      }),
    );

    if (res.statusCode != 200) {
      throw Exception('Direct download failed: ${res.body}');
    }
  }
}