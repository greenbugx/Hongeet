import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/responsive.dart';
import '../../core/utils/audio_player_service.dart';
import '../../core/utils/themed_container.dart';
import '../../core/utils/themed_page.dart';
import '../../core/utils/youtube_thumbnail_utils.dart';
import '../../core/widgets/fallback_network_image.dart';
import '../../data/api/youtube_api.dart';
import '../../data/models/saavn_song.dart';
import '../player/mini_player.dart';
import 'chart_songs_screen.dart';

class ArtistProfileScreen extends StatefulWidget {
  final String artistName;
  final String? artistBrowseId;

  const ArtistProfileScreen({
    super.key,
    required this.artistName,
    this.artistBrowseId,
  });

  @override
  State<ArtistProfileScreen> createState() => _ArtistProfileScreenState();
}

class _ArtistProfileScreenState extends State<ArtistProfileScreen> {
  Future<YtmArtistProfile>? _profileFuture;
  bool _bioExpanded = false;

  final ScrollController _albumsScrollController = ScrollController();
  final ScrollController _singlesScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _albumsScrollController.dispose();
    _singlesScrollController.dispose();
    super.dispose();
  }

  void _loadProfile({bool forceRefresh = false}) {
    _profileFuture = _fetchProfile(forceRefresh: forceRefresh);
  }

  String _primaryArtistName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final normalized = trimmed
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\b(feat|ft)\.?\b.*$', caseSensitive: false), '')
        .trim();
    final split = normalized.split(RegExp(r'\s*(?:,|&| x | and )\s*'));
    return split.first.trim();
  }

  Future<YtmArtistProfile> _fetchProfile({bool forceRefresh = false}) async {
    final seedName = _primaryArtistName(widget.artistName);
    final seedBrowseId = YoutubeApi.extractArtistBrowseId(
      widget.artistBrowseId ?? '',
    );

    return YoutubeApi.artistProfile(
      seedBrowseId,
      artistName: seedName,
      topSongsTake: 24,
      releasesTake: 20,
      forceRefresh: forceRefresh,
    );
  }

  Future<void> _refresh() async {
    setState(() {
      _loadProfile(forceRefresh: true);
    });
    try {
      await _profileFuture;
    } catch (_) {}
  }

  List<SaavnSong> _topSongsPreview(List<SaavnSong> songs) {
    if (songs.isEmpty) return const <SaavnSong>[];
    if (songs.length <= 8) return songs;
    final half = (songs.length / 2).ceil();
    final count = half.clamp(8, 12);
    return songs.take(count).toList(growable: false);
  }

  String _resolvedReleaseSubtitle(String subtitle, String artistName) {
    final raw = subtitle.trim();
    if (raw.isEmpty) return artistName.trim();

    final normalized = raw.toLowerCase().trim();
    final isUnknownOnly =
        normalized == 'unknown' ||
        normalized == 'unknown artist' ||
        normalized == 'artist';
    if (isUnknownOnly) return artistName.trim();
    return raw;
  }

  Widget _buildReleasesSection(
    BuildContext context, {
    required String title,
    required List<YtmAlbum> releases,
    required String headerTitle,
    required String artistName,
    required ScrollController scrollController,
  }) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final scheme = theme.colorScheme;
    final cardWidth = ResponsiveLayout.isExpanded(context) ? 210.0 : 172.0;
    final cardHeight = cardWidth + 62.0;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeaderWithArrows(
            title: title,
            titleStyle: textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            controller: scrollController,
          ),
          const SizedBox(height: 12),
          if (releases.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'No $title available',
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            SizedBox(
              height: cardHeight + 8,
              child: ListView.separated(
                controller: scrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(right: 2, bottom: 8),
                itemCount: releases.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (_, index) {
                  final release = releases[index];
                  final resolvedSubtitle = _resolvedReleaseSubtitle(
                    release.subtitle,
                    artistName,
                  );
                  final imageCandidates = YoutubeThumbnailUtils.candidateUrls(
                    imageUrl: release.imageUrl,
                  );
                  final imageScale =
                      YoutubeThumbnailUtils.preferredArtworkScale(
                        imageUrl: release.imageUrl,
                        youtubeVideoScale: 1.08,
                        normalScale: 1.0,
                      );
                  final chart = YtmChart(
                    playlistId: release.browseId,
                    browseId: release.browseId,
                    title: release.title,
                    subtitle: resolvedSubtitle,
                    imageUrl: release.imageUrl,
                  );

                  return SizedBox(
                    width: cardWidth,
                    height: cardHeight,
                    child: RepaintBoundary(
                      child: ThemedContainer(
                        borderRadius: BorderRadius.circular(18),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ChartSongsScreen(
                                  chart: chart,
                                  headerTitle: headerTitle,
                                  fallbackArtistName: artistName,
                                ),
                              ),
                            );
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AspectRatio(
                                aspectRatio: 1,
                                child: ClipRRect(
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(18),
                                  ),
                                  child: Transform.scale(
                                    scale: imageScale,
                                    child: FallbackNetworkImage(
                                      urls: imageCandidates,
                                      width: double.infinity,
                                      height: double.infinity,
                                      cacheWidth: 768,
                                      cacheHeight: 768,
                                      fit: BoxFit.cover,
                                      alignment: Alignment.center,
                                      filterQuality: FilterQuality.medium,
                                      fallback: Container(
                                        color: scheme.surfaceContainerHighest,
                                        child: const Icon(
                                          Icons.album_rounded,
                                          size: 34,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  8,
                                  10,
                                  8,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      release.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.titleSmall?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      resolvedSubtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodySmall?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final useGlassTheme = themeProvider.useGlassTheme;

    return ThemedPage(
      child: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _refresh,
            child: FutureBuilder<YtmArtistProfile>(
              future: _profileFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 180),
                      Center(child: CircularProgressIndicator()),
                    ],
                  );
                }

                if (snapshot.hasError || !snapshot.hasData) {
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 120),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Unable to load artist profile',
                                style: textTheme.titleMedium,
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton(
                                onPressed: _refresh,
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                }

                final profile = snapshot.data!;
                final previewSongs = _topSongsPreview(profile.topSongs);
                final queuedSongs = profile.topSongs
                    .map(
                      (s) => QueuedSong(
                        id: s.id,
                        meta: NowPlaying(
                          title: s.name,
                          artist: s.artists,
                          imageUrl: s.imageUrl,
                        ),
                      ),
                    )
                    .toList(growable: false);
                final headerImageCandidates =
                    YoutubeThumbnailUtils.candidateUrls(
                      imageUrl: profile.imageUrl,
                    );
                final showBioToggle = profile.bio.trim().length > 220;
                final topSongsCount = profile.topSongs.length;
                final headerHeight = ResponsiveLayout.isExpanded(context)
                    ? 360.0
                    : 310.0;

                return ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 140),
                  children: [
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            useGlassTheme
                                ? CupertinoIcons.back
                                : Icons.arrow_back,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Artist',
                          style: textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: SizedBox(
                          height: headerHeight,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              FallbackNetworkImage(
                                urls: headerImageCandidates,
                                fit: BoxFit.cover,
                                alignment: Alignment.center,
                                cacheWidth: 1200,
                                cacheHeight: 1200,
                                filterQuality: FilterQuality.medium,
                                fallback: Container(
                                  color: scheme.surfaceContainerHighest,
                                  child: const Icon(
                                    Icons.person_rounded,
                                    size: 72,
                                  ),
                                ),
                              ),
                              Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: <Color>[
                                      Color(0x22000000),
                                      Color(0xB0000000),
                                      Color(0xE0000000),
                                    ],
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 16,
                                right: 16,
                                bottom: 16,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      profile.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.headlineMedium?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                      ),
                                    ),
                                    if (profile.monthlyAudience
                                        .trim()
                                        .isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          profile.monthlyAudience,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: textTheme.titleMedium
                                              ?.copyWith(
                                                color: Colors.white.withValues(
                                                  alpha: 0.92,
                                                ),
                                              ),
                                        ),
                                      ),
                                    if (profile.bio.trim().isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      Text(
                                        profile.bio,
                                        maxLines: _bioExpanded ? 10 : 4,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.bodyMedium?.copyWith(
                                          color: Colors.white.withValues(
                                            alpha: 0.93,
                                          ),
                                        ),
                                      ),
                                      if (showBioToggle)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 2,
                                          ),
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            onTap: () => setState(
                                              () =>
                                                  _bioExpanded = !_bioExpanded,
                                            ),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 4,
                                                  ),
                                              child: Text(
                                                _bioExpanded ? 'less' : 'more',
                                                style: textTheme.labelLarge
                                                    ?.copyWith(
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Top Songs',
                        style: textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (previewSongs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'No top songs available',
                          style: textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    else ...[
                      ...previewSongs.asMap().entries.map((entry) {
                        final index = entry.key;
                        final song = entry.value;
                        final imageScale =
                            YoutubeThumbnailUtils.preferredArtworkScale(
                              songId: song.id,
                              imageUrl: song.imageUrl,
                              youtubeVideoScale: 1.0,
                              normalScale: 1.0,
                            );
                        final imageCandidates =
                            YoutubeThumbnailUtils.candidateUrls(
                              songId: song.id,
                              imageUrl: song.imageUrl,
                            );

                        return Padding(
                          padding: const EdgeInsets.only(
                            left: 16,
                            right: 16,
                            bottom: 10,
                          ),
                          child: ThemedContainer(
                            child: ListTile(
                              leading: SizedBox(
                                width: 50,
                                height: 50,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Transform.scale(
                                    scale: imageScale,
                                    child: FallbackNetworkImage(
                                      urls: imageCandidates,
                                      width: 50,
                                      height: 50,
                                      cacheWidth: 320,
                                      cacheHeight: 320,
                                      fit: BoxFit.cover,
                                      alignment: Alignment.center,
                                      filterQuality: FilterQuality.medium,
                                      fallback: Container(
                                        color: scheme.surfaceContainerHighest,
                                        child: const Icon(
                                          Icons.music_note_rounded,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              title: Text(
                                song.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                song.artists,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Text(
                                '${index + 1}',
                                style: textTheme.labelLarge?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              onTap: () async {
                                if (index < 0 || index >= queuedSongs.length) {
                                  return;
                                }
                                await AudioPlayerService().playFromList(
                                  songs: queuedSongs,
                                  startIndex: index,
                                );
                              },
                            ),
                          ),
                        );
                      }),
                      if (topSongsCount > previewSongs.length)
                        Padding(
                          padding: const EdgeInsets.only(
                            left: 16,
                            right: 16,
                            bottom: 6,
                          ),
                          child: Text(
                            'Showing ${previewSongs.length} of $topSongsCount',
                            style: textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _buildReleasesSection(
                        context,
                        title: 'Albums',
                        releases: profile.albums,
                        headerTitle: 'Albums',
                        artistName: profile.name,
                        scrollController: _albumsScrollController,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _buildReleasesSection(
                        context,
                        title: 'Singles & EPs',
                        releases: profile.singlesAndEps,
                        headerTitle: 'Singles & EPs',
                        artistName: profile.name,
                        scrollController: _singlesScrollController,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: ResponsiveLayout.isExpanded(context)
                      ? 760
                      : double.infinity,
                ),
                child: const MiniPlayer(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeaderWithArrows extends StatelessWidget {
  final String title;
  final TextStyle? titleStyle;
  final ScrollController controller;
  final double scrollAmount;

  const _SectionHeaderWithArrows({
    required this.title,
    required this.controller,
    this.titleStyle,
    this.scrollAmount = 620,
  });

  @override
  Widget build(BuildContext context) {
    final isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

    return Row(
      children: [
        Expanded(child: Text(title, style: titleStyle)),
        if (isWindows && ResponsiveLayout.isExpanded(context)) ...[
          const SizedBox(width: 8),
          _ScrollArrowButton(
            icon: Icons.chevron_left_rounded,
            onPressed: () {
              if (!controller.hasClients) return;
              final target = (controller.offset - scrollAmount).clamp(
                0.0,
                controller.position.maxScrollExtent,
              );
              controller.animateTo(
                target,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
              );
            },
          ),
          const SizedBox(width: 4),
          _ScrollArrowButton(
            icon: Icons.chevron_right_rounded,
            onPressed: () {
              if (!controller.hasClients) return;
              final target = (controller.offset + scrollAmount).clamp(
                0.0,
                controller.position.maxScrollExtent,
              );
              controller.animateTo(
                target,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
              );
            },
          ),
        ],
      ],
    );
  }
}

class _ScrollArrowButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _ScrollArrowButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.92),
      elevation: 2,
      shadowColor: scheme.shadow.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Icon(icon, size: 18, color: scheme.onSurface),
        ),
      ),
    );
  }
}
