import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/data_saver_settings.dart';
import 'core/utils/streaming_preferences.dart';
import 'core/utils/permission_manager.dart';
import 'package:audio_service/audio_service.dart';
import 'core/utils/background_audio_handler.dart';
import 'core/utils/presence_bridge.dart';
import 'package:app_links/app_links.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await DataSaverSettings.init();
  await StreamingPreferences.load();
  await PermissionManager.requestStartupPermissions();

  await AudioService.init(
    builder: () => BackgroundAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.dxku.hongit.music',
      androidNotificationChannelName: 'Hongeet Playback',
      androidNotificationOngoing: true,
    ),
  );

  PresenceBridge.instance.start();

  // Handle Android App Links -> opens Hongeet when user clicks
  // the Discord "Listen on Hongeet" button and the app is installed
  // If not installed, the URL falls through to the browser instead
  AppLinks().uriLinkStream.listen((_) {
    // App is already open -> nothing to navigate to, just bring to foreground
    // TODO: Extended logic for deep-linking to the playing song (planned for later versions, maybe :) )
  });

  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const MusicApp(),
    ),
  );
}
