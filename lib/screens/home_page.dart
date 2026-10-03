import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../app/playback_actions.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../services/background_protection.dart';
import '../services/database_service.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../theme/motion.dart';
import '../widgets/cached_cover_image.dart';
import '../widgets/empty_state.dart';
import '../widgets/sheet.dart';
import '../widgets/song_tile.dart';
import 'artist_page.dart';
import 'playlist_page.dart';

/// Home: your music.
///
/// What you played lately across the top, then the library through one of
/// three lenses — 歌曲, 歌单, 歌手 — switched in place by a full-width
/// switch that stays pinned under the search bar. Each lens carries its own
/// actions inside its content (play / shuffle / sort above the songs, a
/// 新建 tile among the playlists), so the switch looks the same in all
/// three. Finding and downloading new music lives in the search bar above.
class HomePage extends StatefulWidget {
  /// Puts the cursor in the search bar (the empty library's way forward).
  final VoidCallback onSearch;

  const HomePage({super.key, required this.onSearch});

  @override
  State<HomePage> createState() => _HomePageState();
}

enum _Lens { songs, playlists, artists }

class _HomePageState extends State<HomePage> {
  LibraryController get _library => AppServices.instance.library;

  _Lens _lens = _Lens.songs;

  /// Android only: shown until background protection is on or dismissed.
  bool _showProtectionHint = false;

  @override
  void initState() {
    super.initState();
    unawaited(_checkProtection());
  }

  Future<void> _checkProtection() async {
    if (!BackgroundProtection.supported) return;
    if (await DatabaseService.getPref('protectionHintDismissed') == true) {
      return;
    }
    final enabled = await BackgroundProtection.isEnabled();
    if (mounted && !enabled) setState(() => _showProtectionHint = true);
  }

  void _select(_Lens lens) {
    if (lens == _lens) return;
    Haptics.selection();
    setState(() => _lens = lens);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _library,
      builder: (context, _) {
        final songs = _library.sortedDownloaded;
        return CustomScrollView(
          slivers: [
            if (_showProtectionHint)
              SliverToBoxAdapter(
                child: _ProtectionHint(
                  onEnable: () async {
                    await BackgroundProtection.request();
                    if (mounted) setState(() => _showProtectionHint = false);
                  },
                  onDismiss: () {
                    setState(() => _showProtectionHint = false);
                    DatabaseService.setPref('protectionHintDismissed', true);
                  },
                ),
              ),
            if (_library.recent.isNotEmpty)
              SliverToBoxAdapter(child: _RecentRail(tracks: _library.recent)),
            SliverPersistentHeader(
              pinned: true,
              delegate: _LensBar(lens: _lens, onSelect: _select),
            ),
            ..._lensBody(songs),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }

  List<Widget> _lensBody(List<Track> songs) {
    switch (_lens) {
      case _Lens.songs:
        if (songs.isEmpty) {
          return [
            SliverToBoxAdapter(
              child: !_library.loaded
                  ? const SizedBox(height: 120)
                  : EmptyState(
                      icon: Icons.library_music_outlined,
                      title: '还没有歌曲',
                      action: TextButton(
                        onPressed: widget.onSearch,
                        child: const Text('搜索并下载',
                            style: TextStyle(color: AppColors.accent)),
                      ),
                    ),
            ),
          ];
        }
        return [
          SliverToBoxAdapter(
            child: _SongActions(library: _library, songs: songs),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            sliver: SliverFixedExtentList.builder(
              itemExtent: SongTile.extent,
              itemCount: songs.length,
              itemBuilder: (context, index) {
                final track = songs[index];
                return SongTile(
                  track: track,
                  queue: songs,
                  onTap: () => openTrack(context, track, queue: songs),
                );
              },
            ),
          ),
        ];

      case _Lens.playlists:
        final playlists = _library.playlists;
        return [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 18,
                crossAxisSpacing: 16,
                childAspectRatio: 0.76,
              ),
              itemCount: playlists.length + 1,
              itemBuilder: (context, index) => index < playlists.length
                  ? _PlaylistCard(playlist: playlists[index])
                  : const _NewPlaylistCard(),
            ),
          ),
        ];

      case _Lens.artists:
        final artists = _library.artists;
        if (artists.isEmpty) {
          return const [
            SliverToBoxAdapter(
              child: EmptyState(
                icon: Icons.person_outline_rounded,
                title: '下载歌曲后，会按歌手自动归类',
              ),
            ),
          ];
        }
        return [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 130,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 0.68,
              ),
              itemCount: artists.length,
              itemBuilder: (context, index) =>
                  _ArtistCard(artist: artists[index]),
            ),
          ),
        ];
    }
  }
}

/// 歌曲 · 歌单 · 歌手 — one switch across the full width, pinned under the
/// search bar once scrolled to.
class _LensBar extends SliverPersistentHeaderDelegate {
  final _Lens lens;
  final ValueChanged<_Lens> onSelect;

  _LensBar({required this.lens, required this.onSelect});

  static const _labels = {
    _Lens.songs: '歌曲',
    _Lens.playlists: '歌单',
    _Lens.artists: '歌手',
  };

  static const double _height = 44;

  @override
  double get minExtent => _height + 16;

  @override
  double get maxExtent => _height + 16;

  @override
  bool shouldRebuild(covariant _LensBar old) => old.lens != lens;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return ColoredBox(
      color: AppColors.background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.fieldFill,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Stack(
            children: [
              // The selected segment's pill slides between positions.
              AnimatedAlign(
                duration: AppMotion.base,
                curve: AppMotion.standard,
                alignment: Alignment(lens.index - 1.0, 0),
                child: FractionallySizedBox(
                  widthFactor: 1 / _Lens.values.length,
                  heightFactor: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppColors.white12,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final entry in _labels.entries)
                    Expanded(
                      child: _LensLabel(
                        label: entry.value,
                        selected: entry.key == lens,
                        onTap: () => onSelect(entry.key),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LensLabel extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _LensLabel({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            style: AppTypography.headline.copyWith(
              fontSize: 16,
              color: selected ? AppColors.textPrimary : AppColors.textMuted,
            ),
            child: Text(label, maxLines: 1),
          ),
        ),
      ),
    );
  }
}

/// 播放 · 随机 · sort, above the song list.
class _SongActions extends StatelessWidget {
  final LibraryController library;
  final List<Track> songs;

  const _SongActions({required this.library, required this.songs});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: PrimaryButton(
              icon: Icons.play_arrow_rounded,
              label: '播放',
              onPressed: () => playCollection(songs),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: PrimaryButton(
              icon: Icons.shuffle_rounded,
              label: '随机',
              secondary: true,
              onPressed: () => playCollection(songs, shuffle: true),
            ),
          ),
          const SizedBox(width: 2),
          _SortButton(library: library),
        ],
      ),
    );
  }
}

class _SortButton extends StatelessWidget {
  final LibraryController library;

  const _SortButton({required this.library});

  static const _labels = {
    LibrarySort.recent: '最近下载',
    LibrarySort.title: '歌名',
    LibrarySort.artist: '歌手',
  };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<LibrarySort>(
      tooltip: '排序',
      initialValue: library.sort,
      onSelected: library.setSort,
      icon: const Icon(Icons.swap_vert_rounded,
          color: AppColors.textSecondary, size: 24),
      itemBuilder: (context) => [
        for (final entry in _labels.entries)
          PopupMenuItem(value: entry.key, child: Text(entry.value)),
      ],
    );
  }
}

/// Covers of what was played lately; tap one to play it again.
class _RecentRail extends StatelessWidget {
  final List<Track> tracks;

  const _RecentRail({required this.tracks});

  static const double _size = 112;

  @override
  Widget build(BuildContext context) {
    final count = tracks.length > 12 ? 12 : tracks.length;
    return SizedBox(
      height: _size + 44,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
        scrollDirection: Axis.horizontal,
        itemCount: count,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final track = tracks[index];
          return SizedBox(
            width: _size,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: () => openTrack(context, track),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    child: CachedCoverImage(
                      url: track.coverUrl,
                      width: _size,
                      height: _size,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption.copyWith(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  final Playlist playlist;

  const _PlaylistCard({required this.playlist});

  @override
  Widget build(BuildContext context) {
    final favorites = playlist.id == Playlist.favoritesId;
    final own = playlist.coverUrl ?? '';
    final cover = own.isNotEmpty
        ? own
        : (playlist.tracks.isNotEmpty ? playlist.tracks.first.coverUrl : '');

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => PlaylistPage.open(context, playlist.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: LayoutBuilder(
                builder: (context, box) => Stack(
                  fit: StackFit.expand,
                  children: [
                    if (cover.isNotEmpty)
                      CachedCoverImage(
                        url: cover,
                        width: box.maxWidth,
                        height: box.maxWidth,
                      )
                    else
                      ColoredBox(
                        color: AppColors.fieldFill,
                        child: Icon(
                          favorites
                              ? Icons.favorite_rounded
                              : Icons.queue_music_rounded,
                          size: 40,
                          color:
                              favorites ? AppColors.accent : AppColors.white24,
                        ),
                      ),
                    if (favorites && cover.isNotEmpty)
                      const Positioned(
                        left: 10,
                        bottom: 10,
                        child: Icon(Icons.favorite_rounded,
                            color: AppColors.accent,
                            size: 22,
                            shadows: [
                              Shadow(color: AppColors.black55, blurRadius: 8),
                            ]),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.body.copyWith(fontWeight: FontWeight.w500),
          ),
          Text('${playlist.tracks.length} 首', style: AppTypography.caption),
        ],
      ),
    );
  }
}

/// The last tile among the playlists: make another.
class _NewPlaylistCard extends StatelessWidget {
  const _NewPlaylistCard();

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => createAndOpenPlaylist(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.hairlineStrong),
              ),
              child: const Center(
                child: Icon(Icons.add_rounded,
                    size: 36, color: AppColors.textMuted),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '新建歌单',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.body.copyWith(
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtistCard extends StatelessWidget {
  final ArtistGroup artist;

  const _ArtistCard({required this.artist});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => ArtistPage.open(context, artist.name),
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipOval(
              child: LayoutBuilder(
                builder: (context, box) => CachedCoverImage(
                  url: artist.coverUrl,
                  width: box.maxWidth,
                  height: box.maxWidth,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            artist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style:
                AppTypography.bodyMedium.copyWith(color: AppColors.textPrimary),
          ),
          Text('${artist.tracks.length} 首', style: AppTypography.caption),
        ],
      ),
    );
  }
}

class _ProtectionHint extends StatelessWidget {
  final VoidCallback onEnable;
  final VoidCallback onDismiss;

  const _ProtectionHint({required this.onEnable, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      child: Material(
        color: AppColors.fieldFill,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Row(
            children: [
              const Icon(Icons.shield_moon_outlined,
                  color: AppColors.textSecondary, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '防止后台播放被系统关闭',
                  maxLines: 2,
                  style: AppTypography.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: onEnable,
                child:
                    const Text('开启', style: TextStyle(color: AppColors.accent)),
              ),
              IconButton(
                tooltip: '不再提示',
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded,
                    color: AppColors.textFaint, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
