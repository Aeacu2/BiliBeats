import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import '../services/recommendation_engine.dart';

/// "为你推荐" in search: Bilibili tracks picked from the listener's
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
  DateTime? _lastFailure;

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

  /// Loads a batch. 换一批 passes [another] to get songs other than the
  /// ones on screen: the next page of the same searches, starting over
  /// when those run out.
  Future<void> refresh({bool another = false}) async {
    final pass = ++_pass;
    final shown = another ? _tracks.map((t) => t.id).toSet() : const <String>{};
    var page = another && _tracks.isNotEmpty ? _page + 1 : 1;
    _loading = true;
    _failed = false;
    _loadingMore = false;
    notifyListeners();

    try {
      var tracks = await RecommendationEngine.recommend(
        page: page,
        excludeIds: shown,
      );
      if (tracks.isEmpty && page > 1) {
        page = 1;
        tracks = await RecommendationEngine.recommend();
      }
      if (pass != _pass) return;
      _seen
        ..clear()
        ..addAll(tracks.map((t) => t.id));
      _tracks = tracks;
      _page = page;
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
    // A failed page gets a quiet window instead of re-firing every seed
    // search on each scroll notification.
    final failedAt = _lastFailure;
    if (failedAt != null &&
        DateTime.now().difference(failedAt).abs() <
            const Duration(seconds: 3)) {
      return;
    }
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
      _lastFailure = null;
      if (tracks.isEmpty) _reachedEnd = true;
    } catch (e) {
      debugPrint('Load more recommendations error: $e');
      if (pass != _pass) return;
      _lastFailure = DateTime.now();
    }
    _loadingMore = false;
    notifyListeners();
  }
}
