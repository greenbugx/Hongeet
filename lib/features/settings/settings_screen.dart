import 'package:flutter/material.dart';
import 'package:hongit/features/settings/about_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/themed_container.dart';
import '../../core/utils/streaming_preferences.dart';
import '../../core/utils/themed_page.dart';
import '../../core/utils/audio_player_service.dart';
import '../../core/utils/app_update_service.dart';
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
  bool _useSaavnService = false;

  static const _remindAfterDays = 5;
  static const _lastPromptKey = 'battery_prompt_time';
  static const _firstSeenKey = 'battery_first_seen';

  static const List<Color> _presetThemeColors = <Color>[
    Color(0xFF28C76F),
    Color(0xFF00BFA6),
    Color(0xFF1E88E5),
    Color(0xFF3F51B5),
    Color(0xFF8E24AA),
    Color(0xFFD81B60),
    Color(0xFFFB8C00),
    Color(0xFFFDD835),
  ];

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
      _useSaavnService = prefs.getBool('use_saavn_service') ?? false;
    });
  }

  Future<void> _setYoutubeServicePreference(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_youtube_service', enabled);
    if (enabled) {
      await prefs.setBool('use_saavn_service', false);
      final currentMode = prefs.getString('app_mode');
      if (currentMode == 'local') {
        await prefs.setString('app_mode', 'ytm');
      }
    }
    if (!mounted) return;
    setState(() {
      _useYoutubeService = enabled;
      if (enabled) _useSaavnService = false;
    });
    await StreamingPreferences.reload();
    widget.onMusicServiceChanged?.call(enabled);
  }

  Future<void> _setSaavnServicePreference(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_saavn_service', enabled);
    if (enabled) {
      await prefs.setBool('use_youtube_service', false);
      final currentMode = prefs.getString('app_mode');
      if (currentMode == 'local') {
        await prefs.setString('app_mode', 'saavn');
      }
    }
    if (!mounted) return;
    setState(() {
      _useSaavnService = enabled;
      if (enabled) _useYoutubeService = false;
    });
    await StreamingPreferences.reload();
    widget.onMusicServiceChanged?.call(enabled);
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

  String _progressBarStyleLabel(ProgressBarStyle style) {
    switch (style) {
      case ProgressBarStyle.defaultStyle:
        return 'Default';
      case ProgressBarStyle.snake:
        return 'Snake';
    }
  }

  String _progressBarStyleHint(ProgressBarStyle style) {
    switch (style) {
      case ProgressBarStyle.defaultStyle:
        return 'Standard seek bar';
      case ProgressBarStyle.snake:
        return 'Curved static track with moving head';
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

  String _dataSaverDescription(bool enabled) {
    return enabled
        ? 'Enabled: streams use up to ~120 kbps and artwork uses lower-medium quality to reduce data usage.'
        : 'Disabled: uses best available audio quality and high-resolution artwork.';
  }

  Future<void> _checkForUpdatesManually() async {
    try {
      final result = await AppUpdateService().checkForUpdates();
      if (!mounted) return;

      if (!result.hasUpdate) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You are already on the latest version'),
          ),
        );
        return;
      }

      await showUpdateDialog(context, result);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not check updates right now')),
      );
    }
  }

  Future<void> _showColorPickerDialog(ThemeProvider themeProvider) async {
    int red = themeProvider.seedColor.r.toInt();
    int green = themeProvider.seedColor.g.toInt();
    int blue = themeProvider.seedColor.b.toInt();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            final preview = Color.fromARGB(255, red, green, blue);

            Widget buildSlider({
              required String label,
              required int value,
              required ValueChanged<double> onChanged,
              required Color activeColor,
            }) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$label: $value'),
                  Slider(
                    min: 0,
                    max: 255,
                    value: value.toDouble(),
                    activeColor: activeColor,
                    onChanged: onChanged,
                  ),
                ],
              );
            }

            return AlertDialog(
              title: const Text('Custom Theme Color'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: double.infinity,
                      height: 64,
                      decoration: BoxDecoration(
                        color: preview,
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    const SizedBox(height: 16),
                    buildSlider(
                      label: 'Red',
                      value: red,
                      activeColor: Colors.red,
                      onChanged: (v) =>
                          setStateDialog(() => red = v.round().clamp(0, 255)),
                    ),
                    buildSlider(
                      label: 'Green',
                      value: green,
                      activeColor: Colors.green,
                      onChanged: (v) =>
                          setStateDialog(() => green = v.round().clamp(0, 255)),
                    ),
                    buildSlider(
                      label: 'Blue',
                      value: blue,
                      activeColor: Colors.blue,
                      onChanged: (v) =>
                          setStateDialog(() => blue = v.round().clamp(0, 255)),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    await themeProvider.setSeedColor(preview);
                    if (!dialogContext.mounted) return;
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildThemeColorSection(
    BuildContext context,
    ThemeProvider themeProvider,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final selected = themeProvider.seedColor.toARGB32();

    return ThemedContainer(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.palette_outlined, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Theme color',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: themeProvider.seedColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.65),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _presetThemeColors.map((color) {
                final isSelected = color.toARGB32() == selected;
                return InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => themeProvider.setSeedColor(color),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: isSelected ? 38 : 34,
                    height: isSelected ? 38 : 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color,
                      border: Border.all(
                        color: isSelected
                            ? scheme.onSurface
                            : scheme.outlineVariant.withValues(alpha: 0.55),
                        width: isSelected ? 2 : 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _showColorPickerDialog(themeProvider),
              icon: const Icon(Icons.tune),
              label: const Text('Custom color'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return ThemedPage(
      child: ListView(
        children: [
          Text(
            'Settings',
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 20),

          if (showBatteryWarning) ...[
            ThemedContainer(
              child: ListTile(
                leading: Icon(Icons.battery_alert, color: scheme.tertiary),
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

          ThemedContainer(
            child: ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: const Text('Check for updates'),
              subtitle: const Text('Check latest version and update now'),
              onTap: _checkForUpdatesManually,
            ),
          ),

          const SizedBox(height: 12),

          _buildThemeColorSection(context, themeProvider),

          const SizedBox(height: 12),

          ThemedContainer(
            child: ListTile(
              leading: const Icon(Icons.speed),
              title: const Text('UI performance'),
              subtitle: Text(_uiPerformanceHint(themeProvider, context)),
              trailing: DropdownButtonHideUnderline(
                child: DropdownButton<UiPerformanceMode>(
                  value: themeProvider.uiPerformanceMode,
                  isDense: true,
                  onChanged: (mode) {
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

          ThemedContainer(
            child: ListTile(
              leading: const Icon(Icons.multitrack_audio),
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
                  items: ProgressBarStyle.values
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

          ThemedContainer(
            child: SwitchListTile(
              value: themeProvider.dataSaverEnabled,
              onChanged: (enabled) {
                themeProvider.setDataSaverEnabled(enabled);
              },
              secondary: const Icon(Icons.data_saver_on),
              title: const Text('Data Saver'),
              subtitle: Text(
                _dataSaverDescription(themeProvider.dataSaverEnabled),
              ),
            ),
          ),

          const SizedBox(height: 12),

          ThemedContainer(
            child: SwitchListTile(
              value: _useSaavnService,
              onChanged: (v) {
                _setSaavnServicePreference(v);
              },
              secondary: const Icon(Icons.library_music),
              title: const Text('Saavn Service'),
              subtitle: const Text('Use Saavn as the music Service'),
            ),
          ),

          const SizedBox(height: 12),

          ThemedContainer(
            child: SwitchListTile(
              value: _useYoutubeService,
              onChanged: (v) {
                _setYoutubeServicePreference(v);
              },
              secondary: const Icon(Icons.smart_display),
              title: const Text('Youtube Service'),
              subtitle: const Text('Use Youtube as the music Service'),
            ),
          ),

          const SizedBox(height: 12),

          ThemedContainer(
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

          ThemedContainer(
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

          ThemedContainer(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              subtitle: const Text('Version, license'),
              trailing: const Icon(Icons.chevron_right),
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
