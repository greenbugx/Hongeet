import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/data_saver_settings.dart';
import 'core/utils/permission_manager.dart';
import 'package:audio_service/audio_service.dart';
import 'core/utils/background_audio_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await DataSaverSettings.init();
  await PermissionManager.requestStartupPermissions();

  await AudioService.init(
    builder: () => BackgroundAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.dxku.hongit.music',
      androidNotificationChannelName: 'Hongeet Playback',
      androidNotificationOngoing: true,
    ),
  );

  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const MusicApp(),
    ),
  );
}
