import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/home_page.dart';
import '../screens/search_view.dart';
import '../screens/settings_sheet.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../utils/snack.dart';
import '../widgets/docked_player.dart';
import '../widgets/download_management_sheet.dart';
import 'app_services.dart';

/// The app's frame.
///
/// ```
///   [ 搜索 …                    ]  ⚙      ← fixed; never moves
///   ─────────────────────────────────
///   your music, or search
///   ─────────────────────────────────
///   [ mini player ]
/// ```
///
/// One page. The search bar is the way to everything that is not yet yours:
/// focus it for recommendations, type to filter your library, submit to
/// search Bilibili.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final AppServices _services = AppServices.instance;

  final TextEditingController _searchText = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ValueNotifier<String> _query = ValueNotifier('');
  bool _searchActive = false;

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

  /// Search stays open once entered — scrolling results drops the keyboard
  /// (and focus) without throwing you back home. 取消 or Back leaves.
  void _syncSearchActive() {
    if (_searchActive || !_searchFocus.hasFocus) return;
    setState(() => _searchActive = true);
  }

  Future<void> _submitOnline(String text) async {
    final query = text.trim();
    if (query.isEmpty) return;
    if (_searchText.text != text) _searchText.text = text;
    _searchFocus.unfocus();
    await _services.onlineSearch.search(query);
  }

  void _exitSearch() {
    _searchText.clear();
    _searchFocus.unfocus();
    _services.onlineSearch.clear();
    setState(() => _searchActive = false);
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

    return PopScope(
      canPop: !_searchActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searchActive) _exitSearch();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Column(
          children: [
            SafeArea(bottom: false, child: _searchBar()),
            Expanded(
              child: AnimatedSwitcher(
                duration: AppMotion.fast,
                switchInCurve: AppMotion.standard,
                switchOutCurve: AppMotion.standardReverse,
                child: _searchActive
                    ? SearchView(
                        key: const ValueKey('search'),
                        query: _query,
                        onSearchOnline: _submitOnline,
                      )
                    : HomePage(
                        key: const ValueKey('home'),
                        onSearch: _searchFocus.requestFocus,
                      ),
              ),
            ),
            if (!keyboardOpen) const DockedPlayer(),
          ],
        ),
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.fieldFill,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 14),
                  const Icon(Icons.search_rounded,
                      color: AppColors.textMuted, size: 21),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchText,
                      focusNode: _searchFocus,
                      textInputAction: TextInputAction.search,
                      autocorrect: false,
                      style: AppTypography.body,
                      onSubmitted: _submitOnline,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '搜索',
                        hintStyle: AppTypography.body.copyWith(
                          color: AppColors.textFaint,
                        ),
                      ),
                    ),
                  ),
                  ValueListenableBuilder<String>(
                    valueListenable: _query,
                    builder: (context, query, _) => query.isEmpty
                        ? const SizedBox(width: 12)
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
          if (_searchActive)
            TextButton(
              onPressed: _exitSearch,
              child: const Text('取消',
                  style: TextStyle(color: AppColors.textPrimary)),
            )
          else ...[
            const _DownloadsButton(),
            IconButton(
              tooltip: '设置',
              onPressed: () => SettingsSheet.show(context),
              icon: const Icon(Icons.settings_outlined,
                  color: AppColors.textMuted, size: 23),
            ),
          ],
        ],
      ),
    );
  }
}

/// Appears only while something is downloading or has failed: a ring with
/// the number in flight, or a warning to tap.
class _DownloadsButton extends StatelessWidget {
  const _DownloadsButton();

  @override
  Widget build(BuildContext context) {
    final library = AppServices.instance.library;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final active = library.activeDownloads.length;
        final failed = library.failedDownloadCount;
        if (active == 0 && failed == 0) return const SizedBox(width: 4);
        return IconButton(
          tooltip: '下载',
          onPressed: () => DownloadManagementSheet.show(context),
          icon: active > 0
              ? SizedBox(
                  width: 24,
                  height: 24,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      Text(
                        '$active',
                        style: AppTypography.caption.copyWith(
                          fontSize: 11,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                )
              : const Icon(Icons.error_outline_rounded,
                  color: AppColors.danger, size: 23),
        );
      },
    );
  }
}
