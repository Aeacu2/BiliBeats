import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import '../services/recommendation_engine.dart';

/// "为你推荐" on the 下载 tab: Bilibili tracks picked from the listener's
/// favorites, history and searches, paged for infinite scroll.
class RecommendationsController extends ChangeNotifier {
  List<Track> _tracks = const [];
  bool _loading = false;
  bool _loaded = false;
  bool _failed = false;
  bool _loadingMore = false;
  bool _reachedEnd = false;
  int _page = 1;
  int _pass = 0;
  final Set<String> _seen = {};

  List<Track> get tracks => _tracks;
  bool get loading => _loading;

  /// True once a pass has completed (even with nothing to recommend).
  bool get loaded => _loaded;
  bool get failed => _failed;
  bool get loadingMore => _loadingMore;
  bool get reachedEnd => _reachedEnd;

  /// Loads the first page if nothing has been loaded yet.
  void ensureLoaded() {
    if (!_loaded && !_loading) unawaited(refresh());
  }

  Future<void> refresh() async {
    final pass = ++_pass;
    _loading = true;
    _failed = false;
    _loadingMore = false;
    notifyListeners();

    try {
      final tracks = await RecommendationEngine.recommend();
      if (pass != _pass) return;
      _seen
        ..clear()
        ..addAll(tracks.map((t) => t.id));
      _tracks = tracks;
      _page = 1;
      _reachedEnd = tracks.isEmpty;
    } catch (e) {
      debugPrint('Recommendations error: $e');
      if (pass != _pass) return;
      _failed = true;
    }
    _loading = false;
    _loaded = true;
    notifyListeners();
  }

  Future<void> loadMore() async {
    if (_loading || _loadingMore || _reachedEnd || _tracks.isEmpty) return;
    final pass = _pass;
    final page = _page + 1;
    _loadingMore = true;
    notifyListeners();

    try {
      final tracks = await RecommendationEngine.recommend(
        page: page,
        excludeIds: Set.of(_seen),
      );
      if (pass != _pass) return;
      _tracks = [
        ..._tracks,
        for (final t in tracks)
          if (_seen.add(t.id)) t,
      ];
      _page = page;
      if (tracks.isEmpty) _reachedEnd = true;
    } catch (e) {
      debugPrint('Load more recommendations error: $e');
      if (pass != _pass) return;
    }
    _loadingMore = false;
    notifyListeners();
  }
}
