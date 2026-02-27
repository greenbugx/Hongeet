import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongit/core/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'use_glass_theme': false,
      'progress_bar_style': 'defaultStyle',
      'ui_performance_mode': 'auto',
    });
  });

  testWidgets('ThemeProvider loads default dark theme', (WidgetTester tester) async {
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

  testWidgets('ThemeProvider can switch to glass theme', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'use_glass_theme': false,
      'progress_bar_style': 'defaultStyle',
      'ui_performance_mode': 'auto',
    });

    final provider = ThemeProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>.value(
        value: provider,
        child: Builder(
          builder: (context) {
            final active = Provider.of<ThemeProvider>(context);
            return MaterialApp(
              theme: active.currentTheme,
              home: Scaffold(
                body: Text(
                  active.useGlassTheme ? 'glass' : 'simple',
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('simple'), findsOneWidget);

    await provider.setUseGlassTheme(true);
    await tester.pumpAndSettle();

    expect(find.text('glass'), findsOneWidget);
    final context = tester.element(find.text('glass'));
    final theme = Theme.of(context);
    expect(theme.scaffoldBackgroundColor, Colors.transparent);
  });
}
