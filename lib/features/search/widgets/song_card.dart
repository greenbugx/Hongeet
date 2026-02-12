import 'package:flutter/material.dart';
import '../../../core/utils/glass_container.dart';
import '../../../data/models/saavn_song.dart';

class SongCard extends StatelessWidget {
  final SaavnSong song;
  final VoidCallback? onTap;

  const SongCard({super.key, required this.song, this.onTap});

  @override
  Widget build(BuildContext context) {
    final imageUrl = song.imageUrl.trim();

    return GlassContainer(
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Album Art
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                clipBehavior: Clip.antiAlias,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(18),
                ),
                child: imageUrl.isNotEmpty
                    ? Transform.scale(
                        scale: 2.0,
                        child: Image.network(
                          imageUrl,
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (_, error, stackTrace) => Container(
                            color: Colors.black26,
                            child: const Icon(
                              Icons.music_note_rounded,
                              size: 40,
                            ),
                          ),
                        ),
                      )
                    : Container(
                        color: Colors.black26,
                        child: const Icon(Icons.music_note_rounded, size: 40),
                      ),
              ),
            ),

            // Text
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      song.artists,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
