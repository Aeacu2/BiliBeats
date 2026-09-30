import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../app/playback_actions.dart';
import '../models/track.dart';
import '../services/local_search.dart';
import '../state/online_search_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/section_header.dart';
import '../widgets/shimmer.dart';
import '../widgets/song_tile.dart';

/// Results for the shared search bar.
///
/// Both sources are always shown; the tab decides the order:
///  * 聆听 — downloaded songs first (instant, as you type), then Bilibili;
///  * 下载 — Bilibili first, then downloaded songs.
///
/// Downloaded matches update on every keystroke. Bilibili is only queried
/// when the search key is pressed (or its row is tapped), so typing never
/// fires network requests.
class SearchResultsView extends StatefulWidget {
  final ValueListenable<String> query;
  final ValueListenable<int> tab;
  final ValueChanged<String> onSearchOnline;

  const SearchResultsView({
    super.key,
    required this.query,
    required this.tab,
    required this.onSearchOnline,
  });

  @override
  State<SearchResultsView> createState() => _SearchResultsViewState();
}

class _SearchResultsViewState extends State<SearchResultsView> {
  final AppServices _services = AppServices.instance;

  /// On 下载 the downloaded section is secondary and starts collapsed.
  bool _localExpanded = false;
  String _lastQuery = '';

  /// Local matches are recomputed only when the query or library changes.
  List<Track> _localCache = const [];
  String? _localCacheQuery;
  List<Track>? _localCacheSource;

  static const int _collapsedLocal = 3;

  List<Track> _localMatches(String query) {
    final source = _services.library.downloaded;
    if (_localCacheQuery != query || !identical(_localCacheSource, source)) {
      _localCache = LocalSearch.search(source, query);
      _localCacheQuery = query;
      _localCacheSource = source;
    }
    return _localCache;
  }

  bool _onScroll(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis == Axis.vertical &&
        metrics.maxScrollExtent > 0 &&
        metrics.pixels >= metrics.maxScrollExtent - 320) {
      final online = _services.onlineSearch;
      if (online.hasSearched && online.results.isNotEmpty) {
        online.loadMore();
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.query,
        widget.tab,
        _services.library,
        _services.onlineSearch,
      ]),
      builder: (context, _) {
        final query = widget.query.value.trim();
        if (query != _lastQuery) {
          _lastQuery = query;
          _localExpanded = false;
        }

        final slivers = query.isEmpty
            ? _idle()
            : [
                if (widget.tab.value == 0) ...[
                  ..._localSection(query, primary: true),
                  ..._onlineSection(query),
                ] else ...[
                  ..._onlineSection(query),
                  ..._localSection(query, primary: false),
                ],
              ];

        return NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              ...slivers,
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Empty query: recent searches
  // ---------------------------------------------------------------------------

  List<Widget> _idle() {
    final history = _services.onlineSearch.history;
    if (history.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: EmptyState(
              icon: Icons.search_rounded,
              title: '搜索你的音乐',
              subtitle: '已下载的歌曲随输入即时显示\n按搜索键查找哔哩哔哩',
            ),
          ),
        ),
      ];
    }
    return [
      SliverToBoxAdapter(
        child: SectionHeader(
          title: '最近搜索',
          trailing: TextButton(
            onPressed: _services.onlineSearch.clearHistory,
            child: const Text('清除'),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverToBoxAdapter(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final term in history)
                ActionChip(
                  label: Text(term),
                  labelStyle: AppTypography.bodyMedium,
                  backgroundColor: AppColors.fieldFill,
                  side: BorderSide.none,
                  shape: const StadiumBorder(),
                  onPressed: () => widget.onSearchOnline(term),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Downloaded songs
  // ---------------------------------------------------------------------------

  List<Widget> _localSection(String query, {required bool primary}) {
    final matches = _localMatches(query);
    final collapsed = !primary && !_localExpanded;
    final visible = collapsed && matches.length > _collapsedLocal
        ? matches.sublist(0, _collapsedLocal)
        : matches;
    final queue = _services.library.downloaded;

    return [
      SliverToBoxAdapter(
        child: SectionHeader(
          title: '已下载',
          count: matches.length,
        ),
      ),
      if (matches.isEmpty)
        const SliverToBoxAdapter(
          child: _Note('没有匹配的已下载歌曲'),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverFixedExtentList(
            itemExtent: SongTile.extent,
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final track = visible[index];
                return SongTile(
                  track: track,
                  queue: queue,
                  onTap: () => openTrack(context, track, queue: queue),
                );
              },
              childCount: visible.length,
            ),
          ),
        ),
      if (visible.length < matches.length)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => setState(() => _localExpanded = true),
                child: Text(
                  '显示全部 ${matches.length} 首',
                  style: const TextStyle(color: AppColors.accent),
                ),
              ),
            ),
          ),
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Bilibili
  // ---------------------------------------------------------------------------

  List<Widget> _onlineSection(String query) {
    final online = _services.onlineSearch;
    final header = SliverToBoxAdapter(
      child: SectionHeader(
        title: '哔哩哔哩',
        count: online.query == query && online.results.isNotEmpty
            ? online.results.length
            : null,
      ),
    );

    // Results belong to the submitted query only; for anything else typed
    // since, offer the search instead of showing stale results.
    if (online.query != query) {
      return [
        header,
        SliverToBoxAdapter(
          child: _SearchPrompt(
            query: query,
            onTap: () => widget.onSearchOnline(query),
          ),
        ),
      ];
    }

    if (online.loading) {
      return [
        header,
        const SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverToBoxAdapter(
            child: Column(
              children: [
                SkeletonTrackTile(),
                SkeletonTrackTile(),
                SkeletonTrackTile(),
                SkeletonTrackTile(),
              ],
            ),
          ),
        ),
      ];
    }

    if (online.failed) {
      return [
        header,
        SliverToBoxAdapter(
          child: _RetryNote(
            message: '暂时无法连接哔哩哔哩',
            onRetry: online.retry,
          ),
        ),
      ];
    }

    if (online.results.isEmpty) {
      return [
        header,
        const SliverToBoxAdapter(
          child: _Note('没有找到相关结果，试试 BV 号或更短的关键词'),
        ),
      ];
    }

    return [
      header,
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverFixedExtentList(
          itemExtent: SongTile.extent,
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final track = online.results[index];
              return SongTile(
                track: track,
                showDownload: true,
                onTap: () => openTrack(context, track),
              );
            },
            childCount: online.results.length,
          ),
        ),
      ),
      SliverToBoxAdapter(child: _footer(online)),
    ];
  }

  Widget _footer(OnlineSearchController online) {
    if (online.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (online.loadMoreFailed) {
      return _RetryNote(message: '加载失败', onRetry: online.loadMore);
    }
    if (online.reachedEnd) return const _Note('没有更多了', center: true);
    return const SizedBox(height: 20);
  }
}

class _SearchPrompt extends StatelessWidget {
  final String query;
  final VoidCallback onTap;

  const _SearchPrompt({required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: SongTile.artSize,
                  height: SongTile.artSize,
                  decoration: BoxDecoration(
                    color: AppColors.fieldFill,
                    borderRadius: BorderRadius.circular(AppRadius.sm - 2),
                  ),
                  child: const Icon(Icons.travel_explore_rounded,
                      color: AppColors.accent, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    '在哔哩哔哩搜索「$query」',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.body.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
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
}

class _Note extends StatelessWidget {
  final String text;
  final bool center;

  const _Note(this.text, {this.center = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Text(
        text,
        textAlign: center ? TextAlign.center : TextAlign.start,
        style: AppTypography.caption.copyWith(fontSize: 13),
      ),
    );
  }
}

class _RetryNote extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _RetryNote({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: AppTypography.caption.copyWith(fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            child: const Text('重试', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }
}
