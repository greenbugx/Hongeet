import 'dart:convert';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PlaylistManager {
  static const _key = 'playlists';
  static const String systemFavourites = 'Favourite Songs';

  static final BehaviorSubject<Map<String, List<Map<String, dynamic>>>>
      _subject = BehaviorSubject.seeded({});

  static Stream<Map<String, List<Map<String, dynamic>>>> get stream =>
      _subject.stream;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);

    Map<String, List<Map<String, dynamic>>> map = {};

    if (raw != null) {
      map = Map<String, List<Map<String, dynamic>>>.from(
        jsonDecode(raw).map(
          (k, v) => MapEntry(k, List<Map<String, dynamic>>.from(v)),
        ),
      );
    }

    map.putIfAbsent(systemFavourites, () => []);

    await _save(map);
  }

  static bool isFavourite(String songId) {
    return _subject.value[systemFavourites]?.any((e) => e['id'] == songId) ??
        false;
  }

  static Future<void> toggleFavourite(Map<String, dynamic> song) async {
    final map = Map<String, List<Map<String, dynamic>>>.from(_subject.value);

    final favs = map[systemFavourites]!;

    final exists = favs.any((e) => e['id'] == song['id']);

    if (exists) {
      favs.removeWhere((e) => e['id'] == song['id']);
    } else {
      favs.add(song);
    }

    await _save(map);
  }

  static Future<void> create(String name) async {
    final map = Map<String, List<Map<String, dynamic>>>.from(_subject.value);
    map[name] = [];
    await _save(map);
  }

  static Future<void> addSong(
    String playlist,
    Map<String, dynamic> song,
  ) async {
    final map = Map<String, List<Map<String, dynamic>>>.from(_subject.value);

    final list = map[playlist] ?? [];

    list.removeWhere((e) => e['id'] == song['id']);
    list.add(song);

    map[playlist] = list;
    await _save(map);
  }

  static Future<void> _save(Map<String, List<Map<String, dynamic>>> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(map));
    _subject.add(map);
  }

  static List<Map<String, dynamic>> getSongs(String playlist) {
    return List<Map<String, dynamic>>.from(
      _subject.value[playlist] ?? [],
    );
  }
}
