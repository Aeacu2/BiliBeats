import 'package:flutter/material.dart';
import '../models/track.dart';
import '../services/bilibili_sdk.dart';
import '../services/database_service.dart';
import '../services/recommendation_engine.dart';
import '../utils/format.dart';
import '../widgets/glass_card.dart';
import '../widgets/track_options_menu.dart';
import '../theme/app_theme.dart';
import '../widgets/cached_cover_image.dart';
import '../widgets/empty_state.dart';
import '../widgets/marquee_text.dart';
import '../widgets/shimmer.dart';
import '../widgets/track_download_button.dart';
import '../widgets/track_row.dart';

class SearchScreen extends StatefulWidget {
  final TrackAction onSelectTrack;
  final TrackAction? onPlayOnly;

  const SearchScreen({
    super.key,
    required this.onSelectTrack,
    this.onPlayOnly,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  List<Track> _searchResults = [];
  List<Track> _recommendedTracks = [];
  bool _isLoading = false;
  bool _isLoadingRecommended = true;
  bool _hasSearched = false;
  String _lastQuery = '';

  List<String> _searchHistory = [];

  bool _wasFocused = false;
  bool _hadText = false;
  bool _recommendationsStale = false;

  /// Monotonic token so a slow earlier search can never overwrite the results
  /// of a later one.
  int _searchToken = 0;

  /// Guards the search-history read/write round-trips: clearing history must
  /// not be undone by an older read completing late.
  int _historyToken = 0;

  /// Operation-identity ticket for pagination loading state. A completion
  /// may only release loading when it still owns the operation — a shared
  /// boolean cleared unconditionally lets an old request kill a newer
  /// request's spinner.
  Object? _loadMoreOwner;

  // --- Pagination / infinite scroll ----------------------------------------
  final ScrollController _scrollController = ScrollController();

  /// Guards re-entrant "load more" fetches.
  bool _isLoadingMore = false;

  // Search pagination.
  int _searchPage = 1;
  final Set<String> _seenSearchIds = {};
  bool _searchReachedEnd = false;

  // Recommendation pagination.
  int _recPage = 0;
  final Set<String> _seenRecIds = {};
  bool _recReachedEnd = false;

  /// Monotonic pass counter so a slow recommendation fetch can never append a
  /// stale batch after a fresh pass reset the page and the seen-set.
  int _recPass = 0;

  /// A load-more fetch that failed gets a quiet retry window instead of
  /// re-firing on every scroll pixel, and the footer shows why the list
  /// stopped growing.
  bool _searchLoadFailed = false;
  bool _recLoadFailed = false;
  DateTime _lastSearchFail = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRecFail = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    _searchController.addListener(_onTextChange);
    _scrollController.addListener(_onScroll);
    _loadSearchHistory();
  }

  Future<void> _loadSearchHistory() async {
    final token = _historyToken;
    final history = await DatabaseService.getSearchHistory();
    // Startup read must not overwrite a later user action (e.g. clearing
    // history while this read was in flight).
    if (!mounted || token != _historyToken) return;
    setState(() => _searchHistory = history);
    _loadRecommendations();
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _searchController.removeListener(_onTextChange);
    _focusNode.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    final focused = _focusNode.hasFocus;
    if (focused != _wasFocused) {
      _wasFocused = focused;
      setState(() {});
    }
  }

  void _onTextChange() {
    // The only thing the text drives in this build is the clear button, so
    // rebuilding the entire result list on every keystroke is wasted work.
    final hasText = _searchController.text.isNotEmpty;
    if (hasText != _hadText) {
      _hadText = hasText;
      setState(() {});
    }
  }

  /// Recommendations are only meaningful once there is something to learn
  /// from, and the first search is the earliest moment that is true — so the
  /// section stays hidden until then. Clearing search history hides it again,
  /// which is deliberate: it is one of the three signals feeding the profile.
  bool get _canRecommend => _searchHistory.isNotEmpty;

  Future<void> _loadRecommendations() async {
    // Invalidate the previous pass even when there is currently nothing to
    // recommend: an older fetch must not repopulate after history is gone.
    final pass = ++_recPass;
    if (!_canRecommend) {
      if (mounted) {
        setState(() {
          _recommendedTracks = const [];
          _isLoadingRecommended = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _isLoadingRecommended = true;
        // A fresh pass owns pagination now; a load-more still in flight
        // from the old pass must not clear the new loading state.
        _isLoadingMore = false;
        _loadMoreOwner = null;
      });
    }
    // A fresh recommendation pass restarts pagination from page 1. Its token
    // invalidates any load-more that was in flight when the pass began.
    _recPage = 1;
    _seenRecIds.clear();
    _recReachedEnd = false;
    _recLoadFailed = false;
    try {
      final tracks = await RecommendationEngine.recommend();
      if (!mounted || pass != _recPass) return;
      for (final t in tracks) {
        _seenRecIds.add(t.id);
      }
      setState(() {
        _recommendedTracks = tracks;
        _isLoadingRecommended = false;
        _recommendationsStale = false;
        _recLoadFailed = false;
        if (tracks.isEmpty) _recReachedEnd = true;
      });
    } catch (_) {
      if (mounted && pass == _recPass) {
        setState(() {
          _isLoadingRecommended = false;
          _recLoadFailed = true;
          _lastRecFail = DateTime.now();
        });
      }
    }
  }

  /// Returning to the recommendation view after searching is the natural place
  /// to fold that new signal in — refreshing on every keystroke or every
  /// search would mean several extra requests per query.
  void _showRecommendations() {
    // Invalidate any in-flight search: it must not repopulate results after
    // the user cleared the field, and its loading/pagination state is dead.
    ++_searchToken;
    _loadMoreOwner = null;
    _searchController.clear();
    setState(() {
      _searchResults = const [];
      _hasSearched = false;
      _isLoading = false;
      _isLoadingMore = false;
      _searchLoadFailed = false;
      _searchPage = 1;
      _seenSearchIds.clear();
      _searchReachedEnd = false;
    });
    if (_recommendationsStale) _loadRecommendations();
  }

  Future<void> _clearSearchHistory() async {
    // Invalidate recommendation work and the startup history read before
    // touching storage, so neither can restore the cleared chips.
    ++_recPass;
    ++_historyToken;
    _loadMoreOwner = null;
    await DatabaseService.clearSearchHistory();
    if (!mounted) return;
    // Search history feeds the taste profile, so dropping it must drop its
    // influence too — not just the chips. Also reset dedup sets so a later
    // fresh pass doesn't consider old ids as seen.
    setState(() {
      _searchHistory = const [];
      _recommendedTracks = const [];
      _isLoadingRecommended = false;
      _isLoadingMore = false;
      _recLoadFailed = false;
      _seenRecIds.clear();
      _seenSearchIds.clear();
      _recReachedEnd = false;
      _searchReachedEnd = false;
      _recPage = 0;
      _searchPage = 1;
      _recommendationsStale = true;
    });
  }

  Future<void> _performSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    // Allocate ownership before the first await: rapid submissions must not
    // finish their history writes out of order, and loading shows at once.
    final token = ++_searchToken;
    final historyToken = _historyToken;
    _focusNode.unfocus();
    setState(() {
      _isLoading = true;
      _hasSearched = true;
      _lastQuery = trimmed;
      // A new query restarts pagination from page 1 and takes loading
      // ownership from any in-flight load-more.
      _searchResults = const [];
      _seenSearchIds.clear();
      _searchPage = 1;
      _searchReachedEnd = false;
      _searchLoadFailed = false;
      _isLoadingMore = false;
      _loadMoreOwner = null;
    });

    List<String> history;
    try {
      history = await DatabaseService.addSearchHistory(trimmed);
    } catch (e) {
      debugPrint('Search history write failed: $e');
      if (!mounted || token != _searchToken) return;
      history = _searchHistory;
    }
    // Leaving the tab during those awaits would otherwise unfocus a disposed
    // FocusNode and setState on a dead State.
    if (!mounted || token != _searchToken) return;

    setState(() {
      // History cleared mid-search: keep the search, drop the stale chips.
      if (historyToken == _historyToken) _searchHistory = history;
    });

    try {
      final results = await BilibiliSdk.search(trimmed);
      if (mounted && token == _searchToken) {
        for (final t in results) {
          _seenSearchIds.add(t.id);
        }
        setState(() {
          _searchResults = results;
          _isLoading = false;
          // This search is new evidence about taste; fold it in next time the
          // recommendation view is shown.
          _recommendationsStale = true;
          if (results.isEmpty) _searchReachedEnd = true;
        });
      }
    } catch (e) {
      debugPrint('Search error: $e');
      // Without this the skeleton spinner would stay up forever.
      if (mounted && token == _searchToken) {
        setState(() {
          _isLoading = false;
          _searchLoadFailed = true;
          _lastSearchFail = DateTime.now();
        });
      }
    }
  }

  // --------------------------------------------------------------------------
  // Infinite scroll + pull-to-refresh. Both append the *next* batch of tracks;
  // a refresh never re-serves an earlier batch (seen ids are excluded).
  // --------------------------------------------------------------------------

  void _onScroll() {
    final pos = _scrollController.position;
    // Content that fits on screen has nothing to scroll towards — leave that
    // case to pull-to-refresh instead of auto-paging on every overscroll.
    if (pos.maxScrollExtent <= 0) return;
    if (pos.pixels >= pos.maxScrollExtent - 240) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || _isLoading || _isLoadingRecommended) return;
    if (_hasSearched) {
      if (!_searchReachedEnd) {
        if (_searchLoadFailed &&
            DateTime.now().difference(_lastSearchFail).inSeconds < 3) {
          return;
        }
        await _loadMoreSearch();
      }
    } else if (_canRecommend) {
      if (!_recReachedEnd) {
        if (_recLoadFailed &&
            DateTime.now().difference(_lastRecFail).inSeconds < 3) {
          return;
        }
        await _loadMoreRecommendations();
      }
    }
  }

  /// Releases pagination loading only for the operation that still owns it.
  void _releaseLoadMore(Object owner) {
    if (mounted && identical(_loadMoreOwner, owner)) {
      setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _loadMoreSearch() async {
    if (_lastQuery.isEmpty || _isLoadingMore) return;
    // A new search may have started while this fetch is in flight; only a
    // batch that still belongs to the current query may be appended, and
    // only the owning fetch may release the loading flag.
    final token = _searchToken;
    final owner = Object();
    _loadMoreOwner = owner;
    setState(() => _isLoadingMore = true);
    final page = _searchPage + 1;
    try {
      final results = await BilibiliSdk.search(_lastQuery, page: page);
      if (!mounted ||
          token != _searchToken ||
          !identical(_loadMoreOwner, owner)) {
        return;
      }
      final fresh = <Track>[];
      for (final t in results) {
        if (_seenSearchIds.add(t.id)) fresh.add(t);
      }
      setState(() {
        _searchResults = [..._searchResults, ...fresh];
        _searchPage = page;
        _isLoadingMore = false;
        _searchLoadFailed = false;
        // The source returning nothing proves the end; a page of only
        // duplicates does not (filtering can discard a whole batch).
        if (results.isEmpty) _searchReachedEnd = true;
      });
    } catch (e) {
      debugPrint('Load more search error: $e');
      if (mounted &&
          token == _searchToken &&
          identical(_loadMoreOwner, owner)) {
        setState(() {
          _isLoadingMore = false;
          _searchLoadFailed = true;
          _lastSearchFail = DateTime.now();
        });
      }
    } finally {
      _releaseLoadMore(owner);
    }
  }

  Future<void> _loadMoreRecommendations() async {
    if (_isLoadingMore) return;
    // A fresh recommendation pass resets the seen-set and page while this is
    // in flight; a stale batch must not be appended to the new list, nor
    // release a newer operation's loading flag.
    final pass = _recPass;
    final owner = Object();
    _loadMoreOwner = owner;
    setState(() => _isLoadingMore = true);
    final page = _recPage + 1;
    List<Track> tracks;
    try {
      // Snapshot the seen-set: the engine reads it during the await, and a
      // fresh pass may clear it while this fetch is still running.
      tracks = await RecommendationEngine.recommend(
          page: page, excludeIds: Set.of(_seenRecIds));
    } catch (e) {
      debugPrint('Load more recommendations error: $e');
      if (mounted && pass == _recPass && identical(_loadMoreOwner, owner)) {
        setState(() {
          _isLoadingMore = false;
          _recLoadFailed = true;
          _lastRecFail = DateTime.now();
        });
      }
      return;
    }
    if (!mounted || pass != _recPass || !identical(_loadMoreOwner, owner)) {
      _releaseLoadMore(owner);
      return;
    }
    final fresh = <Track>[];
    for (final t in tracks) {
      if (_seenRecIds.add(t.id)) fresh.add(t);
    }
    setState(() {
      _recommendedTracks = [..._recommendedTracks, ...fresh];
      _recPage = page;
      _isLoadingMore = false;
      _recLoadFailed = false;
      if (tracks.isEmpty) _recReachedEnd = true;
    });
  }

  /// Bottom-of-list feedback: a spinner while the next batch loads, or a quiet
  /// "没有更多了" once a fetch came back with nothing new.
  Widget _loadMoreFooter() {
    final reachedEnd = _hasSearched ? _searchReachedEnd : _recReachedEnd;
    final hasContent = _hasSearched
        ? _searchResults.isNotEmpty
        : _recommendedTracks.isNotEmpty;
    if (_isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: AppColors.accent),
          ),
        ),
      );
    }
    if (reachedEnd && hasContent) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: Text('没有更多了',
              style: TextStyle(color: AppColors.textFaint, fontSize: 12)),
        ),
      );
    }
    if (hasContent) {
      final loadFailed = _hasSearched ? _searchLoadFailed : _recLoadFailed;
      if (loadFailed) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 22),
          child: Center(
            child: Text('加载失败，上滑重试',
                style: TextStyle(color: AppColors.textFaint, fontSize: 12)),
          ),
        );
      }
    }
    return const SizedBox.shrink();
  }

  /// Result rows that should be built lazily rather than all at once.
  List<Track> get _visibleTracks {
    if (_isLoading) return const [];
    if (_hasSearched) return _searchResults;
    if (!_canRecommend || _isLoadingRecommended) return const [];
    return _recommendedTracks;
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: _scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(left: 20, right: 20, top: 20),
          sliver: SliverList(delegate: SliverChildListDelegate(_header())),
        ),
        // Rows are built on demand so a long result list costs only what is
        // actually on screen.
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList.builder(
            itemCount: _visibleTracks.length,
            itemBuilder: (context, index) =>
                _buildTrackTile(_visibleTracks[index], index),
          ),
        ),
        SliverToBoxAdapter(child: _loadMoreFooter()),
        const SliverToBoxAdapter(
          child: SizedBox(height: 24),
        ),
      ],
    );
  }

  List<Widget> _header() {
    return [
      // No "搜索" heading: the tab bar above already says which page this is,
      // and printing the same word twice, one line apart, was pure noise.
      // Search Input Bar with Focus Listener
      GlassCard(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              const Icon(
                Icons.search_rounded,
                color: AppColors.textMuted,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  focusNode: _focusNode,
                  textInputAction: TextInputAction.search,
                  autocorrect: false,
                  style: AppTypography.body,
                  cursorColor: AppColors.accent,
                  onSubmitted: _performSearch,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '歌曲、UP 主或 BV 链接',
                    hintStyle: AppTypography.body.copyWith(
                      color: AppColors.textFaint,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 16),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
              SizedBox(
                width: 48,
                height: 48,
                child: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: _showRecommendations,
                        tooltip: '清除搜索',
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 20,
                          color: AppColors.textMuted,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),

      // Show Search History ONLY when Search Bar is Focused / Tapped!
      if (_focusNode.hasFocus) ...[
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '历史搜索',
              style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.bold),
            ),
            if (_searchHistory.isNotEmpty)
              InkWell(
                onTap: _clearSearchHistory,
                borderRadius: BorderRadius.circular(4),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Text('清空历史',
                      style:
                          TextStyle(color: AppColors.textFaint, fontSize: 12)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _searchHistory.map((tag) {
            return ActionChip(
              label: Text(tag,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
              backgroundColor: AppColors.white10,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              onPressed: () {
                _searchController.text = tag;
                _performSearch(tag);
              },
            );
          }).toList(),
        ),
      ],

      const SizedBox(height: 24),

      // Loading Indicator
      if (_isLoading)
        const Column(
          children: [
            SkeletonTrackTile(),
            SkeletonTrackTile(),
            SkeletonTrackTile(),
            SkeletonTrackTile(),
            SkeletonTrackTile(),
          ],
        )
      // Active Search Results List
      else if (_hasSearched && _searchResults.isNotEmpty) ...[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${_searchResults.length} 个结果',
              style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.bold),
            ),
            TextButton(
              onPressed: _showRecommendations,
              child: const Text('清空搜索',
                  style: TextStyle(color: AppColors.textFaint, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ]
      // Search failed: transport/API error, not an empty result. The query
      // is kept so retry is one tap.
      else if (_hasSearched && _searchResults.isEmpty && _searchLoadFailed) ...[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Column(
            children: [
              const Icon(Icons.wifi_off_rounded,
                  size: 48, color: AppColors.textMuted),
              const SizedBox(height: 12),
              const Text(
                '暂时无法加载结果',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text(
                '请稍后重试，你的搜索内容已保留',
                style: TextStyle(color: AppColors.textFaint, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => _performSearch(_lastQuery),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  side: const BorderSide(color: AppColors.accent30),
                ),
              ),
            ],
          ),
        ),
      ]
      // Search Completed but No Results Found
      else if (_hasSearched && _searchResults.isEmpty) ...[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Column(
            children: [
              const Icon(Icons.search_off_rounded,
                  size: 48, color: AppColors.textMuted),
              const SizedBox(height: 12),
              Text(
                '未找到「$_lastQuery」',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 14),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text(
                '试试 BV 号，或更简短的关键词',
                style: TextStyle(color: AppColors.textFaint, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => _performSearch(_lastQuery),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accent,
                  side: const BorderSide(color: AppColors.accent30),
                ),
              ),
            ],
          ),
        ),
      ]
      // Default view: recommendations, once there is a search to learn from.
      else if (!_canRecommend) ...[
        const EmptyState(
          icon: Icons.search_rounded,
          title: '先搜索一首歌吧',
          subtitle: '搜过之后，这里会根据你的收藏与播放推荐',
        ),
      ] else ...[
        const Row(
          children: [
            Icon(Icons.auto_awesome, color: AppColors.accent, size: 20),
            SizedBox(width: 8),
            Text(
              '推荐',
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_isLoadingRecommended)
          const Column(
            children: [
              SkeletonTrackTile(),
              SkeletonTrackTile(),
              SkeletonTrackTile(),
            ],
          )
        else if (_recommendedTracks.isEmpty && _recLoadFailed)
          Center(
            child: OutlinedButton.icon(
              onPressed: _loadRecommendations,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新加载推荐'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: const BorderSide(color: AppColors.accent30),
              ),
            ),
          ),
      ],
    ];
  }

  Widget _buildTrackTile(Track track, int index) {
    return Padding(
      padding: const EdgeInsets.only(bottom: TrackRow.gap),
      child: TrackRow(
        // Tapping the row: plays AND opens the full player.
        onTap: () => widget.onSelectTrack(track),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedCoverImage(
                url: track.coverUrl,
                width: 54,
                height: 54,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Bilibili titles are routinely far wider than a row.
                  // The marquee is affordable here because it only
                  // animates when the text actually overflows, and the
                  // RepaintBoundary keeps each ticking title from
                  // repainting the rest of the row.
                  RepaintBoundary(
                    child: MarqueeText(
                      text: track.title,
                      style: AppTypography.body.copyWith(
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                      // Desynchronise rows so a screenful of titles does
                      // not slide in lockstep.
                      phase: (index % 5) / 5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${track.uploader} • ${formatDuration(Duration(seconds: track.duration))}',
                    style: AppTypography.caption.copyWith(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),

            // Nudged right: the gap that was missing between the title
            // and the download control comes out of the padding after the
            // last button, so the title keeps exactly the width it had.
            const SizedBox(width: 8),
            TrackDownloadButton(
              track: track,
              size: 24,
              onPlay: () {
                if (widget.onPlayOnly != null) {
                  widget.onPlayOnly!(track);
                } else {
                  widget.onSelectTrack(track);
                }
              },
            ),

            // Overflow menu: favorite / add-to-playlist live here.
            // Download stays directly available.
            IconButton(
              tooltip: '更多选项',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 48,
                minHeight: 48,
              ),
              icon: const Icon(
                Icons.more_horiz_rounded,
                color: AppColors.textMuted,
                size: 24,
              ),
              onPressed: () {
                TrackOptionsMenu.show(
                  context,
                  track,
                  onTrackChanged: () {
                    if (mounted) setState(() {});
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
