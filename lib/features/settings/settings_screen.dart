import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hongit/features/settings/about_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/glass_container.dart';
import '../../core/utils/glass_page.dart';
import '../../data/api/local_backend_api.dart';
import '../../core/utils/audio_player_service.dart';
import '../../core/utils/battery_optimization_handler.dart';

class SettingsScreen extends StatefulWidget {
  final ValueChanged<bool>? onMusicServiceChanged;

  const SettingsScreen({super.key, this.onMusicServiceChanged});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool showBatteryWarning = false;
  String manufacturer = '';

  bool _useYoutubeService = false;

  static const _remindAfterDays = 5;
  static const _lastPromptKey = 'battery_prompt_time';
  static const _firstSeenKey = 'battery_first_seen';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkBattery();
    _loadMusicServicePreference();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkBattery();
    }
  }

  Future<void> _checkBattery() async {
    final m = await BatteryOptimizationHelper.getManufacturer();
    final ignored = await BatteryOptimizationHelper.isIgnoringOptimizations();

    if (!BatteryOptimizationHelper.isAggressiveOEM(m)) return;

    final prefs = await SharedPreferences.getInstance();

    if (ignored) {
      await prefs.remove(_lastPromptKey);
      await prefs.remove(_firstSeenKey);

      if (!mounted) return;
      setState(() => showBatteryWarning = false);
      return;
    }

    final firstSeen = prefs.getBool(_firstSeenKey) ?? false;
    final lastPrompt = prefs.getInt(_lastPromptKey) ?? 0;

    final now = DateTime.now().millisecondsSinceEpoch;
    final daysPassed = (now - lastPrompt) ~/ Duration.millisecondsPerDay;

    if (!firstSeen) {
      await prefs.setBool(_firstSeenKey, true);
      await prefs.setInt(_lastPromptKey, now);

      if (!mounted) return;
      _showBatteryPopup(m);
    } else if (daysPassed >= _remindAfterDays) {
      await prefs.setInt(_lastPromptKey, now);

      if (!mounted) return;
      _showBatteryPopup(m);
    }

    if (!mounted) return;
    setState(() {
      manufacturer = m;
      showBatteryWarning = true;
    });
  }

  Future<void> _loadMusicServicePreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _useYoutubeService = prefs.getBool('use_youtube_service') ?? false;
    });
  }

  Future<void> _setMusicServicePreference(bool useYoutube) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_youtube_service', useYoutube);
    if (!mounted) return;
    setState(() {
      _useYoutubeService = useYoutube;
    });
    widget.onMusicServiceChanged?.call(useYoutube);
  }

  void _showBatteryPopup(String m) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Background playback may stop'),
        content: Text(
          '$m devices aggressively limit background apps.\n\n'
          'Disable battery optimization to keep Hongeet playing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              BatteryOptimizationHelper.requestDisableOptimization();
            },
            child: const Text('Fix now'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return GlassPage(
      child: ListView(
        children: [
          const Text(
            'Settings',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 20),

          if (showBatteryWarning) ...[
            GlassContainer(
              child: ListTile(
                leading: const Icon(Icons.battery_alert, color: Colors.orange),
                title: const Text('Background playback may stop'),
                subtitle: Text(
                  '$manufacturer devices aggressively limit background apps. '
                  'Disable battery optimization to keep Hongeet playing.',
                ),
                trailing: const Icon(Icons.open_in_new),
                onTap: () {
                  BatteryOptimizationHelper.requestDisableOptimization();
                },
              ),
            ),
            const SizedBox(height: 20),
          ],

          GlassContainer(
            child: ListTile(
              leading: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.heart_circle
                    : Icons.favorite_border,
              ),
              title: const Text('Backend Health'),
              subtitle: const Text('Tap to test local server'),
              onTap: () async {
                final res = await LocalBackendApi.health();
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(res.toString())));
              },
            ),
          ),

          const SizedBox(height: 12),

          GlassContainer(
            child: ListTile(
              leading: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.arrow_down_circle
                    : Icons.downloading,
              ),
              title: const Text('Download Health'),
              subtitle: const Text('Tap to test download server'),
              onTap: () async {
                try {
                  await LocalBackendApi.downloadSaavn(
                    title: 'Downloads Working!',
                    songId: '1ZDlyUiL',
                  );
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Download queued!')),
                  );
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Download failed: $e')),
                  );
                }
              },
            ),
          ),

          const SizedBox(height: 12),

          GlassContainer(
            child: SwitchListTile(
              value: themeProvider.useGlassTheme,
              onChanged: (_) => themeProvider.toggleTheme(),
              title: const Text('Glass UI Theme'),
              subtitle: const Text(
                'Use iOS 26 glass UI Theme. Might be laggy in some low-end mobiles.',
              ),
            ),
          ),

          const SizedBox(height: 12),

          GlassContainer(
            child: SwitchListTile(
              value: !_useYoutubeService,
              onChanged: (v) {
                if (v) _setMusicServicePreference(false);
              },
              title: const Text('Saavn Service'),
              subtitle: const Text('Use Saavn as the music Service'),
            ),
          ),

          const SizedBox(height: 12),

          GlassContainer(
            child: SwitchListTile(
              value: _useYoutubeService,
              onChanged: (v) {
                if (v) _setMusicServicePreference(true);
              },
              title: const Text('Youtube Service'),
              subtitle: const Text('Use Youtube as the music Service'),
            ),
          ),

          const SizedBox(height: 12),

          GlassContainer(
            child: ListTile(
              leading: const Icon(Icons.cached),
              title: const Text('Clear stream cache'),
              subtitle: const Text('Temporary streaming data'),
              onTap: () {
                if (AudioPlayerService().isPlaying) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Pause playback before clearing cache'),
                    ),
                  );
                  return;
                }
                AudioPlayerService().clearStreamCache();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Stream cache cleared')),
                );
              },
            ),
          ),

          const SizedBox(height: 12),

          GlassContainer(
            child: ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Clear recently played'),
              subtitle: const Text('Removes playback history'),
              onTap: () async {
                await AudioPlayerService().clearRecentlyPlayed();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Recently played cleared')),
                );
              },
            ),
          ),

          const SizedBox(height: 12),

          GlassContainer(
            child: ListTile(
              leading: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.info_circle
                    : Icons.info_outline,
              ),
              title: const Text('About'),
              subtitle: const Text('Version, licenses'),
              trailing: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.right_chevron
                    : Icons.chevron_right,
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const AboutScreen()),
                );
              },
            ),
          ),

          const SizedBox(height: 80),
        ],
      ),
    );
  }
}
