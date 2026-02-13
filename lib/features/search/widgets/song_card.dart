import 'package:flutter/material.dart';
import '../../../core/widgets/fallback_network_image.dart';
import '../../../core/utils/youtube_thumbnail_utils.dart';
import '../../../core/utils/glass_container.dart';
import '../../../data/models/saavn_song.dart';

class SongCard extends StatelessWidget {
  final SaavnSong song;
  final VoidCallback? onTap;

  const SongCard({super.key, required this.song, this.onTap});

  @override
  Widget build(BuildContext context) {
    final imageUrl = song.imageUrl.trim();
    final imageScale = YoutubeThumbnailUtils.preferredArtworkScale(
      songId: song.id,
      imageUrl: imageUrl,
      youtubeVideoScale: 2.0,
      normalScale: 1.0,
    );
    final imageCandidates = YoutubeThumbnailUtils.candidateUrls(
      songId: song.id,
      imageUrl: imageUrl,
    );

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
                child: imageCandidates.isNotEmpty
                    ? Transform.scale(
                        scale: imageScale,
                        child: FallbackNetworkImage(
                          urls: imageCandidates,
                          width: double.infinity,
                          height: double.infinity,
                          cacheWidth: 640,
                          cacheHeight: 640,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          filterQuality: FilterQuality.medium,
                          fallback: Container(
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
