import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import '../services/bilibili_sdk.dart';
import '../services/database_service.dart';

/// Bilibili search results with pagination and search history.
///
/// Every request carries a token; a slow, older request can never write
/// into a newer query's results or loading state.
class OnlineSearchController extends ChangeNotifier {
  OnlineSearchController() {
    unawaited(_loadHistory());
  }

  List<Track> _results = const [];
  List<String> _history = const [];
  String _query = '';
  bool _loading = false;
  bool _failed = false;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;
  bool _reachedEnd = false;
  int _page = 1;
  int _token = 0;
  int _historyToken = 0;
  DateTime _lastFailure = DateTime.fromMillisecondsSinceEpoch(0);
  final Set<String> _seen = {};

  /// The query the current results belong to ('' before any search).
  String get query => _query;
  List<Track> get results => _results;
  List<String> get history => _history;
  bool get hasSearched => _query.isNotEmpty;
  bool get loading => _loading;
  bool get failed => _failed;
  bool get loadingMore => _loadingMore;
  bool get loadMoreFailed => _loadMoreFailed;
  bool get reachedEnd => _reachedEnd;

  Future<void> _loadHistory() async {
    final token = _historyToken;
    final history = await DatabaseService.getSearchHistory();
    if (token != _historyToken) return;
    _history = history;
    notifyListeners();
  }

  Future<void> search(String raw) async {
    final query = raw.trim();
    if (query.isEmpty) return;

    final token = ++_token;
    _query = query;
    _results = const [];
    _seen.clear();
    _page = 1;
    _loading = true;
    _failed = false;
    _loadingMore = false;
    _loadMoreFailed = false;
    _reachedEnd = false;
    notifyListeners();

    final historyToken = _historyToken;
    try {
      final history = await DatabaseService.addSearchHistory(query);
      if (historyToken == _historyToken) _history = history;
    } catch (e) {
      debugPrint('Search history write failed: $e');
    }

    try {
      final results = await BilibiliSdk.search(query);
      if (token != _token) return;
      _results = [
        for (final t in results)
          if (_seen.add(t.id)) t,
      ];
      _reachedEnd = results.isEmpty;
    } catch (e) {
      debugPrint('Search error: $e');
      if (token != _token) return;
      _failed = true;
    }
    _loading = false;
    notifyListeners();
  }

  Future<void> retry() => search(_query);

  Future<void> loadMore() async {
    if (_query.isEmpty || _loading || _loadingMore || _reachedEnd) return;
    // A failed page gets a quiet retry window instead of re-firing on every
    // scroll pixel.
    if (_loadMoreFailed &&
        DateTime.now().difference(_lastFailure) < const Duration(seconds: 3)) {
      return;
    }

    final token = _token;
    final page = _page + 1;
    _loadingMore = true;
    notifyListeners();

    try {
      final results = await BilibiliSdk.search(_query, page: page);
      if (token != _token) return;
      _results = [
        ..._results,
        for (final t in results)
          if (_seen.add(t.id)) t,
      ];
      _page = page;
      _loadMoreFailed = false;
      // Only an empty page proves the end; a page of duplicates does not.
      if (results.isEmpty) _reachedEnd = true;
    } catch (e) {
      debugPrint('Load more search error: $e');
      if (token != _token) return;
      _loadMoreFailed = true;
      _lastFailure = DateTime.now();
    }
    _loadingMore = false;
    notifyListeners();
  }

  /// Forgets the current results (the field was cleared).
  void clear() {
    ++_token;
    _query = '';
    _results = const [];
    _seen.clear();
    _loading = false;
    _failed = false;
    _loadingMore = false;
    _loadMoreFailed = false;
    _reachedEnd = false;
    notifyListeners();
  }

  Future<void> clearHistory() async {
    ++_historyToken;
    _history = const [];
    notifyListeners();
    await DatabaseService.clearSearchHistory();
  }
}
