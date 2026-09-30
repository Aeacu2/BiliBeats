import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/download_tab.dart';
import '../screens/listen_tab.dart';
import '../screens/now_playing_page.dart';
import '../screens/search_results_view.dart';
import '../screens/settings_sheet.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../utils/snack.dart';
import '../widgets/mini_player.dart';
import '../widgets/segment_tabs.dart';
import 'app_services.dart';

/// Adapts a [PageController] into the [Animation] [SegmentTabs] follows, so
/// the tab underline tracks a swipe between pages.
class _PageFraction extends Animation<double> with ChangeNotifier {
  _PageFraction(this._controller) {
    _controller.addListener(notifyListeners);
  }

  final PageController _controller;
  int fallback = 0;

  @override
  void dispose() {
    _controller.removeListener(notifyListeners);
    super.dispose();
  }

  @override
  double get value {
    if (!_controller.hasClients) return fallback.toDouble();
    return (_controller.page ?? fallback.toDouble()).clamp(0.0, 1.0);
  }

  @override
  AnimationStatus get status => AnimationStatus.forward;

  @override
  void addStatusListener(AnimationStatusListener listener) {}

  @override
  void removeStatusListener(AnimationStatusListener listener) {}
}

/// The app's frame.
///
/// ```
///   聆听  下载                          ⚙
///   [ 搜索 …                           ]   ← fixed; never moves
///   ─────────────────────────────────────
///   tab page, or search results
///   ─────────────────────────────────────
///   [ mini player ]
/// ```
///
/// One search bar serves both tabs. Results always include both sources;
/// the tab only decides which comes first — your downloaded songs on 聆听,
/// Bilibili on 下载.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final AppServices _services = AppServices.instance;

  late final PageController _pages = PageController();
  late final _PageFraction _pageFraction = _PageFraction(_pages);
  final ValueNotifier<int> _tab = ValueNotifier(0);

  final TextEditingController _searchText = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ValueNotifier<String> _query = ValueNotifier('');
  bool _searchActive = false;

  final GlobalKey _miniPlayerKey = GlobalKey();
  StreamSubscription<String>? _messagesSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchFocus.addListener(_syncSearchActive);
    _searchText.addListener(_onSearchTextChanged);
    _messagesSub = _services.handler.messages.listen(_showMessage);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messagesSub?.cancel();
    _searchFocus.removeListener(_syncSearchActive);
    _searchText.removeListener(_onSearchTextChanged);
    _searchFocus.dispose();
    _searchText.dispose();
    _query.dispose();
    _tab.dispose();
    _pageFraction.dispose();
    _pages.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist the position before the system may reclaim the process.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_services.handler.saveSession());
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    showAppSnackBar(
      ScaffoldMessenger.of(context),
      message: message,
      backgroundColor: AppColors.backgroundElevated,
      duration: const Duration(seconds: 3),
    );
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  void _onSearchTextChanged() {
    final text = _searchText.text;
    if (text == _query.value) return;
    _query.value = text;
    if (text.trim().isEmpty) _services.onlineSearch.clear();
    _syncSearchActive();
  }

  void _syncSearchActive() {
    final active = _searchFocus.hasFocus || _searchText.text.isNotEmpty;
    if (active != _searchActive) setState(() => _searchActive = active);
  }

  Future<void> _submitOnline(String text) async {
    final query = text.trim();
    if (query.isEmpty) return;
    if (_searchText.text != text) _searchText.text = text;
    _searchFocus.unfocus();
    await _services.onlineSearch.search(query);
    // A first search gives the recommender something to learn from.
    final recommendations = _services.recommendations;
    if (recommendations.tracks.isEmpty && !recommendations.loading) {
      unawaited(recommendations.refresh());
    }
  }

  void _exitSearch() {
    _searchText.clear();
    _searchFocus.unfocus();
    _services.onlineSearch.clear();
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _selectTab(int index) {
    if (_tab.value == index) return;
    _tab.value = index;
    _pageFraction.fallback = index;
    final media = MediaQuery.of(context);
    if (media.disableAnimations || media.accessibleNavigation) {
      _pages.jumpToPage(index);
    } else {
      _pages.animateToPage(
        index,
        duration: AppMotion.fast,
        curve: AppMotion.standard,
      );
    }
  }

  Rect? _miniPlayerRect() {
    final box = _miniPlayerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _openPlayer() {
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(NowPlayingPage.open(context, from: _miniPlayerRect()));
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    final dockHeight = keyboardOpen ? 0.0 : MiniPlayer.totalHeight(context);

    return PopScope(
      canPop: !_searchActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searchActive) _exitSearch();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            Column(
              children: [
                SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      _header(),
                      _searchBar(),
                    ],
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      PageView(
                        controller: _pages,
                        onPageChanged: (index) {
                          _tab.value = index;
                          _pageFraction.fallback = index;
                        },
                        children: const [
                          RepaintBoundary(child: ListenTab()),
                          RepaintBoundary(child: DownloadTab()),
                        ],
                      ),
                      if (_searchActive)
                        Positioned.fill(
                          child: ColoredBox(
                            color: AppColors.background,
                            child: SearchResultsView(
                              query: _query,
                              tab: _tab,
                              onSearchOnline: _submitOnline,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: dockHeight),
              ],
            ),
            if (!keyboardOpen)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: KeyedSubtree(
                  key: _miniPlayerKey,
                  child: MiniPlayer(
                    handler: _services.handler,
                    onTap: _openPlayer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
      child: Row(
        children: [
          // Bounded width: SegmentTabs lays its labels out as Flexibles.
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: SegmentTabs(
                labels: const ['聆听', '下载'],
                animation: _pageFraction,
                onTap: _selectTab,
                fontSize: 26,
              ),
            ),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () => SettingsSheet.show(context),
            icon: const Icon(Icons.settings_outlined,
                color: AppColors.textMuted, size: 24),
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.fieldFill,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  const Icon(Icons.search_rounded,
                      color: AppColors.textMuted, size: 21),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ValueListenableBuilder<int>(
                      valueListenable: _tab,
                      builder: (context, tab, _) => TextField(
                        controller: _searchText,
                        focusNode: _searchFocus,
                        textInputAction: TextInputAction.search,
                        autocorrect: false,
                        style: AppTypography.body,
                        onSubmitted: _submitOnline,
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText:
                              tab == 0 ? '搜索我的音乐与哔哩哔哩' : '搜索哔哩哔哩、BV 号或链接',
                          hintStyle: AppTypography.body.copyWith(
                            color: AppColors.textFaint,
                          ),
                        ),
                      ),
                    ),
                  ),
                  ValueListenableBuilder<String>(
                    valueListenable: _query,
                    builder: (context, query, _) => query.isEmpty
                        ? const SizedBox(width: 8)
                        : IconButton(
                            tooltip: '清除',
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              _searchText.clear();
                              _searchFocus.requestFocus();
                            },
                            icon: const Icon(Icons.cancel_rounded,
                                color: AppColors.textFaint, size: 18),
                          ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            child: _searchActive
                ? TextButton(
                    onPressed: _exitSearch,
                    child: const Text('取消',
                        style: TextStyle(color: AppColors.textPrimary)),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
