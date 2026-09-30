import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../app/playback_actions.dart';
import '../state/library_controller.dart';
import '../state/recommendations_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/download_management_sheet.dart';
import '../widgets/empty_state.dart';
import '../widgets/section_header.dart';
import '../widgets/shimmer.dart';
import '../widgets/song_tile.dart';
import '../widgets/track_download_button.dart';

/// 下载 — getting new music: downloads in progress, what failed, and
/// recommendations to download next. Searching Bilibili happens in the
/// shared search bar above (results lead with Bilibili on this tab).
class DownloadTab extends StatefulWidget {
  const DownloadTab({super.key});

  @override
  State<DownloadTab> createState() => _DownloadTabState();
}

class _DownloadTabState extends State<DownloadTab>
    with AutomaticKeepAliveClientMixin {
  LibraryController get _library => AppServices.instance.library;
  RecommendationsController get _recs => AppServices.instance.recommendations;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _recs.ensureLoaded();
  }

  bool _onScroll(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis == Axis.vertical &&
        metrics.maxScrollExtent > 0 &&
        metrics.pixels >= metrics.maxScrollExtent - 320) {
      _recs.loadMore();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_library, _recs]),
      builder: (context, _) {
        final active = _library.activeDownloads;
        final failed = _library.failedDownloadCount;

        return NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: RefreshIndicator(
            color: AppColors.accent,
            backgroundColor: AppColors.backgroundElevated,
            onRefresh: _recs.refresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _summary(failed)),
                if (active.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: SectionHeader(title: '下载中', count: active.length),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverFixedExtentList(
                      itemExtent: SongTile.extent,
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final track = active[index].track;
                          return SongTile(
                            track: track,
                            trailing:
                                TrackDownloadButton(track: track, size: 22),
                          );
                        },
                        childCount: active.length,
                      ),
                    ),
                  ),
                ],
                SliverToBoxAdapter(
                  child: SectionHeader(
                    title: '为你推荐',
                    trailing: IconButton(
                      tooltip: '换一批',
                      onPressed: _recs.loading ? null : _recs.refresh,
                      icon: const Icon(Icons.refresh_rounded,
                          color: AppColors.textMuted),
                    ),
                  ),
                ),
                ..._recommendations(),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _summary(int failed) {
    final count = _library.downloaded.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Material(
        color: AppColors.fieldFill,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => DownloadManagementSheet.show(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                const Icon(Icons.download_done_rounded,
                    color: AppColors.textSecondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('已下载 $count 首', style: AppTypography.headline),
                      const SizedBox(height: 2),
                      Text(
                        failed > 0 ? '$failed 首下载失败，点按重试' : '管理下载与存储空间',
                        style: AppTypography.caption.copyWith(
                          color: failed > 0 ? AppColors.danger : null,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _recommendations() {
    if (!_recs.loaded || (_recs.loading && _recs.tracks.isEmpty)) {
      return const [
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverToBoxAdapter(
            child: Column(
              children: [
                SkeletonTrackTile(),
                SkeletonTrackTile(),
                SkeletonTrackTile(),
              ],
            ),
          ),
        ),
      ];
    }

    if (_recs.tracks.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: _recs.failed
              ? Center(
                  child: TextButton(
                    onPressed: _recs.refresh,
                    child: const Text('推荐加载失败，点按重试',
                        style: TextStyle(color: AppColors.accent)),
                  ),
                )
              : const EmptyState(
                  icon: Icons.auto_awesome_rounded,
                  title: '先搜索一首歌',
                  subtitle: '推荐会根据你的收藏、播放与搜索生成',
                ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverFixedExtentList(
          itemExtent: SongTile.extent,
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final track = _recs.tracks[index];
              return SongTile(
                track: track,
                showDownload: true,
                onTap: () => openTrack(context, track),
              );
            },
            childCount: _recs.tracks.length,
          ),
        ),
      ),
      if (_recs.loadingMore)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ),
    ];
  }
}
