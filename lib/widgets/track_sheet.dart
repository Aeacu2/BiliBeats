import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../screens/artist_page.dart';
import '../services/database_service.dart';
import '../services/download_manager.dart';
import '../state/library_controller.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/snack.dart';
import 'cached_cover_image.dart';
import 'sheet.dart';
import 'sleep_timer_sheet.dart';
import 'track_info_sheet.dart';

/// A song's sheet: what it is, and everything you can do with it.
///
/// Doubles as the preview for songs that are not downloaded yet — the
/// primary action is then 下载并播放, which downloads first and starts the
/// song only once it is on disk (the current song keeps playing meanwhile).
///
/// Opened from the player ([forPlayer]) it drops 播放 and adds the
/// player-level extras (睡眠定时).
class TrackSheet extends StatefulWidget {
  final Track track;

  /// The queue 播放 should play within (default: the whole library).
  final List<Track>? queue;
  final bool forPlayer;

  const TrackSheet({
    super.key,
    required this.track,
    this.queue,
    this.forPlayer = false,
  });

  static Future<void> show(
    BuildContext context,
    Track track, {
    List<Track>? queue,
    bool forPlayer = false,
  }) {
    return showAppSheet<void>(
      context,
      builder: (_) =>
          TrackSheet(track: track, queue: queue, forPlayer: forPlayer),
    );
  }

  @override
  State<TrackSheet> createState() => _TrackSheetState();
}

class _TrackSheetState extends State<TrackSheet> {
  LibraryController get _library => AppServices.instance.library;
  StreamSubscription<String>? _downloadSub;

  @override
  void initState() {
    super.initState();
    // The sheet stays open while a download runs: its button fills up and
    // turns into 播放 when the file lands.
    _downloadSub = DownloadManager.instance.updates.listen((id) {
      if (id == widget.track.id && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    super.dispose();
  }

  /// Closes the sheet and returns a context that outlives it.
  BuildContext _dismiss() {
    final navigator = Navigator.of(context);
    navigator.pop();
    return navigator.context;
  }

  void _play() {
    Haptics.light();
    final downloaded = _library.isDownloaded(widget.track.id);
    final parent = _dismiss();
    unawaited(AppServices.instance.handler
        .playTrack(widget.track, queue: widget.queue));
    if (!downloaded && parent.mounted) {
      showAppSnackBar(ScaffoldMessenger.of(parent), message: '下载完成后播放');
    }
  }

  void _download() {
    Haptics.light();
    unawaited(DownloadManager.instance.startDownload(widget.track));
  }

  Future<void> _toggleFavorite() async {
    Haptics.light();
    await DatabaseService.toggleFavorite(widget.track);
  }

  Future<void> _deleteDownload() async {
    final track = widget.track;
    final parent = _dismiss();
    await DatabaseService.removeDownloadedTrack(track);
    if (parent.mounted) {
      showAppSnackBar(ScaffoldMessenger.of(parent), message: '已删除下载');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _library,
      builder: (context, _) {
        final track = _latest();
        final downloaded = _library.isDownloaded(track.id);
        final favorite = _library.isFavorite(track.id);
        final artists = LibraryController.artistNamesOf(track);

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: CachedCoverImage(
                      url: track.coverUrl,
                      width: 56,
                      height: 56,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.headline.copyWith(fontSize: 16),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          LibraryController.artistOf(track),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.caption.copyWith(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: favorite ? '取消收藏' : '收藏',
                    onPressed: _toggleFavorite,
                    icon: Icon(
                      favorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color:
                          favorite ? AppColors.accent : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (!widget.forPlayer || !downloaded)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                child: _primary(track, downloaded),
              ),
            const SizedBox(height: 4),
            SheetAction(
              icon: Icons.playlist_add_rounded,
              label: '加入歌单',
              onTap: () {
                final parent = _dismiss();
                PlaylistPicker.show(parent, [track]);
              },
            ),
            if (downloaded)
              for (final artist in artists.take(2))
                if (_library.artistNamed(artist) != null)
                  SheetAction(
                    icon: Icons.person_outline_rounded,
                    label: artist,
                    trailing: const Icon(Icons.chevron_right_rounded,
                        color: AppColors.textFaint),
                    onTap: () {
                      final parent = _dismiss();
                      ArtistPage.open(parent, artist);
                    },
                  ),
            if (downloaded)
              SheetAction(
                icon: Icons.edit_outlined,
                label: '编辑信息',
                onTap: () {
                  final parent = _dismiss();
                  TrackInfoSheet.show(parent, track);
                },
              ),
            if (widget.forPlayer)
              SheetAction(
                icon: Icons.bedtime_outlined,
                label: '睡眠定时',
                onTap: () {
                  final parent = _dismiss();
                  SleepTimerSheet.show(parent);
                },
              ),
            if (downloaded)
              SheetAction(
                icon: Icons.delete_outline_rounded,
                label: '删除下载',
                color: AppColors.danger,
                onTap: _deleteDownload,
              ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  /// The library's copy carries any edits made since the sheet's caller
  /// captured its [Track].
  Track _latest() {
    for (final track in _library.downloaded) {
      if (track.id == widget.track.id) return track;
    }
    return widget.track;
  }

  Widget _primary(Track track, bool downloaded) {
    if (downloaded) {
      return PrimaryButton(
        icon: Icons.play_arrow_rounded,
        label: '播放',
        onPressed: _play,
      );
    }
    final task = DownloadManager.instance.taskFor(track.id);
    if (task != null) {
      return PrimaryButton(
        label: '${(task.fraction * 100).round()}%',
        onPressed: null,
        progress: task.fraction,
      );
    }
    return Row(
      children: [
        Expanded(
          child: PrimaryButton(
            icon: Icons.play_arrow_rounded,
            label: '下载并播放',
            onPressed: _play,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: PrimaryButton(
            icon: Icons.download_rounded,
            label: '下载',
            secondary: true,
            onPressed: _download,
          ),
        ),
      ],
    );
  }
}

/// Picks a playlist (or makes one) to add [tracks] to.
class PlaylistPicker extends StatelessWidget {
  final List<Track> tracks;

  const PlaylistPicker({super.key, required this.tracks});

  /// Completes with true when the tracks were added somewhere.
  static Future<bool> show(BuildContext context, List<Track> tracks) async {
    if (tracks.isEmpty) return false;
    final added = await showAppSheet<bool>(
      context,
      builder: (_) => PlaylistPicker(tracks: tracks),
    );
    return added == true;
  }

  Future<void> _addTo(BuildContext context, Playlist playlist) async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context, true);
    // Membership never downloads: offline availability is its own action.
    await DatabaseService.addTracksToPlaylist(playlist.id, tracks);
    showAppSnackBar(messenger, message: '已加入「${playlist.name}」');
  }

  Future<void> _create(BuildContext context) async {
    final name = await promptForText(context, title: '新建歌单', confirm: '创建');
    if (name == null || !context.mounted) return;
    final created = await DatabaseService.createPlaylist(name);
    if (context.mounted) await _addTo(context, created);
  }

  @override
  Widget build(BuildContext context) {
    final library = AppServices.instance.library;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitle(
            '加入歌单',
            detail: tracks.length > 1 ? '${tracks.length} 首' : null,
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                SheetAction(
                  icon: Icons.add_rounded,
                  label: '新建歌单',
                  onTap: () => _create(context),
                ),
                for (final playlist in library.playlists)
                  SheetAction(
                    icon: playlist.id == Playlist.favoritesId
                        ? Icons.favorite_rounded
                        : Icons.queue_music_rounded,
                    label: playlist.name,
                    trailing: Text('${playlist.tracks.length}',
                        style: AppTypography.caption.copyWith(fontSize: 13)),
                    onTap: () => _addTo(context, playlist),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
