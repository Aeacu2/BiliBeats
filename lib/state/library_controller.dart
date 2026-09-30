import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/playlist.dart';
import '../models/track.dart';
import '../services/database_service.dart';
import '../services/download_manager.dart';

/// How the song list on 聆听 is ordered.
enum LibrarySort { recent, title, artist }

/// One in-memory view of the library for every screen.
///
/// Screens used to each load their own copy from [DatabaseService] and
/// subscribe to its update streams separately, so two views of the same
/// data could disagree for a moment. They now all read this, which reloads
/// once per change and notifies once.
class LibraryController extends ChangeNotifier {
  LibraryController._() {
    _subs.add(DatabaseService.libraryUpdateStream.listen((_) => reload()));
    _subs.add(DatabaseService.historyUpdateStream.listen((_) => _loadRecent()));
    _subs.add(DownloadManager.instance.updates.listen((_) => _onDownloads()));
    unawaited(reload());
    unawaited(_loadSort());
  }

  static final LibraryController instance = LibraryController._();

  final List<StreamSubscription<void>> _subs = [];

  List<Track> _downloaded = const [];
  Set<String> _downloadedIds = const {};
  List<Playlist> _playlists = const [];
  List<Track> _recent = const [];
  List<DownloadTask> _active = const [];
  int _failedCount = 0;
  bool _loaded = false;
  LibrarySort _sort = LibrarySort.recent;

  /// Downloaded tracks, most recently downloaded first.
  List<Track> get downloaded => _downloaded;
  bool isDownloaded(String id) => _downloadedIds.contains(id);

  List<Playlist> get playlists => _playlists;
  List<Track> get recent => _recent;
  List<DownloadTask> get activeDownloads => _active;
  int get failedDownloadCount => _failedCount;
  bool get loaded => _loaded;
  LibrarySort get sort => _sort;

  Playlist? get favorites {
    for (final playlist in _playlists) {
      if (playlist.id == Playlist.favoritesId) return playlist;
    }
    return null;
  }

  bool isFavorite(String id) =>
      favorites?.tracks.any((t) => t.id == id) ?? false;

  /// User playlists (everything except 收藏).
  List<Playlist> get userPlaylists =>
      [for (final p in _playlists) if (p.id != Playlist.favoritesId) p];

  /// The subset of [tracks] that can play right now, in order.
  List<Track> playableOf(List<Track> tracks) =>
      [for (final t in tracks) if (_downloadedIds.contains(t.id)) t];

  List<Track>? _sortedCache;
  List<Track>? _sortedSource;
  LibrarySort? _sortedBy;

  /// [downloaded] in the chosen [sort] order (cached until either changes).
  List<Track> get sortedDownloaded {
    final cached = _sortedCache;
    if (cached != null &&
        identical(_sortedSource, _downloaded) &&
        _sortedBy == _sort) {
      return cached;
    }
    int byTitle(Track a, Track b) =>
        a.title.toLowerCase().compareTo(b.title.toLowerCase());
    final sorted = switch (_sort) {
      LibrarySort.recent => _downloaded,
      LibrarySort.title => List.of(_downloaded)..sort(byTitle),
      LibrarySort.artist => List.of(_downloaded)
        ..sort((a, b) {
          final byArtist =
              a.uploader.toLowerCase().compareTo(b.uploader.toLowerCase());
          return byArtist != 0 ? byArtist : byTitle(a, b);
        }),
    };
    _sortedSource = _downloaded;
    _sortedBy = _sort;
    return _sortedCache = List.unmodifiable(sorted);
  }

  Future<void> setSort(LibrarySort sort) async {
    if (sort == _sort) return;
    _sort = sort;
    notifyListeners();
    await DatabaseService.setPref('librarySort', sort.name);
  }

  Future<void> _loadSort() async {
    final saved = await DatabaseService.getPref('librarySort');
    final match = LibrarySort.values.where((s) => s.name == saved);
    if (match.isNotEmpty && match.first != _sort) {
      _sort = match.first;
      notifyListeners();
    }
  }

  Future<void> reload() async {
    final results = await Future.wait([
      DatabaseService.getDownloadedTracks(),
      DatabaseService.getPlaylists(),
      DatabaseService.getRecentlyPlayed(),
    ]);
    _downloaded = List.unmodifiable(results[0] as List<Track>);
    _downloadedIds = {for (final t in _downloaded) t.id};
    _playlists = List.unmodifiable(results[1] as List<Playlist>);
    _recent = List.unmodifiable(results[2] as List<Track>);
    _active = DownloadManager.instance.activeTasks;
    _failedCount = DownloadManager.instance.failedTasks.length;
    _loaded = true;
    notifyListeners();
  }

  Future<void> _loadRecent() async {
    _recent = List.unmodifiable(await DatabaseService.getRecentlyPlayed());
    notifyListeners();
  }

  /// Progress ticks arrive every 64 KiB; only membership changes matter here
  /// (rows draw their own rings).
  void _onDownloads() {
    final active = DownloadManager.instance.activeTasks;
    final failed = DownloadManager.instance.failedTasks.length;
    final sameIds = setEquals(
      {for (final t in active) t.track.id},
      {for (final t in _active) t.track.id},
    );
    if (sameIds && failed == _failedCount) return;
    _active = active;
    _failedCount = failed;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }
}
