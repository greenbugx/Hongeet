import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/utils/themed_page.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final siteUri = Uri.parse('https://greenbugx.github.io/Hongeet/');
    final githubUri = Uri.parse('https://github.com/greenbugx/Hongeet');
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final logoSize = (MediaQuery.sizeOf(context).width * 0.42).clamp(
      140.0,
      220.0,
    );

    return ThemedPage(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Column(
                children: [
                  Image.asset(
                    'assets/app/icon_fg.webp',
                    width: logoSize.toDouble(),
                    height: logoSize.toDouble(),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => Image.asset(
                      'assets/icon/icon_fg.png',
                      width: logoSize.toDouble(),
                      height: logoSize.toDouble(),
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'HONGEET',
                    style: textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Dev: Dxku',
                    style: textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: () async {
                    await launchUrl(
                      siteUri,
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Visit Website'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    await launchUrl(
                      githubUri,
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  icon: const Icon(Icons.code),
                  label: const Text('View Source'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                'v1.7.0+18',
                style: textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'A simple yet powerful music player designed for seamless streaming of your favorite songs. Enjoy a smooth, distraction-free listening experience with no ads, no interruptions, and a clean interface built for music lovers.',
                  style: textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'This app is open source and available on Github and licensed under the GNU-AGPLv3.0-or-later',
                  style: textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
