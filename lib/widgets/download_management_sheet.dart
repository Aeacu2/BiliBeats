import 'dart:async';

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/audio_download_service.dart';
import '../services/database_service.dart';
import '../services/download_manager.dart';
import '../services/library_transfer.dart';
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
/// The persistent import queue shares this view, including queued songs
/// and controls that also update the on-disk queue.
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
    LibraryTransfer.status.addListener(_queueChanged);
    _refreshTasks();
    _refreshLibrary();
    _dlSub = DownloadManager.instance.updates.listen((_) => _refreshTasks());
    _libSub =
        DatabaseService.libraryUpdateStream.listen((_) => _refreshLibrary());
  }

  void _queueChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    LibraryTransfer.status.removeListener(_queueChanged);
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
    if (same(active, _active, (t) => '${t.track.id}${t.retrying}') &&
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
    final queue = LibraryTransfer.status.value;
    final queued = LibraryTransfer.queuedTracks;
    final isEmpty = _active.isEmpty &&
        _failed.isEmpty &&
        _downloaded.isEmpty &&
        queue.pending == 0;

    final rows = <Widget Function()>[
      for (final task in _active)
        () => SongTile(
              key: ValueKey('active-${task.track.id}'),
              track: task.track,
              detail: task.retrying ? '连接中断，稍后自动重试' : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TrackDownloadButton(track: task.track, size: 22),
                  _icon(
                    tooltip: '取消下载',
                    icon: Icons.close_rounded,
                    onPressed: () => LibraryTransfer.cancelTrack(task.track.id),
                  ),
                ],
              ),
            ),
      for (final failed in _failed)
        () => SongTile(
              key: ValueKey('failed-${failed.track.id}'),
              track: failed.track,
              // Bilibili's own reason, where it refused the
              // video outright; otherwise the plain fact.
              detail: failed.error.startsWith('无法下载') ? failed.error : '下载失败',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _icon(
                    tooltip: '重试',
                    icon: Icons.refresh_rounded,
                    color: AppColors.accent,
                    onPressed: () {
                      Haptics.light();
                      if (LibraryTransfer.contains(failed.track.id)) {
                        unawaited(LibraryTransfer.retryTrack(failed.track.id));
                      } else {
                        DownloadManager.instance.retryDownload(failed.track.id);
                      }
                    },
                  ),
                  _icon(
                    tooltip: '忽略',
                    icon: Icons.close_rounded,
                    onPressed: () {
                      unawaited(LibraryTransfer.cancelTrack(failed.track.id));
                      DownloadManager.instance.dismissFailed(failed.track.id);
                    },
                  ),
                ],
              ),
            ),
      for (final track in LibraryTransfer.failedTracks
          .where((t) => !_failed.any((f) => f.track.id == t.id)))
        () => SongTile(
            track: track,
            key: ValueKey('import-failed-${track.id}'),
            detail: '下载失败',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              _icon(
                  tooltip: '重试',
                  icon: Icons.refresh_rounded,
                  onPressed: () => LibraryTransfer.retryTrack(track.id)),
              _icon(
                  tooltip: '忽略',
                  icon: Icons.close_rounded,
                  onPressed: () => LibraryTransfer.cancelTrack(track.id)),
            ])),
      for (final track in queued)
        () => SongTile(
            track: track,
            key: ValueKey('queued-${track.id}'),
            detail: queue.paused ? '已暂停' : '等待下载',
            trailing: _icon(
                tooltip: '取消排队',
                icon: Icons.close_rounded,
                onPressed: () => LibraryTransfer.cancelTrack(track.id))),
      for (final track in _downloaded)
        () => SongTile(
              key: ValueKey('done-${track.id}'),
              track: track,
              detail: formatBytes(_sizes[track.id] ?? 0),
              trailing: _icon(
                tooltip: '删除下载',
                icon: Icons.delete_outline_rounded,
                onPressed: () => _remove(track),
              ),
            ),
    ];
    return Column(
      children: [
        SheetTitle(
          '下载',
          detail: _downloaded.isEmpty
              ? null
              : '${_downloaded.length} 首 · ${formatBytes(totalBytes)}',
        ),
        if (queue.pending > 0)
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 8),
            child: Row(children: [
              Expanded(
                  child: Text(
                      '${queue.paused ? '已暂停' : '导入'} · ${queue.completed}/${queue.total}'
                      '${queue.failed > 0 ? ' · ${queue.failed} 首失败' : ''}',
                      style: AppTypography.caption)),
              if (queue.failed > 0)
                _icon(
                    tooltip: '重试导入失败项',
                    icon: Icons.refresh_rounded,
                    onPressed: LibraryTransfer.retryFailed),
              _icon(
                  tooltip: queue.paused ? '继续导入' : '暂停导入',
                  icon: queue.paused
                      ? Icons.play_arrow_rounded
                      : Icons.pause_rounded,
                  onPressed: () => queue.paused
                      ? LibraryTransfer.continueDownloads()
                      : LibraryTransfer.pause()),
              _icon(
                  tooltip: '取消剩余导入',
                  icon: Icons.close_rounded,
                  onPressed: LibraryTransfer.cancelAll),
            ]),
          ),
        Expanded(
          child: isEmpty
              ? const EmptyState(
                  icon: Icons.download_rounded,
                  title: '暂无下载',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 16),
                  itemCount: rows.length,
                  itemBuilder: (context, index) => rows[index](),
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
      width: 48,
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
