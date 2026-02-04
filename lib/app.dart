import 'package:flutter/material.dart';
import 'package:hongit/core/theme/app_theme.dart';
import 'package:hongit/core/utils/app_messenger.dart';
import 'package:hongit/features/home/home_screen.dart';
import 'package:provider/provider.dart';

class MusicApp extends StatelessWidget {
  const MusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return MaterialApp(
          navigatorKey: AppMessenger.navigatorKey,
          debugShowCheckedModeBanner: false,
          title: 'Music',
          theme: themeProvider.currentTheme,
          home: const HomeScreen(),
        );
      },
    );
  }
}