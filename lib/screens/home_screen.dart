import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/track.dart';
import '../models/playlist.dart';
import '../services/database_service.dart';
import '../services/download_manager.dart';
import '../widgets/glass_card.dart';
import '../widgets/playlist_detail_sheet.dart';
import '../widgets/track_options_menu.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../widgets/cached_cover_image.dart';
import '../widgets/download_management_sheet.dart';
import '../widgets/empty_state.dart';
import '../widgets/marquee_text.dart';
import '../widgets/track_download_button.dart';
import '../widgets/track_row.dart';

import 'dart:async';

class HomeScreen extends StatefulWidget {
  final List<Track> recentlyPlayed;
  final TrackAction onSelectTrack;
  final TrackAction? onPlayOnly;
  final Function(Playlist)? onOpenPlaylist;

  /// Plays a whole collection. Loop-all; shuffle only when asked.
  final void Function(List<Track> tracks, {bool shuffle})? onPlayCollection;

  const HomeScreen({
    super.key,
    required this.recentlyPlayed,
    required this.onSelectTrack,
    this.onPlayOnly,
    this.onOpenPlaylist,
    this.onPlayCollection,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Playlist> _playlists = [];
  List<Track> _downloadedTracks = [];
  StreamSubscription<void>? _downloadSub;
  StreamSubscription<void>? _downloadManagerSub;
  List<DownloadTask> _downloadingTasks = [];
  Set<String> _downloadingIds = {};
  bool _hasFailedDownloads = false;

  @override
  void initState() {
    super.initState();
    _loadData();
    _refreshDownloading();
    _downloadSub = DatabaseService.libraryUpdateStream.listen((_) {
      _loadData();
    });
    _downloadManagerSub = DownloadManager.instance.updates.listen((_) {
      final ids =
          DownloadManager.instance.activeTasks.map((t) => t.track.id).toSet();
      final hasFailed = DownloadManager.instance.failedTasks.isNotEmpty;
      if (!setEquals(ids, _downloadingIds) ||
          hasFailed != _hasFailedDownloads) {
        _downloadingIds = ids;
        _refreshDownloading();
      }
    });
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    _downloadManagerSub?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    final playlists = await DatabaseService.getPlaylists();
    final downloaded = await DatabaseService.getDownloadedTracks();
    if (mounted) {
      setState(() {
        _playlists = playlists;
        _downloadedTracks = downloaded;
      });
    }
  }

  void _refreshDownloading() {
    if (!mounted) return;
    setState(() {
      _downloadingTasks = DownloadManager.instance.activeTasks;
      _hasFailedDownloads = DownloadManager.instance.failedTasks.isNotEmpty;
    });
  }

  void _openDownloadManagement() {
    DownloadManagementSheet.show(context);
  }

  void _openCreatePlaylistDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.backgroundElevated,
        title:
            const Text('新建歌单', style: TextStyle(color: AppColors.textPrimary)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(
            hintText: '歌单名称',
            hintStyle: TextStyle(color: AppColors.textFaint),
          ),
        ),
        actions: [
          TextButton(
            child: const Text('取消'),
            onPressed: () => Navigator.pop(ctx),
          ),
          TextButton(
            child: const Text('创建', style: TextStyle(color: AppColors.accent)),
            onPressed: () => Navigator.pop(ctx, controller.text),
          ),
        ],
      ),
    );

    controller.dispose();

    if (name != null && name.trim().isNotEmpty) {
      await DatabaseService.createPlaylist(name);
      _loadData();
    }
  }

  /// Long-pressing a playlist card offers to delete it — previously a playlist
  /// could be created but never removed.
  Future<void> _confirmDeletePlaylist(Playlist pl) async {
    if (pl.id == Playlist.favoritesId) return;
    Haptics.medium();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.backgroundElevated,
        title:
            const Text('删除歌单', style: TextStyle(color: AppColors.textPrimary)),
        content: Text(
          '「${pl.name}」将被删除，本地音频保留。',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await DatabaseService.deletePlaylist(pl.id);
      await _loadData();
    }
  }

  void _openPlaylist(Playlist pl) {
    if (widget.onOpenPlaylist != null) {
      widget.onOpenPlaylist!(pl);
    } else {
      PlaylistDetailSheet.show(
        context,
        playlist: pl,
        onSelectTrack: widget.onSelectTrack,
        onPlayOnly: widget.onPlayOnly,
        onPlaylistUpdated: _loadData,
      );
    }
  }

  /// Completed downloads only. Active (unfinished) downloads are shown in
  /// their own section and must never enter an offline playback queue.
  void _openDownloadedPlaylist() {
    _openPlaylist(Playlist(
      id: 'downloaded',
      name: '本地',
      tracks: List<Track>.of(_downloadedTracks),
    ));
  }

  Widget _quickCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required List<Track> Function() tracks,
    String? cover,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: cover != null && cover.isNotEmpty
                      ? CachedCoverImage(url: cover, width: 40, height: 40)
                      : Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.white06,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Icon(
                            icon,
                            color: icon == Icons.favorite_rounded
                                ? AppColors.accent
                                : AppColors.textSecondary,
                            size: 22,
                          ),
                        ),
                ),
                const Spacer(),
                // Opposite corner from the icon: tapping the card opens the
                // collection, tapping here just starts it.
                _playCollectionButton(tracks),
              ],
            ),
            const SizedBox(height: 12),
            Text(title, style: AppTypography.headline),
            const SizedBox(height: 2),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption),
          ],
        ),
      ),
    );
  }

  /// Start-this-collection control. Loop-all, in order — the shuffled variant
  /// lives inside the collection, where 随机播放 is the header button.
  Widget _playCollectionButton(List<Track> Function() tracks) {
    final enabled = widget.onPlayCollection != null && tracks().isNotEmpty;

    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        tooltip: '播放全部',
        onPressed: !enabled
            ? null
            : () {
                final queue = List<Track>.of(tracks());
                if (queue.isEmpty) return;

                Haptics.light();
                widget.onPlayCollection?.call(queue);
              },
        icon: Icon(
          Icons.play_arrow_rounded,
          size: 28,
          color: enabled ? AppColors.textPrimary : AppColors.textFaint,
        ),
      ),
    );
  }

  /// Completed-download subset of [tracks]. Collection playback and
  /// automatic advance never silently download missing items.
  List<Track> _playableOf(List<Track> tracks) {
    if (tracks.isEmpty) return const [];
    final ids = _downloadedTracks.map((t) => t.id).toSet();
    return tracks.where((t) => ids.contains(t.id)).toList();
  }

  /// A playlist reads as a row, exactly like a song in the search results.
  ///
  /// It used to be a [GlassCard]; a page of them was a stack of boxes again,
  /// and there is no reason a playlist should look heavier than the songs
  /// inside it.
  Widget _playlistBar(Playlist pl) {
    return Padding(
      padding: const EdgeInsets.only(bottom: TrackRow.gap),
      child: TrackRow(
        onTap: () => _openPlaylist(pl),
        onLongPress: () => _confirmDeletePlaylist(pl),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: pl.coverUrl != null && pl.coverUrl!.isNotEmpty
                  ? CachedCoverImage(url: pl.coverUrl!, width: 54, height: 54)
                  : const SizedBox(
                      width: 54,
                      height: 54,
                      child: ColoredBox(
                        color: AppColors.white06,
                        child: Center(
                          child: Icon(Icons.queue_music_rounded,
                              color: AppColors.textSecondary, size: 26),
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pl.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('${pl.tracks.length} 首', style: AppTypography.caption),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _playCollectionButton(() => _playableOf(pl.tracks)),
            ),
          ],
        ),
      ),
    );
  }

  /// One row of the 下载中 section, built lazily like the playlists below it.
  Widget _downloadingTaskTile(int index) {
    final task = _downloadingTasks[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: TrackRow.gap),
      child: TrackRow(
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: CachedCoverImage(
                url: task.track.coverUrl,
                width: 48,
                height: 48,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RepaintBoundary(
                    child: MarqueeText(
                      text: task.track.title,
                      phase: (index % 5) / 5,
                      style: AppTypography.body.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    task.track.uploader,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption.copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
            TrackDownloadButton(track: task.track, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _newPlaylistBar() {
    return TrackRow(
      onTap: _openCreatePlaylistDialog,
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: AppColors.hairlineStrong),
            ),
            child: const Icon(Icons.add_rounded,
                color: AppColors.accent, size: 24),
          ),
          const SizedBox(width: 12),
          const Text('新建歌单',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Playlist? get _favorites {
    for (final pl in _playlists) {
      if (pl.id == Playlist.favoritesId) return pl;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Playlists other than 收藏, which has its own quick-access card.
    final otherPlaylists =
        _playlists.where((p) => p.id != Playlist.favoritesId).toList();

    // Collection queues are completed downloads only: automatic advance
    // must not silently download missing items.
    final downloadedIds = _downloadedTracks.map((t) => t.id).toSet();
    final favTracks = _favorites?.tracks ?? const [];
    final favPlayable =
        favTracks.where((t) => downloadedIds.contains(t.id)).toList();

    // Slivers instead of one eager ListView(children:): long playlists and
    // an active download list only pay for the rows actually on screen. The
    // static headers stay in a fixed child-list delegate (cheap, count known).
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(left: 20, right: 20, top: 20),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              // No "聆听" heading: the tab bar above already names the page, and
              // repeating it one line below was the same word twice.
              // Quick Access Cards: Downloaded Tracks & Favorites
              Row(
                children: [
                  Expanded(
                    child: _quickCard(
                      icon: Icons.download_done_rounded,
                      title: '本地',
                      subtitle: _downloadingTasks.isEmpty
                          ? '${_downloadedTracks.length} 首可播放'
                          : '${_downloadedTracks.length} 首可播放 · '
                              '${_downloadingTasks.length} 首下载中',
                      onTap: _openDownloadedPlaylist,
                      tracks: () => List<Track>.of(_downloadedTracks),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _quickCard(
                      icon: Icons.favorite_rounded,
                      title: '收藏',
                      subtitle: favPlayable.length == favTracks.length
                          ? '${favTracks.length} 首'
                          : '${favTracks.length} 首 · '
                              '${favPlayable.length} 首可播放',
                      onTap: () {
                        final fav = _favorites;
                        if (fav != null) _openPlaylist(fav);
                      },
                      tracks: () => List<Track>.of(favPlayable),
                      cover: _favorites?.coverUrl,
                    ),
                  ),
                ],
              ),

              if (_downloadingTasks.isNotEmpty || _hasFailedDownloads) ...[
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _downloadingTasks.isNotEmpty ? '下载中' : '下载',
                        style: AppTypography.title,
                      ),
                    ),
                    TextButton(
                      onPressed: _openDownloadManagement,
                      child: const Text('管理',
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 13)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ]),
          ),
        ),

        if (_downloadingTasks.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList.builder(
              itemCount: _downloadingTasks.length,
              itemBuilder: (context, index) => _downloadingTaskTile(index),
            ),
          ),

        // The playlist header belongs to the playlist rows: it must come
        // after the download rows, not before them.
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
              20,
              (_downloadingTasks.isEmpty && !_hasFailedDownloads) ? 24 : 28,
              20,
              12),
          sliver: const SliverToBoxAdapter(
            child: Text('我的歌单', style: AppTypography.title),
          ),
        ),

        // Playlists: a plain vertical stack of bars, laid out by the page's
        // own scroll view. A horizontal rail hid every playlist past the
        // second one behind a sideways scroll nobody thinks to try, on a page
        // that already scrolls downwards.
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList.builder(
            itemCount: otherPlaylists.length,
            itemBuilder: (context, index) =>
                _playlistBar(otherPlaylists[index]),
          ),
        ),

        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverToBoxAdapter(child: _newPlaylistBar()),
        ),

        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 28),

                // Recently Played Section
                const Text('最近播放', style: AppTypography.title),

                const SizedBox(height: 14),

                if (widget.recentlyPlayed.isEmpty)
                  const EmptyState(
                    icon: Icons.history_rounded,
                    title: '暂无播放记录',
                    subtitle: '去搜索页找歌',
                  )
                else
                  SizedBox(
                    height: 200,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: widget.recentlyPlayed.length,
                      itemBuilder: (context, index) {
                        final track = widget.recentlyPlayed[index];
                        return GestureDetector(
                          onTap: () => widget.onSelectTrack(track),
                          onLongPress: () {
                            TrackOptionsMenu.show(context, track,
                                onTrackChanged: _loadData);
                          },
                          child: Container(
                            width: 130,
                            margin: const EdgeInsets.only(right: 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: CachedCoverImage(
                                    url: track.coverUrl,
                                    width: 130,
                                    height: 130,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                MarqueeText(
                                  text: track.title,
                                  phase: (index % 5) / 5,
                                  style: AppTypography.body.copyWith(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                Text(
                                  track.uploader,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.caption
                                      .copyWith(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
