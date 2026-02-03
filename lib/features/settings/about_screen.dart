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
                Text('HONGEET', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                SizedBox(height: 16),
                Text('Dev: Dxku', style: TextStyle(fontSize: 22)),
                SizedBox(height: 8),
                Text('v1.1.0+3', style: TextStyle(fontSize: 16)),
                SizedBox(height: 10),
                Text('A Simple yet useful music player for streaming your favorite songs without any ads.', style: TextStyle(fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
