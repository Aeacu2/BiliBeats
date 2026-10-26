import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/play_stat.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../services/database_service.dart';
import '../services/download_manager.dart';
import '../services/lyrics_engine.dart';
import '../services/track_credit.dart';
import '../services/track_naming.dart';
import '../services/prefs.dart';
import '../services/accompaniment.dart';

/// How the song list is ordered.
enum LibrarySort { recent, played, mostPlayed, forgotten, title, artist }

/// Downloaded songs that share an artist — a collection nobody has to build.
@immutable
class ArtistGroup {
  final String name;
  final List<Track> tracks;

  const ArtistGroup(this.name, this.tracks);

  /// Artwork standing in for a portrait: the newest song's cover.
  String get coverUrl => tracks.isEmpty ? '' : tracks.first.coverUrl;
}

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
  Map<String, PlayStat> _plays = const {};
  List<DownloadTask> _active = const [];
  int _failedCount = 0;
  bool _loaded = false;
  LibrarySort _sort = LibrarySort.recent;

  /// Downloaded tracks, most recently downloaded first.
  List<Track> get downloaded => _downloaded;
  bool isDownloaded(String id) => _downloadedIds.contains(id);

  List<Playlist> get playlists => _playlists;
  List<Track> get recent => _recent;

  /// How often [id] has been listened to; null if never (counted).
  PlayStat? playsOf(String id) => _plays[id];
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
  List<Playlist> get userPlaylists => [
        for (final p in _playlists)
          if (p.id != Playlist.favoritesId) p
      ];

  /// The subset of [tracks] that can play right now, in order.
  List<Track> playableOf(List<Track> tracks) => [
        for (final t in tracks)
          if (_downloadedIds.contains(t.id)) t
      ];

  List<Track>? _sortedCache;
  List<Track>? _sortedRecent;
  Map<String, PlayStat>? _sortedPlays;

  /// Played songs first, the latest on top; the rest as downloaded.
  List<Track> _byLastPlayed() {
    final rank = <String, int>{
      for (var i = 0; i < _recent.length; i++) _recent[i].id: i,
    };
    final played = [
      for (final t in _downloaded)
        if (rank.containsKey(t.id)) t,
    ]..sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!));
    return [
      ...played,
      for (final t in _downloaded)
        if (!rank.containsKey(t.id)) t,
    ];
  }

  /// Most listened to first; songs heard equally often, latest first.
  List<Track> _byPlayCount() {
    final byLast = _byLastPlayed();
    final order = {for (var i = 0; i < byLast.length; i++) byLast[i].id: i};
    return byLast
      ..sort((a, b) {
        final byCount =
            (_plays[b.id]?.count ?? 0).compareTo(_plays[a.id]?.count ?? 0);
        return byCount != 0 ? byCount : order[a.id]!.compareTo(order[b.id]!);
      });
  }

  List<Track>? _sortedSource;
  LibrarySort? _sortedBy;

  /// [downloaded] in the chosen [sort] order (cached until either changes).
  /// Every song played replaces [recent] and the play counts; only the
  /// orders that read them are worked out again for it.
  List<Track> get sortedDownloaded {
    final cached = _sortedCache;
    final byListening = switch (_sort) {
      LibrarySort.recent || LibrarySort.title || LibrarySort.artist => false,
      _ => true,
    };
    if (cached != null &&
        identical(_sortedSource, _downloaded) &&
        _sortedBy == _sort &&
        (!byListening ||
            identical(_sortedRecent, _recent) &&
                identical(_sortedPlays, _plays))) {
      return cached;
    }
    // Lower-cased once per song, not once per comparison.
    final titles = <String, String>{};
    final artists = <String, String>{};
    String titleOf(Track t) => titles[t.id] ??= t.title.toLowerCase();
    String nameOf(Track t) => artists[t.id] ??= artistOf(t).toLowerCase();
    int byTitle(Track a, Track b) => titleOf(a).compareTo(titleOf(b));
    final sorted = switch (_sort) {
      LibrarySort.recent => _downloaded,
      LibrarySort.played => _byLastPlayed(),
      LibrarySort.mostPlayed => _byPlayCount(),
      // The songs gone longest unheard: never played first, oldest
      // downloads first among those, then the least recently played.
      LibrarySort.forgotten => _byLastPlayed().reversed.toList(),
      LibrarySort.title => List.of(_downloaded)..sort(byTitle),
      LibrarySort.artist => List.of(_downloaded)
        ..sort((a, b) {
          final byArtist = nameOf(a).compareTo(nameOf(b));
          return byArtist != 0 ? byArtist : byTitle(a, b);
        }),
    };
    _sortedSource = _downloaded;
    _sortedRecent = _recent;
    _sortedPlays = _plays;
    _sortedBy = _sort;
    return _sortedCache = List.unmodifiable(sorted);
  }

  // ---------------------------------------------------------------------------
  // Artists
  // ---------------------------------------------------------------------------

  static final RegExp _artistSeparators = RegExp(
      r'\s*(?:[&、,，/／×]|\bfeat\b\.?|\bft\b\.?)\s*',
      caseSensitive: false);

  /// Who performs [track] (see [TrackCredit.artistOf]).
  static String artistOf(Track track) => TrackCredit.artistOf(track);

  /// Individual names in a credit like `黄绮珊 & 周深`.
  static List<String> artistNamesOf(Track track) => artistOf(track)
      .split(_artistSeparators)
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toList();

  List<ArtistGroup>? _artistsCache;
  List<Track>? _artistsSource;

  /// Every artist in the library, most songs first. A collaboration counts
  /// for each of its artists.
  List<ArtistGroup> get artists {
    final cached = _artistsCache;
    if (cached != null && identical(_artistsSource, _downloaded)) return cached;

    final groups = <String, List<Track>>{};
    final names = <String, String>{};
    for (final track in _downloaded) {
      for (final name in artistNamesOf(track)) {
        final key = name.toLowerCase();
        names.putIfAbsent(key, () => name);
        groups.putIfAbsent(key, () => []).add(track);
      }
    }
    final list = [
      for (final entry in groups.entries)
        ArtistGroup(names[entry.key]!, List.unmodifiable(entry.value)),
    ]..sort((a, b) {
        final byCount = b.tracks.length.compareTo(a.tracks.length);
        return byCount != 0
            ? byCount
            : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    _artistsSource = _downloaded;
    return _artistsCache = List.unmodifiable(list);
  }

  ArtistGroup? artistNamed(String name) {
    final key = name.toLowerCase();
    for (final group in artists) {
      if (group.name.toLowerCase() == key) return group;
    }
    return null;
  }

  Future<void> setSort(LibrarySort sort) async {
    if (sort == _sort) return;
    _sort = sort;
    notifyListeners();
    await Prefs.set('librarySort', sort.name);
  }

  Future<void> _loadSort() async {
    final saved = await Prefs.get('librarySort');
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
      DatabaseService.getPlayStats(),
    ]);
    final known = _downloadedIds;
    final downloaded = results[0] as List<Track>;
    // Most events (a favourite, a playlist) leave the downloads as they
    // were: keeping the same list keeps the sort and artist work done on it.
    var same = downloaded.length == _downloaded.length;
    for (var i = 0; same && i < downloaded.length; i++) {
      same = identical(downloaded[i], _downloaded[i]);
    }
    if (!same) {
      _downloaded = List.unmodifiable(downloaded);
      _downloadedIds = {for (final t in _downloaded) t.id};
      _teachArtists();
    }
    if (_loaded) {
      // A song that just arrived gets its real name looked up.
      for (final track in _downloaded) {
        if (!known.contains(track.id)) TrackNaming.autoName(track);
      }
    }
    _playlists = List.unmodifiable(results[1] as List<Playlist>);
    _recent = List.unmodifiable(results[2] as List<Track>);
    _plays = results[3] as Map<String, PlayStat>;
    _active = DownloadManager.instance.activeTasks;
    _failedCount = DownloadManager.instance.failedTasks.length;
    _loaded = true;
    notifyListeners();
  }

  Set<String> _taught = const {};

  /// The artists of songs already named are names the title parser can
  /// recognise in the next video, with or without a connection.
  void _teachArtists() {
    final names = {
      for (final track in _downloaded)
        if (track.isNamed) ...artistNamesOf(track),
    }..removeWhere(Accompaniment.isCredit);
    if (setEquals(names, _taught)) return;
    _taught = names;
    LyricsEngine.knownArtists = names;
    TrackCredit.reset();
    _artistsCache = null;
    _sortedCache = null;
  }

  Future<void> _loadRecent() async {
    _recent = List.unmodifiable(await DatabaseService.getRecentlyPlayed());
    _plays = await DatabaseService.getPlayStats();
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
