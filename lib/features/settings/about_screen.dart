import 'package:flutter/material.dart';
import '../../core/utils/glass_page.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Center(
            child: Column(
              children: [
                Text(
                  'HONGEET',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 16),
                Text('Dev: Dxku', style: TextStyle(fontSize: 22)),
                SizedBox(height: 8),
                Text('v1.3.1+9', style: TextStyle(fontSize: 16)),
                SizedBox(height: 10),
                Text(
                  'A simple yet powerful music player designed for seamless streaming of your favorite songs. Enjoy a smooth, distraction-free listening experience with no ads, no interruptions, and a clean interface built for music lovers.',
                  style: TextStyle(fontSize: 14),
                ),
                SizedBox(height: 16),
                Text(
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
