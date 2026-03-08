import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/responsive.dart';
import '../../core/utils/app_messenger.dart';
import '../../core/utils/audio_player_service.dart';
import '../../core/utils/themed_container.dart';
import '../../core/utils/themed_page.dart';
import '../player/mini_player.dart';
import 'downloaded_songs_provider.dart';
import 'local_audio_provider.dart';

class LocalAudiosScreen extends StatefulWidget {
  const LocalAudiosScreen({super.key});

  @override
  State<LocalAudiosScreen> createState() => _LocalAudiosScreenState();
}

class _LocalAudiosScreenState extends State<LocalAudiosScreen> {
  late Future<List<LocalAudioTrack>> _tracksFuture;
  StreamSubscription<int>? _downloadsChangeSub;
  StreamSubscription<int>? _localAudiosChangeSub;

  @override
  void initState() {
    super.initState();
    _tracksFuture = _loadWithPermission();
    _downloadsChangeSub = DownloadedSongsProvider.changes.listen((_) {
      if (!mounted) return;
      _refresh();
    });
    _localAudiosChangeSub = LocalAudioProvider.changes.listen((_) {
      if (!mounted) return;
      _refresh();
    });
  }

  @override
  void dispose() {
    _downloadsChangeSub?.cancel();
    _localAudiosChangeSub?.cancel();
    super.dispose();
  }

  Future<bool> _ensureAudioPermission() async {
    if (!Platform.isAndroid) return true;

    var audioStatus = await Permission.audio.status;
    if (audioStatus.isGranted || audioStatus.isLimited) {
      return true;
    }

    audioStatus = await Permission.audio.request();
    if (audioStatus.isGranted || audioStatus.isLimited) {
      return true;
    }

    var storageStatus = await Permission.storage.status;
    if (storageStatus.isGranted) return true;
    storageStatus = await Permission.storage.request();
    return storageStatus.isGranted;
  }

  Future<List<LocalAudioTrack>> _loadWithPermission() async {
    final granted = await _ensureAudioPermission();
    if (!granted) return const [];
    return LocalAudioProvider.load(maxItems: 500);
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _tracksFuture = _loadWithPermission();
    });
  }

  Widget _emptyState(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final player = AudioPlayerService();
    final textTheme = Theme.of(context).textTheme;

    return ThemedPage(
      child: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 140),
              children: [
                const SizedBox(height: 12),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        themeProvider.useGlassTheme
                            ? CupertinoIcons.back
                            : Icons.arrow_back,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Local Audios',
                        style: textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                FutureBuilder<List<LocalAudioTrack>>(
                  future: _tracksFuture,
                  builder: (_, snap) {
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final tracks = snap.data!;
                    if (tracks.isEmpty) {
                      return _emptyState('No local audio files found');
                    }

                    return Column(
                      children: tracks.asMap().entries.map((entry) {
                        final index = entry.key;
                        final track = entry.value;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: ThemedContainer(
                            child: ListTile(
                              leading: Icon(
                                themeProvider.useGlassTheme
                                    ? CupertinoIcons.music_note
                                    : Icons.music_note,
                              ),
                              title: Text(
                                track.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                track.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () {
                                // Build queue from all local audio tracks, starting at clicked track
                                player.playLocalFiles(
                                  files: tracks
                                      .map((t) => (path: t.path, name: t.name))
                                      .toList(),
                                  startIndex: index,
                                );
                                AppMessenger.show('Playing ${track.name}');
                              },
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: ResponsiveLayout.isExpanded(context)
                      ? 760
                      : double.infinity,
                ),
                child: const MiniPlayer(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
