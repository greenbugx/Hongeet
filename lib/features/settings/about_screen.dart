import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/utils/glass_page.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final siteUri = Uri.parse('https://greenbugx.github.io/Hongeet/');
    final githubUri = Uri.parse('https://github.com/greenbugx/Hongeet');
    final logoSize = (MediaQuery.sizeOf(context).width * 0.42).clamp(
      140.0,
      220.0,
    );

    return GlassPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
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
                const Text(
                  'HONGEET',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                const Text('Dev: Dxku', style: TextStyle(fontSize: 22)),
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
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
                    FilledButton.icon(
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
                const SizedBox(height: 8),
                const Text('v1.3.2+12', style: TextStyle(fontSize: 16)),
                const SizedBox(height: 10),
                const Text(
                  'A simple yet powerful music player designed for seamless streaming of your favorite songs. Enjoy a smooth, distraction-free listening experience with no ads, no interruptions, and a clean interface built for music lovers.',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 16),
                const Text(
                  'This app is open source and available on Github and licensed under the GPLv3.0',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
