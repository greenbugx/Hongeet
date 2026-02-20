import 'package:flutter/material.dart';

class SleepTimerOverlayScreen extends StatelessWidget {
  final bool endOfCurrentSong;

  const SleepTimerOverlayScreen({super.key, this.endOfCurrentSong = false});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).maybePop(),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.nightlight_round,
                    size: 150,
                    color: Colors.white,
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Sleep Timer Active',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    endOfCurrentSong
                        ? 'Playback stopped after current song.'
                        : 'Playback stopped by sleep timer.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 15, color: Colors.white70),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Tap anywhere to continue',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.white54),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
