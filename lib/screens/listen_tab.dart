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
import '../widgets/cached_cover_image.dart';
import '../widgets/empty_state.dart';
import '../widgets/pill_button.dart';
import '../widgets/section_header.dart';
import '../widgets/song_tile.dart';
import 'playlist_page.dart';

/// 聆听 — everything you already have: favorites, playlists, what you
/// played recently, and every downloaded song.
class ListenTab extends StatefulWidget {
  const ListenTab({super.key});

  @override
  State<ListenTab> createState() => _ListenTabState();
}

class _ListenTabState extends State<ListenTab>
    with AutomaticKeepAliveClientMixin {
  LibraryController get _library => AppServices.instance.library;

  /// Android only: shown until background protection is on or dismissed.
  bool _showProtectionHint = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_checkProtection());
  }

  Future<void> _checkProtection() async {
    if (!BackgroundProtection.supported) return;
    final dismissed = await DatabaseService.getPref('protectionHintDismissed');
    if (dismissed == true) return;
    final enabled = await BackgroundProtection.isEnabled();
    if (mounted && !enabled) setState(() => _showProtectionHint = true);
  }

  Future<void> _dismissProtectionHint() async {
    setState(() => _showProtectionHint = false);
    await DatabaseService.setPref('protectionHintDismissed', true);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
                  onDismiss: _dismissProtectionHint,
                ),
              ),
            SliverToBoxAdapter(child: _quickRow(songs)),
            if (_library.recent.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SectionHeader(title: '最近播放')),
              SliverToBoxAdapter(child: _recentRail(_library.recent)),
            ],
            SliverToBoxAdapter(
              child: SectionHeader(
                title: '歌单',
                trailing: IconButton(
                  tooltip: '新建歌单',
                  onPressed: () => createAndOpenPlaylist(context),
                  icon: const Icon(Icons.add_rounded,
                      color: AppColors.textSecondary),
                ),
              ),
            ),
            if (_library.userPlaylists.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('还没有歌单，点右侧 ＋ 新建',
                      style: AppTypography.caption),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: _library.userPlaylists.length,
                  itemBuilder: (context, index) =>
                      _PlaylistRow(playlist: _library.userPlaylists[index]),
                ),
              ),
            SliverToBoxAdapter(
              child: SectionHeader(
                title: '全部歌曲',
                count: songs.length,
                trailing: _SortButton(library: _library),
              ),
            ),
            if (songs.isEmpty)
              SliverToBoxAdapter(
                child: _library.loaded
                    ? const EmptyState(
                        icon: Icons.library_music_rounded,
                        title: '还没有下载的歌曲',
                        subtitle: '在上方搜索，下载想听的歌',
                      )
                    : const SizedBox(height: 120),
              )
            else ...[
              SliverToBoxAdapter(child: _playButtons(songs)),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverFixedExtentList(
                  itemExtent: SongTile.extent,
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final track = songs[index];
                      return SongTile(
                        track: track,
                        queue: songs,
                        onTap: () => openTrack(context, track, queue: songs),
                      );
                    },
                    childCount: songs.length,
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }

  Widget _quickRow(List<Track> songs) {
    final favorites = _library.favorites;
    final favTracks = favorites?.tracks ?? const <Track>[];
    final favPlayable = _library.playableOf(favTracks);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: _QuickCard(
              icon: Icons.favorite_rounded,
              iconColor: AppColors.accent,
              title: '收藏',
              subtitle: favPlayable.length == favTracks.length
                  ? '${favTracks.length} 首'
                  : '${favTracks.length} 首 · ${favPlayable.length} 首可播放',
              onTap: favorites == null
                  ? null
                  : () => PlaylistPage.open(context, favorites.id),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _QuickCard(
              icon: Icons.shuffle_rounded,
              iconColor: AppColors.textPrimary,
              title: '随机播放',
              subtitle: '全部 ${songs.length} 首',
              onTap: songs.isEmpty
                  ? null
                  : () => playCollection(songs, shuffle: true),
            ),
          ),
        ],
      ),
    );
  }

  Widget _recentRail(List<Track> recent) {
    return SizedBox(
      height: 172,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        scrollDirection: Axis.horizontal,
        itemCount: recent.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final track = recent[index];
          return SizedBox(
            width: 120,
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
                      width: 120,
                      height: 120,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyMedium.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    track.uploader,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _playButtons(List<Track> songs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: PillButton(
              icon: Icons.play_arrow_rounded,
              label: '播放',
              onPressed: () => playCollection(songs),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: PillButton(
              icon: Icons.shuffle_rounded,
              label: '随机播放',
              onPressed: () => playCollection(songs, shuffle: true),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _QuickCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.fieldFill,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap == null
            ? null
            : () {
                Haptics.light();
                onTap!();
              },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: iconColor, size: 24),
              const SizedBox(height: 14),
              Text(title, style: AppTypography.headline),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  final Playlist playlist;

  const _PlaylistRow({required this.playlist});

  @override
  Widget build(BuildContext context) {
    final cover = playlist.coverUrl;
    final fallbackCover =
        playlist.tracks.isNotEmpty ? playlist.tracks.first.coverUrl : '';
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => PlaylistPage.open(context, playlist.id),
      child: SizedBox(
        height: SongTile.extent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm - 2),
                child: (cover != null && cover.isNotEmpty) ||
                        fallbackCover.isNotEmpty
                    ? CachedCoverImage(
                        url: (cover != null && cover.isNotEmpty)
                            ? cover
                            : fallbackCover,
                        width: SongTile.artSize,
                        height: SongTile.artSize,
                      )
                    : const SizedBox(
                        width: SongTile.artSize,
                        height: SongTile.artSize,
                        child: ColoredBox(
                          color: AppColors.fieldFill,
                          child: Icon(Icons.queue_music_rounded,
                              color: AppColors.textMuted),
                        ),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.body
                          .copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text('${playlist.tracks.length} 首',
                        style: AppTypography.caption.copyWith(fontSize: 13)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: AppColors.textFaint),
              const SizedBox(width: 8),
            ],
          ),
        ),
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
      itemBuilder: (context) => [
        for (final entry in _labels.entries)
          PopupMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_labels[library.sort]!, style: AppTypography.caption),
            const Icon(Icons.unfold_more_rounded,
                size: 16, color: AppColors.textMuted),
          ],
        ),
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
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
        decoration: BoxDecoration(
          color: AppColors.fieldFill,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.shield_moon_outlined,
                    color: AppColors.accent, size: 20),
                SizedBox(width: 8),
                Text('后台播放保护', style: AppTypography.headline),
              ],
            ),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Text(
                '部分手机会在后台关闭音乐应用。允许 BiliBeats 不受电池优化限制，可避免播放中途被系统关闭。',
                style: AppTypography.bodyMedium,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onDismiss, child: const Text('不再提示')),
                TextButton(
                  onPressed: onEnable,
                  child: const Text('允许',
                      style: TextStyle(color: AppColors.accent)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
