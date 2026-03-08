import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongit/core/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'theme_seed_color': AppTheme.defaultSeedColor.toARGB32(),
      'progress_bar_style': 'defaultStyle',
      'ui_performance_mode': 'auto',
    });
  });

  testWidgets('ThemeProvider loads default dark theme', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: Builder(
          builder: (context) {
            final provider = Provider.of<ThemeProvider>(context);
            return MaterialApp(
              theme: provider.currentTheme,
              home: const Scaffold(body: Text('ready')),
            );
          },
        ),
      ),
    );

    await tester.pumpAndSettle();

    final context = tester.element(find.text('ready'));
    final theme = Theme.of(context);
    expect(theme.brightness, Brightness.dark);
    expect(find.text('ready'), findsOneWidget);
  });

  testWidgets('ThemeProvider can update Material 3 seed color', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'theme_seed_color': AppTheme.defaultSeedColor.toARGB32(),
      'progress_bar_style': 'defaultStyle',
      'ui_performance_mode': 'auto',
    });

    final provider = ThemeProvider();
    const updatedSeed = Color(0xFFE57373);
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>.value(
        value: provider,
        child: Builder(
          builder: (context) {
            final active = Provider.of<ThemeProvider>(context);
            return MaterialApp(
              theme: active.currentTheme,
              home: Scaffold(
                body: Text(active.seedColor.toARGB32().toString()),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final defaultSeedText = AppTheme.defaultSeedColor.toARGB32().toString();
    expect(find.text(defaultSeedText), findsOneWidget);

    await provider.setSeedColor(updatedSeed);
    await tester.pumpAndSettle();

    final updatedSeedText = updatedSeed.toARGB32().toString();
    expect(find.text(updatedSeedText), findsOneWidget);
    final context = tester.element(find.text(updatedSeedText));
    final theme = Theme.of(context);
    expect(provider.seedColor.toARGB32(), updatedSeed.toARGB32());
    expect(theme.brightness, Brightness.dark);
  });
}
