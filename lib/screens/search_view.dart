import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../app/playback_actions.dart';
import '../models/track.dart';
import '../services/local_search.dart';
import '../state/online_search_controller.dart';
import '../state/recommendations_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/shimmer.dart';
import '../widgets/song_tile.dart';

/// What the search bar shows once it has focus.
///
/// * Nothing typed: recent searches, then recommendations to download.
/// * Typing: matches from your own library, instantly, with one row that
///   takes the query to Bilibili.
/// * Submitted: Bilibili's results, under any library matches.
///
/// Bilibili is only queried on submit (the search key, or that row), so
/// typing never fires network requests.
class SearchView extends StatefulWidget {
  final ValueListenable<String> query;
  final ValueChanged<String> onSearchOnline;

  const SearchView({
    super.key,
    required this.query,
    required this.onSearchOnline,
  });

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final AppServices _services = AppServices.instance;

  OnlineSearchController get _online => _services.onlineSearch;
  RecommendationsController get _recs => _services.recommendations;

  /// With Bilibili results on screen the library section stays short unless
  /// asked for in full.
  bool _localExpanded = false;
  String _lastQuery = '';

  /// Library matches are recomputed only when the query or library changes.
  List<Track> _localCache = const [];
  String? _localCacheQuery;
  List<Track>? _localCacheSource;

  static const int _collapsedLocal = 3;

  @override
  void initState() {
    super.initState();
    _recs.ensureLoaded();
  }

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
      if (widget.query.value.trim().isEmpty) {
        _recs.loadMore();
      } else if (_online.hasSearched && _online.results.isNotEmpty) {
        _online.loadMore();
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.query,
        _services.library,
        _online,
        _recs,
      ]),
      builder: (context, _) {
        final query = widget.query.value.trim();
        if (query != _lastQuery) {
          _lastQuery = query;
          _localExpanded = false;
        }

        return NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              if (query.isEmpty) ..._idle() else ..._results(query),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Nothing typed: history and recommendations
  // ---------------------------------------------------------------------------

  List<Widget> _idle() {
    final history = _online.history;
    return [
      if (history.isNotEmpty)
        SliverToBoxAdapter(
          child: SizedBox(
            height: 44,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: history.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) => Center(
                child: _Chip(
                  label: history[index],
                  onTap: () => widget.onSearchOnline(history[index]),
                ),
              ),
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: _Label(
          '为你推荐',
          trailing: IconButton(
            tooltip: '换一批',
            onPressed: _recs.loading ? null : _recs.refresh,
            icon: const Icon(Icons.refresh_rounded,
                color: AppColors.textMuted, size: 20),
          ),
        ),
      ),
      ..._recommendations(),
    ];
  }

  List<Widget> _recommendations() {
    if (!_recs.loaded || (_recs.loading && _recs.tracks.isEmpty)) {
      return const [_Skeletons()];
    }
    if (_recs.tracks.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: _recs.failed
              ? EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: '推荐加载失败',
                  action: _retry(_recs.refresh),
                )
              : const EmptyState(
                  icon: Icons.auto_awesome_outlined,
                  title: '听几首歌之后，这里会有推荐',
                ),
        ),
      ];
    }
    return [
      _songs(_recs.tracks),
      if (_recs.loadingMore) const SliverToBoxAdapter(child: _Spinner()),
    ];
  }

  // ---------------------------------------------------------------------------
  // A query: library first, then Bilibili
  // ---------------------------------------------------------------------------

  List<Widget> _results(String query) {
    final matches = _localMatches(query);
    final submitted = _online.query == query;
    final collapsed =
        submitted && !_localExpanded && matches.length > _collapsedLocal;
    final visible = collapsed ? matches.sublist(0, _collapsedLocal) : matches;
    final library = _services.library.downloaded;

    return [
      if (matches.isNotEmpty) ...[
        const SliverToBoxAdapter(child: _Label('我的音乐')),
        _songs(visible, queue: library),
        if (collapsed)
          SliverToBoxAdapter(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: TextButton(
                  onPressed: () => setState(() => _localExpanded = true),
                  child: Text('全部 ${matches.length} 首'),
                ),
              ),
            ),
          ),
      ],
      if (!submitted)
        SliverToBoxAdapter(
          child: _SearchPrompt(
            query: query,
            onTap: () => widget.onSearchOnline(query),
          ),
        )
      else ...[
        const SliverToBoxAdapter(child: _Label('哔哩哔哩')),
        ..._onlineResults(),
      ],
    ];
  }

  List<Widget> _onlineResults() {
    if (_online.loading) return const [_Skeletons()];
    if (_online.failed) {
      return [
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.cloud_off_rounded,
            title: '无法连接哔哩哔哩',
            action: _retry(_online.retry),
          ),
        ),
      ];
    }
    if (_online.results.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.search_off_rounded,
            title: '没有找到，换个关键词或粘贴 BV 号试试',
          ),
        ),
      ];
    }
    return [
      _songs(_online.results),
      if (_online.loadingMore)
        const SliverToBoxAdapter(child: _Spinner())
      else if (_online.loadMoreFailed)
        SliverToBoxAdapter(child: Center(child: _retry(_online.loadMore))),
    ];
  }

  Widget _songs(List<Track> tracks, {List<Track>? queue}) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      sliver: SliverFixedExtentList.builder(
        itemExtent: SongTile.extent,
        itemCount: tracks.length,
        itemBuilder: (context, index) {
          final track = tracks[index];
          return SongTile(
            track: track,
            queue: queue,
            onTap: () => openTrack(context, track, queue: queue),
          );
        },
      ),
    );
  }

  Widget _retry(VoidCallback onPressed) => TextButton(
        onPressed: onPressed,
        child: const Text('重试', style: TextStyle(color: AppColors.accent)),
      );
}

class _Label extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const _Label(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 6, 2),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Text(text, style: AppTypography.section),
            const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _Chip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.fieldFill,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodyMedium,
            ),
          ),
        ),
      ),
    );
  }
}

/// The row that takes what was typed to Bilibili.
class _SearchPrompt extends StatelessWidget {
  final String query;
  final VoidCallback onTap;

  const _SearchPrompt({required this.query, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onTap,
          child: SizedBox(
            height: SongTile.extent,
            child: Row(
              children: [
                const SizedBox(width: 4),
                Container(
                  width: SongTile.artSize,
                  height: SongTile.artSize,
                  decoration: BoxDecoration(
                    color: AppColors.fieldFill,
                    borderRadius: BorderRadius.circular(AppRadius.sm - 2),
                  ),
                  child: const Icon(Icons.search_rounded,
                      color: AppColors.accent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      text: '在哔哩哔哩搜索 ',
                      style: AppTypography.body
                          .copyWith(color: AppColors.textSecondary),
                      children: [
                        TextSpan(
                          text: query,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.north_east_rounded,
                    color: AppColors.textFaint, size: 18),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Skeletons extends StatelessWidget {
  const _Skeletons();

  @override
  Widget build(BuildContext context) {
    return const SliverPadding(
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
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) {
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
}
