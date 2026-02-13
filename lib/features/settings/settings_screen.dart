import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hongit/features/settings/about_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/glass_container.dart';
import '../../core/utils/glass_page.dart';
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

    if (!BatteryOptimizationHelper.isAggressiveOEM(m)) {
      if (!mounted) return;
      setState(() {
        manufacturer = m;
        showBatteryWarning = false;
      });
      return;
    }

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
            onPressed: () async {
              Navigator.pop(context);
              await _requestBatteryOptimizationFix();
            },
            child: const Text('Fix now'),
          ),
        ],
      ),
    );
  }

  Future<void> _requestBatteryOptimizationFix() async {
    final launched =
        await BatteryOptimizationHelper.requestDisableOptimization();
    if (!mounted) return;
    if (!launched) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open battery settings on this device'),
        ),
      );
      return;
    }

    Future<void>.delayed(const Duration(milliseconds: 600), _checkBattery);
  }

  bool _canUseGlassTheme(BuildContext context) {
    return !ThemeProvider.isLowEndLikely(context);
  }

  String _progressBarStyleLabel(ProgressBarStyle style) {
    switch (style) {
      case ProgressBarStyle.defaultStyle:
        return 'Default';
      case ProgressBarStyle.snake:
        return 'Snake';
      case ProgressBarStyle.glass:
        return 'Glass';
    }
  }

  String _progressBarStyleHint(ProgressBarStyle style) {
    switch (style) {
      case ProgressBarStyle.defaultStyle:
        return 'Standard seek bar';
      case ProgressBarStyle.snake:
        return 'Curved static track with moving head';
      case ProgressBarStyle.glass:
        return 'Glass-styled seek bar';
    }
  }

  String _uiPerformanceLabel(UiPerformanceMode mode) {
    switch (mode) {
      case UiPerformanceMode.auto:
        return 'Auto';
      case UiPerformanceMode.smooth:
        return 'Smooth';
      case UiPerformanceMode.full:
        return 'Full';
    }
  }

  String _uiPerformanceHint(ThemeProvider themeProvider, BuildContext context) {
    if (themeProvider.useGlassTheme) {
      return 'This setting makes no change when Glass Theme is enabled.';
    }

    final resolved = themeProvider.resolvedUiPerformanceMode(context);
    switch (themeProvider.uiPerformanceMode) {
      case UiPerformanceMode.auto:
        return 'Auto-selected: ${_uiPerformanceLabel(resolved)}';
      case UiPerformanceMode.smooth:
        return 'Lower motion and lighter rendering';
      case UiPerformanceMode.full:
        return 'Best visual quality and motion';
    }
  }

  List<ProgressBarStyle> _availableProgressStyles(ThemeProvider themeProvider) {
    if (themeProvider.useGlassTheme) {
      return ProgressBarStyle.values;
    }
    return const [ProgressBarStyle.defaultStyle, ProgressBarStyle.snake];
  }

  String _dataSaverDescription(bool enabled) {
    return enabled
        ? 'Enabled: streams use up to ~120 kbps and artwork uses lower-medium quality to reduce data usage.'
        : 'Disabled: uses best available audio quality and high-resolution artwork.';
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final canUseGlassTheme = _canUseGlassTheme(context);

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
                onTap: () async {
                  await _requestBatteryOptimizationFix();
                },
              ),
            ),
            const SizedBox(height: 20),
          ],

          GlassContainer(
            child: SwitchListTile(
              value: themeProvider.useGlassTheme,
              onChanged: (enabled) {
                if (enabled && !canUseGlassTheme) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Glass theme may feel laggy on this device.',
                      ),
                    ),
                  );
                }
                themeProvider.setUseGlassTheme(enabled);
              },
              secondary: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.settings
                    : Icons.blur_on,
              ),
              title: const Text('Glass UI Theme'),
              subtitle: Text(
                canUseGlassTheme
                    ? 'Use iOS 26 glass UI Theme.'
                    : 'May lag on low-end devices.',
              ),
            ),
          ),

          const SizedBox(height: 12),

          GlassContainer(
            child: ListTile(
              leading: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.speedometer
                    : Icons.speed,
              ),
              title: const Text('UI performance'),
              subtitle: Text(_uiPerformanceHint(themeProvider, context)),
              trailing: DropdownButtonHideUnderline(
                child: DropdownButton<UiPerformanceMode>(
                  value: themeProvider.uiPerformanceMode,
                  isDense: true,
                  onChanged: themeProvider.useGlassTheme
                      ? null
                      : (mode) {
                          if (mode != null) {
                            themeProvider.setUiPerformanceMode(mode);
                          }
                        },
                  items: UiPerformanceMode.values
                      .map(
                        (mode) => DropdownMenuItem<UiPerformanceMode>(
                          value: mode,
                          child: Text(_uiPerformanceLabel(mode)),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          GlassContainer(
            child: ListTile(
              leading: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.waveform_path_ecg
                    : Icons.multitrack_audio,
              ),
              title: const Text('Progress bar style'),
              subtitle: Text(
                _progressBarStyleHint(themeProvider.effectiveProgressBarStyle),
              ),
              trailing: DropdownButtonHideUnderline(
                child: DropdownButton<ProgressBarStyle>(
                  value: themeProvider.effectiveProgressBarStyle,
                  isDense: true,
                  onChanged: (style) {
                    if (style != null) {
                      themeProvider.setProgressBarStyle(style);
                    }
                  },
                  items: _availableProgressStyles(themeProvider)
                      .map(
                        (style) => DropdownMenuItem<ProgressBarStyle>(
                          value: style,
                          child: Text(_progressBarStyleLabel(style)),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          GlassContainer(
            child: SwitchListTile(
              value: themeProvider.dataSaverEnabled,
              onChanged: (enabled) {
                themeProvider.setDataSaverEnabled(enabled);
              },
              secondary: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.antenna_radiowaves_left_right
                    : Icons.data_saver_on,
              ),
              title: const Text('Data Saver'),
              subtitle: Text(
                _dataSaverDescription(themeProvider.dataSaverEnabled),
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
              secondary: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.music_albums
                    : Icons.library_music,
              ),
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
              secondary: Icon(
                themeProvider.useGlassTheme
                    ? CupertinoIcons.play_circle
                    : Icons.smart_display,
              ),
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
                if (!context.mounted) return;
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
              subtitle: const Text('Version, license'),
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
