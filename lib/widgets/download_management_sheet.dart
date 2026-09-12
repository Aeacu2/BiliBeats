import 'dart:async';

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../services/audio_download_service.dart';
import '../services/database_service.dart';
import '../services/download_manager.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/snack.dart';
import 'cached_cover_image.dart';
import 'empty_state.dart';
import 'marquee_text.dart';
import 'progress_ring.dart';
import 'track_row.dart';

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text =
      value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// Quiet download management: active progress, failed items with Retry,
/// and completed storage with explicit remove-download.
///
/// Deliberately no Cancel: the service has no cancellation, and a
/// disappearing row is not cancellation.
class DownloadManagementSheet extends StatefulWidget {
  const DownloadManagementSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.backgroundElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
      ),
      builder: (context) => const DownloadManagementSheet(),
    );
  }

  @override
  State<DownloadManagementSheet> createState() =>
      _DownloadManagementSheetState();
}

class _DownloadManagementSheetState
    extends State<DownloadManagementSheet> {
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
    _dlSub =
        DownloadManager.instance.updates.listen((_) => _refreshTasks());
    _libSub = DatabaseService.libraryUpdateStream
        .listen((_) => _refreshLibrary());
  }

  @override
  void dispose() {
    _dlSub?.cancel();
    _libSub?.cancel();
    super.dispose();
  }

  void _refreshTasks() {
    if (!mounted) return;
    setState(() {
      _active = DownloadManager.instance.activeTasks;
      _failed = DownloadManager.instance.failedTasks;
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

  Future<void> _confirmRemoveDownload(Track track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.backgroundElevated,
        title: const Text('删除本地音频',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text('将删除本地音频，可重新下载。歌单与收藏保留。',
            style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await DatabaseService.removeDownloadedTrack(track);
    if (!mounted) return;
    showAppSnackBar(ScaffoldMessenger.of(context),
        message: '已删除本地音频',
        backgroundColor: AppColors.backgroundElevated);
  }

  @override
  Widget build(BuildContext context) {
    final totalBytes =
        _sizes.values.fold<int>(0, (sum, b) => sum + b);
    final isEmpty =
        _active.isEmpty && _failed.isEmpty && _downloaded.isEmpty;

    return FractionallySizedBox(
      heightFactor: 0.78,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '下载管理',
                          style: AppTypography.title,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '共 ${_downloaded.length} 首 · ${_formatBytes(totalBytes)}',
                          style: AppTypography.caption,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: isEmpty
                  ? const Center(
                      child: EmptyState(
                        icon: Icons.download_rounded,
                        title: '暂无下载',
                        subtitle: '下载的歌曲会在这里管理',
                      ),
                    )
                  : ListView(
                      padding:
                          const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      children: [
                        if (_active.isNotEmpty) ...[
                          const _SectionHeader('下载中'),
                          for (final task in _active)
                            _trackTile(
                              key: ValueKey('active-${task.track.id}'),
                              track: task.track,
                              subtitle:
                                  '正在下载 · ${(task.fraction * 100).toStringAsFixed(0)}%',
                              trailing: ProgressRing(
                                fraction: task.fraction,
                                size: 34,
                                child: const Icon(
                                  Icons.download_rounded,
                                  color: AppColors.textSecondary,
                                  size: 16,
                                ),
                              ),
                            ),
                        ],
                        if (_failed.isNotEmpty) ...[
                          const _SectionHeader('下载失败'),
                          for (final failed in _failed)
                            _trackTile(
                              key: ValueKey('failed-${failed.track.id}'),
                              track: failed.track,
                              subtitle: failed.error.isEmpty
                                  ? '下载未完成'
                                  : failed.error,
                              subtitleLines: 2,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: IconButton(
                                      tooltip: '重试',
                                      onPressed: () {
                                        Haptics.light();
                                        DownloadManager.instance
                                            .retryDownload(
                                                failed.track.id);
                                      },
                                      icon: const Icon(
                                        Icons.refresh_rounded,
                                        color: AppColors.accent,
                                        size: 22,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: IconButton(
                                      tooltip: '忽略',
                                      onPressed: () {
                                        DownloadManager.instance
                                            .dismissFailed(
                                                failed.track.id);
                                      },
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        color: AppColors.textMuted,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                        if (_downloaded.isNotEmpty) ...[
                          const _SectionHeader('已下载'),
                          for (final track in _downloaded)
                            _trackTile(
                              key: ValueKey(
                                  'done-${track.id}'),
                              track: track,
                              subtitle: _formatBytes(
                                  _sizes[track.id] ?? 0),
                              trailing: SizedBox(
                                width: 48,
                                height: 48,
                                child: IconButton(
                                  tooltip: '删除本地音频',
                                  onPressed: () =>
                                      _confirmRemoveDownload(track),
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    color: AppColors.textMuted,
                                    size: 22,
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
    );
  }

  Widget _trackTile({
    required Key key,
    required Track track,
    required String subtitle,
    int subtitleLines = 1,
    required Widget trailing,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: TrackRow.gap),
      child: TrackRow(
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: CachedCoverImage(
                url: track.coverUrl,
                width: 48,
                height: 48,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MarqueeText(
                    text: track.title,
                    style: AppTypography.body.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: subtitleLines,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        title,
        style: AppTypography.title.copyWith(fontSize: 17),
      ),
    );
  }
}
