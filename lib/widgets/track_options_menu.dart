import 'dart:async';

import 'package:flutter/material.dart';
import '../app/app_services.dart';
import '../services/audio_player_handler.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/format.dart';
import '../models/track.dart';
import '../models/playlist.dart';
import '../services/database_service.dart';
import '../services/audio_download_service.dart';
import '../services/download_manager.dart';
import '../utils/snack.dart';
import 'cached_cover_image.dart';

/// A song's sheet: its details plus everything you can do with it.
///
/// Doubles as the preview for songs that are not downloaded yet — the
/// primary action is then 下载并播放, which downloads first and starts the
/// song only once it is on disk (the current song keeps playing meanwhile).
class TrackOptionsMenu extends StatefulWidget {
  final Track track;
  final VoidCallback? onTrackChanged;

  /// The queue 播放 should play within (default: the whole library).
  final List<Track>? queue;

  const TrackOptionsMenu({
    super.key,
    required this.track,
    this.onTrackChanged,
    this.queue,
  });

  static Future<void> show(BuildContext context, Track track,
      {VoidCallback? onTrackChanged, List<Track>? queue}) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => TrackOptionsMenu(
        track: track,
        onTrackChanged: onTrackChanged,
        queue: queue,
      ),
    );
  }

  static Future<void> showAddToPlaylist(BuildContext context, Track track,
      {VoidCallback? onTrackChanged}) {
    return showAddToPlaylistForTracks(context, [track],
        onTrackChanged: onTrackChanged);
  }

  static Future<void> showAddToPlaylistForTracks(
      BuildContext context, List<Track> tracks,
      {VoidCallback? onTrackChanged}) async {
    if (tracks.isEmpty) return;
    final List<Playlist> playlists = await DatabaseService.getPlaylists();

    if (!context.mounted) return;
    final parentMessenger = ScaffoldMessenger.of(context);

    // Awaited: the returned future completes when the sheet dismisses, so
    // callers can order UI transitions after it.
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.backgroundElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return Container(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        tracks.length == 1
                            ? '加入歌单'
                            : '批量加入歌单 (${tracks.length} 首)',
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.bold),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.add,
                            color: AppColors.accent, size: 20),
                        label: const Text('新建歌单',
                            style: TextStyle(color: AppColors.accent)),
                        onPressed: () async {
                          final controller = TextEditingController();
                          final newPlName = await showDialog<String>(
                            context: ctx,
                            builder: (dCtx) => AlertDialog(
                              backgroundColor: AppColors.backgroundElevated,
                              title: const Text('新建歌单',
                                  style:
                                      TextStyle(color: AppColors.textPrimary)),
                              content: TextField(
                                controller: controller,
                                style: const TextStyle(
                                    color: AppColors.textPrimary),
                                decoration: const InputDecoration(
                                  hintText: '歌单名称',
                                  hintStyle:
                                      TextStyle(color: AppColors.textFaint),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  child: const Text('取消'),
                                  onPressed: () => Navigator.pop(dCtx),
                                ),
                                TextButton(
                                  child: const Text('创建',
                                      style:
                                          TextStyle(color: AppColors.accent)),
                                  onPressed: () =>
                                      Navigator.pop(dCtx, controller.text),
                                ),
                              ],
                            ),
                          );

                          controller.dispose();

                          if (newPlName != null &&
                              newPlName.trim().isNotEmpty) {
                            final created =
                                await DatabaseService.createPlaylist(newPlName);
                            // One persist for the whole batch, not a full-file
                            // rewrite per track. Saving membership never
                            // downloads: offline availability is explicit.
                            await DatabaseService.addTracksToPlaylist(
                                created.id, tracks);
                            if (ctx.mounted) Navigator.pop(ctx);
                            onTrackChanged?.call();
                            showAppSnackBar(parentMessenger,
                                message: '已加入「${created.name}」');
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: playlists.length,
                      itemBuilder: (context, index) {
                        final pl = playlists[index];
                        return ListTile(
                          leading: Icon(
                            pl.id == Playlist.favoritesId
                                ? Icons.favorite
                                : Icons.queue_music,
                            color: pl.id == Playlist.favoritesId
                                ? AppColors.accent
                                : AppColors.textSecondary,
                          ),
                          title: Text(pl.name,
                              style: const TextStyle(
                                  color: AppColors.textPrimary)),
                          subtitle: Text('${pl.tracks.length} 首',
                              style: const TextStyle(
                                  color: AppColors.textMuted, fontSize: 12)),
                          onTap: () async {
                            await DatabaseService.addTracksToPlaylist(
                                pl.id, tracks);
                            if (ctx.mounted) Navigator.pop(ctx);
                            onTrackChanged?.call();
                            showAppSnackBar(parentMessenger,
                                message: '已加入「${pl.name}」');
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  State<TrackOptionsMenu> createState() => _TrackOptionsMenuState();
}

class _TrackOptionsMenuState extends State<TrackOptionsMenu> {
  bool _isFav = false;
  bool _isDownloaded = false;
  bool _inLibrary = false;
  StreamSubscription<String>? _downloadSub;

  @override
  void initState() {
    super.initState();
    _checkStatus();
    // The sheet stays open while a download runs, so its primary control
    // follows the ring and turns into 播放 when the file lands.
    _downloadSub = DownloadManager.instance.updates.listen((id) {
      if (id != widget.track.id || !mounted) return;
      if (DownloadManager.instance.isDownloading(id)) {
        setState(() {}); // progress tick
      } else {
        _checkStatus(); // finished or failed
      }
    });
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    super.dispose();
  }

  Future<void> _checkStatus() async {
    final fav = await DatabaseService.isFavorite(widget.track.id);
    final isDown = await AudioDownloadService.isDownloaded(widget.track);
    final playlists = await DatabaseService.getPlaylists();
    final recent = await DatabaseService.getRecentlyPlayed();
    final inLibrary = isDown ||
        playlists.any((p) => p.tracks.any((t) => t.id == widget.track.id)) ||
        recent.any((t) => t.id == widget.track.id);

    if (mounted) {
      setState(() {
        _isFav = fav;
        _isDownloaded = isDown;
        _inLibrary = inLibrary;
      });
    }
  }

  BiliBeatAudioHandler get _handler => AppServices.instance.handler;

  void _play() {
    Haptics.light();
    Navigator.pop(context);
    unawaited(_handler.playTrack(widget.track, queue: widget.queue));
  }

  void _downloadAndPlay() {
    Haptics.light();
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    // The handler downloads first and only then switches songs; the mini
    // player shows 正在准备 meanwhile.
    unawaited(_handler.playTrack(widget.track, queue: widget.queue));
    showAppSnackBar(
      messenger,
      message: '下载完成后开始播放',
      backgroundColor: AppColors.backgroundElevated,
    );
  }

  void _downloadOnly() {
    Haptics.light();
    // Not awaited: startDownload returns only once the file is on disk.
    unawaited(DownloadManager.instance.startDownload(widget.track));
    widget.onTrackChanged?.call();
    setState(() {});
  }

  Future<void> _deleteDownload() async {
    final messenger = ScaffoldMessenger.of(context);
    final track = widget.track;
    Navigator.pop(context);
    await DatabaseService.removeDownloadedTrack(track);
    widget.onTrackChanged?.call();
    showAppSnackBar(messenger,
        message: '已删除本地音频', backgroundColor: AppColors.backgroundElevated);
  }

  Future<void> _handleFavorite() async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    // Favorite only: making a track available offline is a separate,
    // explicit download action.
    final nowFav = await DatabaseService.toggleFavorite(widget.track);
    widget.onTrackChanged?.call();

    showAppSnackBar(
      messenger,
      message: nowFav ? '已收藏' : '已取消收藏',
      icon: nowFav ? Icons.favorite : Icons.favorite_border,
      backgroundColor: AppColors.backgroundElevated,
    );
  }

  Future<void> _handleRemoveFromLibrary() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final track = widget.track;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从资料库中移除'),
        content: const Text(
          '将删除本地音频，并将该曲目从所有歌单、收藏与最近播放中移除。此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    navigator.pop();

    await DatabaseService.removeFromLibrary(track);
    widget.onTrackChanged?.call();
    showAppSnackBar(messenger,
        message: '已从资料库中移除', backgroundColor: AppColors.backgroundElevated);
  }

  Future<void> _handleAddToPlaylist() async {
    final navigator = Navigator.of(context);
    final parent = navigator.context;
    navigator.pop();
    if (!parent.mounted) return;
    await TrackOptionsMenu.showAddToPlaylist(parent, widget.track,
        onTrackChanged: widget.onTrackChanged);
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final task = DownloadManager.instance.taskFor(track.id);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.backgroundElevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        10,
        20,
        16 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: AppColors.textFaint,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          const SizedBox(height: 18),

          // Header: artwork and the full, untruncated title.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: CachedCoverImage(
                  url: track.coverUrl,
                  width: 72,
                  height: 72,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.headline.copyWith(height: 1.3),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        track.uploader,
                        if (track.duration > 0)
                          formatDuration(Duration(seconds: track.duration)),
                        if (_isDownloaded) '已下载',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption.copyWith(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 18),
          _primaryActions(task),
          const SizedBox(height: 8),

          _action(
            icon: Icons.playlist_add_rounded,
            label: '加入歌单',
            onTap: _handleAddToPlaylist,
          ),
          _action(
            icon: _isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            iconColor: _isFav ? AppColors.accent : null,
            label: _isFav ? '取消收藏' : '收藏',
            onTap: _handleFavorite,
          ),
          if (_isDownloaded)
            _action(
              icon: Icons.delete_outline_rounded,
              label: '删除本地音频',
              subtitle: '保留歌单与收藏，可重新下载',
              onTap: _deleteDownload,
            ),
          if (_inLibrary)
            _action(
              icon: Icons.delete_forever_outlined,
              iconColor: AppColors.danger,
              label: '从资料库中移除',
              subtitle: '删除本地音频，并移出所有歌单与收藏',
              onTap: _handleRemoveFromLibrary,
            ),
        ],
      ),
    );
  }

  Widget _primaryActions(DownloadTask? task) {
    if (_isDownloaded) {
      return _PrimaryButton(
        icon: Icons.play_arrow_rounded,
        label: '播放',
        onPressed: _play,
      );
    }
    if (task != null) {
      return _PrimaryButton(
        icon: Icons.downloading_rounded,
        label: '下载中 ${(task.fraction * 100).round()}%',
        onPressed: null,
        progress: task.fraction,
      );
    }
    return Row(
      children: [
        Expanded(
          child: _PrimaryButton(
            icon: Icons.play_arrow_rounded,
            label: '下载并播放',
            onPressed: _downloadAndPlay,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _PrimaryButton(
            icon: Icons.download_rounded,
            label: '仅下载',
            secondary: true,
            onPressed: _downloadOnly,
          ),
        ),
      ],
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    String? subtitle,
    Color? iconColor,
  }) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: iconColor ?? AppColors.textSecondary, size: 24),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: AppTypography.body
                            .copyWith(fontWeight: FontWeight.w500)),
                    if (subtitle != null)
                      Text(subtitle, style: AppTypography.caption),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool secondary;
  final double? progress;

  const _PrimaryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.secondary = false,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final background = secondary ? AppColors.white10 : AppColors.accent;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: background)),
          if (progress != null)
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progress!.clamp(0.0, 1.0),
                child: const ColoredBox(color: AppColors.accent50),
              ),
            ),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                height: 48,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, color: AppColors.textPrimary, size: 22),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: AppTypography.body.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
