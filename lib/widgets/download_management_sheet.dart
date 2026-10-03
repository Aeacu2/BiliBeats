import 'dart:async';

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/audio_download_service.dart';
import '../services/database_service.dart';
import '../services/download_manager.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/format.dart';
import 'empty_state.dart';
import 'sheet.dart';
import 'song_tile.dart';
import 'track_download_button.dart';

/// Downloads in one list: what is in flight, what failed (retry or dismiss),
/// and what is stored, with its size and a way to remove it.
///
/// Deliberately no Cancel: the service has no cancellation, and a
/// disappearing row is not cancellation.
class DownloadManagementSheet extends StatefulWidget {
  const DownloadManagementSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showAppSheet<void>(
      context,
      expand: true,
      builder: (_) => const DownloadManagementSheet(),
    );
  }

  @override
  State<DownloadManagementSheet> createState() =>
      _DownloadManagementSheetState();
}

class _DownloadManagementSheetState extends State<DownloadManagementSheet> {
  List<Track> _downloaded = [];
  Map<String, int> _sizes = {};
  List<DownloadTask> _active = [];
  List<FailedDownload> _failed = [];
  StreamSubscription<String>? _dlSub;
  StreamSubscription<void>? _libSub;

  @override
  void initState() {
    super.initState();
    _refreshTasks();
    _refreshLibrary();
    _dlSub = DownloadManager.instance.updates.listen((_) => _refreshTasks());
    _libSub =
        DatabaseService.libraryUpdateStream.listen((_) => _refreshLibrary());
  }

  @override
  void dispose() {
    _dlSub?.cancel();
    _libSub?.cancel();
    super.dispose();
  }

  void _refreshTasks() {
    if (!mounted) return;
    final active = DownloadManager.instance.activeTasks;
    final failed = DownloadManager.instance.failedTasks;
    // Progress ticks are drawn by each row's own ring; only membership
    // matters here. Compared by id: one download finishing as another
    // starts leaves the counts equal and the rows wrong.
    bool same<T>(List<T> a, List<T> b, String Function(T) id) =>
        a.length == b.length &&
        Iterable<int>.generate(a.length).every((i) => id(a[i]) == id(b[i]));
    if (same(active, _active, (t) => t.track.id) &&
        same(failed, _failed, (f) => f.track.id)) {
      return;
    }
    setState(() {
      _active = active;
      _failed = failed;
    });
  }

  Future<void> _refreshLibrary() async {
    final downloaded = await DatabaseService.getDownloadedTracks();
    final sizes = await AudioDownloadService.storageBreakdown();
    if (!mounted) return;
    setState(() {
      _downloaded = downloaded;
      _sizes = sizes;
    });
  }

  Future<void> _remove(Track track) async {
    if (!await confirmAction(
      context,
      title: '删除「${track.title}」的下载？',
      confirm: '删除',
    )) {
      return;
    }
    await DatabaseService.removeDownloadedTrack(track);
  }

  @override
  Widget build(BuildContext context) {
    final totalBytes = _sizes.values.fold<int>(0, (sum, b) => sum + b);
    final isEmpty = _active.isEmpty && _failed.isEmpty && _downloaded.isEmpty;

    return Column(
      children: [
        SheetTitle(
          '下载',
          detail: _downloaded.isEmpty
              ? null
              : '${_downloaded.length} 首 · ${formatBytes(totalBytes)}',
        ),
        Expanded(
          child: isEmpty
              ? const EmptyState(
                  icon: Icons.download_rounded,
                  title: '暂无下载',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 16),
                  children: [
                    for (final task in _active)
                      SongTile(
                        key: ValueKey('active-${task.track.id}'),
                        track: task.track,
                        trailing:
                            TrackDownloadButton(track: task.track, size: 22),
                      ),
                    for (final failed in _failed)
                      SongTile(
                        key: ValueKey('failed-${failed.track.id}'),
                        track: failed.track,
                        detail: '下载失败',
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _icon(
                              tooltip: '重试',
                              icon: Icons.refresh_rounded,
                              color: AppColors.accent,
                              onPressed: () {
                                Haptics.light();
                                DownloadManager.instance
                                    .retryDownload(failed.track.id);
                              },
                            ),
                            _icon(
                              tooltip: '忽略',
                              icon: Icons.close_rounded,
                              onPressed: () => DownloadManager.instance
                                  .dismissFailed(failed.track.id),
                            ),
                          ],
                        ),
                      ),
                    for (final track in _downloaded)
                      SongTile(
                        key: ValueKey('done-${track.id}'),
                        track: track,
                        detail: formatBytes(_sizes[track.id] ?? 0),
                        trailing: _icon(
                          tooltip: '删除下载',
                          icon: Icons.delete_outline_rounded,
                          onPressed: () => _remove(track),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _icon({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    Color color = AppColors.textFaint,
  }) {
    return SizedBox(
      width: 44,
      height: 48,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        icon: Icon(icon, color: color, size: 21),
      ),
    );
  }
}
