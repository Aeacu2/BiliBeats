import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/play_stat.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import 'audio_download_service.dart';
import 'store_files.dart';

/// Parse helpers run inside a background isolate (via [StoreFiles.load]): a
/// large library means several files of jsonDecode + object construction,
/// and doing that on the UI isolate blocked the first frame after startup.
/// They are top-level because isolate entry points must be top-level or
/// static, and they only touch pure model constructors — never the
/// service's static state.
List<Track> _parseTrackList(String json) =>
    _tracksIn(StoreFiles.unwrap(jsonDecode(json)) as List<dynamic>? ?? []);

List<Track> _tracksIn(List<dynamic> list) {
  final out = <Track>[];
  for (final item in list) {
    try {
      out.add(Track.fromMap(Map<String, dynamic>.from(item as Map)));
    } catch (e) {
      debugPrint('Library: skipped a bad track: $e');
    }
  }
  return out;
}

/// The playlists file before songs were stored by id: each song in full.
List<Playlist> _parsePlaylistList(String json) {
  final list = StoreFiles.unwrap(jsonDecode(json)) as List<dynamic>? ?? [];
  final out = <Playlist>[];
  for (final item in list) {
    try {
      final map = Map<String, dynamic>.from(item as Map);
      final tracks = _tracksIn(map['tracks'] as List<dynamic>? ?? []);
      out.add(Playlist.fromMap(map, tracks: tracks));
    } catch (e) {
      debugPrint('Library: skipped a bad playlist: $e');
    }
  }
  return out;
}

/// A playlist as stored: its songs are ids (of the download list's copies)
/// or songs in full.
typedef _StoredPlaylist = ({Playlist playlist, List<Object> entries});

List<_StoredPlaylist> _parseStoredPlaylists(String json) {
  final list = StoreFiles.unwrap(jsonDecode(json)) as List<dynamic>? ?? [];
  final out = <_StoredPlaylist>[];
  for (final item in list) {
    try {
      final map = Map<String, dynamic>.from(item as Map);
      final entries = <Object>[];
      for (final entry in map['tracks'] as List<dynamic>? ?? []) {
        if (entry is String) {
          if (entry.isNotEmpty) entries.add(entry);
        } else {
          entries.addAll(_tracksIn([entry]));
        }
      }
      out.add((playlist: Playlist.fromMap(map), entries: entries));
    } catch (e) {
      debugPrint('Library: skipped a bad playlist: $e');
    }
  }
  return out;
}

Map<String, PlayStat> _parsePlays(String json) {
  final map = StoreFiles.unwrap(jsonDecode(json));
  if (map is! Map) return {};
  return {
    for (final e in map.entries)
      if (PlayStat.fromMap(e.value) case final stat?) '${e.key}': stat,
  };
}

/// The library: downloaded songs, play history and counts, and playlists
/// (收藏 among them), each a whole-file store written through [StoreFiles].
///
/// A song can be held in several of these at once, each as its own copy of
/// the [Track]; an edit or a measured loudness is applied to every copy.
/// Screens do not read this directly; they listen to `LibraryController`.
class DatabaseService {
  DatabaseService._();

  static const String _downloadedFile = 'bilibeat_downloaded.json';
  static const String _historyFile = 'bilibeat_recently_played.json';

  /// Playlists, each song stored as the id of its downloaded copy where the
  /// two are the same, else in full.
  static const String _playlistsFile = 'bilibeat_playlists2.json';

  /// Playlists as earlier builds kept them, every song in full. Read once,
  /// to move to [_playlistsFile], and never written again: an older build
  /// installed over this one still finds every playlist as it was then,
  /// and cannot touch the newer file. Should an older build change it, it
  /// becomes the newer of the two and is moved over again.
  static const String _legacyPlaylistsFile = 'bilibeat_playlists.json';
  static const String _playsFile = 'bilibeat_plays.json';

  static final List<Track> _downloadedTracks = [];
  static final List<Track> _recentlyPlayed = [];

  /// Track id -> how often and when it was last really listened to.
  static final Map<String, PlayStat> _plays = {};

  static final List<Playlist> _playlists = [_emptyFavorites()];

  static Playlist _emptyFavorites() =>
      Playlist(id: Playlist.favoritesId, name: '收藏', tracks: []);

  static int _playlistSeq = 0;

  /// Plays remembered: long enough to order a library by (排序 → 最近播放).
  static const int _historyLimit = 1000;

  static final StreamController<void> _libraryUpdateController =
      StreamController<void>.broadcast();
  static final StreamController<void> _historyUpdateController =
      StreamController<void>.broadcast();

  /// Ids whose local audio was just deleted. The player drops them from its
  /// queue so it never tries to open a file that is gone.
  static final StreamController<Set<String>> _downloadRemovedController =
      StreamController<Set<String>>.broadcast();

  /// Emitted when the library changes: downloads, playlists or favourites.
  /// Screens subscribe to this instead of relying on whichever call site
  /// happened to make the change to also remember to refresh them.
  static Stream<void> get libraryUpdateStream =>
      _libraryUpdateController.stream;

  /// Emitted when the recently-played list changes — including when the audio
  /// handler auto-advances, which no UI action would otherwise notice.
  static Stream<void> get historyUpdateStream =>
      _historyUpdateController.stream;

  static Stream<Set<String>> get downloadRemovedStream =>
      _downloadRemovedController.stream;

  static void _libraryChanged() {
    if (!_libraryUpdateController.isClosed) _libraryUpdateController.add(null);
  }

  static void _historyChanged() {
    if (!_historyUpdateController.isClosed) _historyUpdateController.add(null);
  }

  // ---------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------

  static Future<void>? _loadFuture;

  static Future<void> _ensureLoaded() {
    final existing = _loadFuture;
    if (existing != null) return existing;
    final fut = _load().catchError((e, st) {
      debugPrint('DatabaseService _ensureLoaded failed, will retry: $e');
      _loadFuture = null;
      Error.throwWithStackTrace(e, st);
    });
    _loadFuture = fut;
    return fut;
  }

  static Future<void> _load() async {
    try {
      final docs = await StoreFiles.documents();
      final everSetAside = await StoreFiles.tidy();

      // Each file is parsed into a local list first, then swapped into the
      // store: one corrupt file must not wipe the whole in-memory library
      // (a truncated write is easy with whole-file rewrites).
      final downloaded = await StoreFiles.load(_downloadedFile, _parseTrackList,
          offThread: true);
      if (downloaded != null) _replace(_downloadedTracks, downloaded);
      // Before discovery drops songs whose files are gone: a playlist may
      // name them by id.
      final listed = {for (final t in _downloadedTracks) t.id: t};
      final downloadsChanged = await _discoverAudioFiles(docs);
      final history =
          await StoreFiles.load(_historyFile, _parseTrackList, offThread: true);
      if (history != null) _replace(_recentlyPlayed, history);
      final playlistsChanged = await _loadPlaylists(listed, docs);
      if (!_playlists.any((p) => p.id == Playlist.favoritesId)) {
        _playlists.insert(0, _emptyFavorites());
      }
      // Playlists first: a song the download list has lost is then written
      // into them in full before the list stops holding it.
      if (playlistsChanged) await _persistPlaylists();
      // Pruned, or found on disk but missing from the list (a download that
      // completed while the list's file was truncated): saved, so the next
      // launch does not depend on discovery.
      if (downloadsChanged) unawaited(_persistDownloaded());
      final plays = await StoreFiles.load(_playsFile, _parsePlays);
      if (plays != null) {
        _plays
          ..clear()
          ..addAll(plays);
      }
      _rebaseCovers(docs);
      // With a store set aside, what it referenced is unknown: keep it all.
      if (!StoreFiles.setAsideThisLaunch && !everSetAside) {
        unawaited(_sweepCovers(docs));
      }
    } catch (e) {
      debugPrint('DatabaseService _ensureLoaded error: $e');
    }
  }

  static void _replace<T>(List<T> store, List<T> loaded) => store
    ..clear()
    ..addAll(loaded);

  /// Reads the playlists, from the older file when it is the newer of the
  /// two (see [_legacyPlaylistsFile]). True when they are to be saved
  /// again: moved from the older file, or holding by id a song the
  /// download list no longer has ([listed]: the list as it was read).
  static Future<bool> _loadPlaylists(
      Map<String, Track> listed, String docs) async {
    final downloads = {for (final t in _downloadedTracks) t.id: t};
    if (await _legacyIsNewer()) {
      final legacy = await StoreFiles.load(
          _legacyPlaylistsFile, _parsePlaylistList,
          offThread: true);
      if (legacy != null) {
        for (final playlist in legacy) {
          _alignWithDownloads(playlist.tracks, downloads, docs);
        }
        _replace(_playlists, legacy);
        return true;
      }
    }
    final stored = await StoreFiles.load(_playlistsFile, _parseStoredPlaylists,
        offThread: true);
    if (stored == null) return false;
    Map<String, Track>? legacyCopies;
    var changed = false;
    final playlists = <Playlist>[];
    for (final (:playlist, :entries) in stored) {
      final tracks = <Track>[];
      for (final entry in entries) {
        if (entry is Track) {
          tracks.add(entry);
          continue;
        }
        final id = entry as String;
        var track = downloads[id];
        if (track == null) {
          // Its file is gone (or the list was unreadable): the copy the list
          // had, else the one the older file kept.
          changed = true;
          legacyCopies ??= await _legacyCopies();
          track = listed[id] ?? legacyCopies[id];
        }
        if (track != null) {
          tracks.add(track);
        } else {
          debugPrint('Library: playlist ${playlist.id} lost song $id');
        }
      }
      if (_alignWithDownloads(tracks, downloads, docs)) changed = true;
      playlists.add(Playlist(
          id: playlist.id,
          name: playlist.name,
          coverUrl: playlist.coverUrl,
          tracks: tracks));
    }
    _replace(_playlists, playlists);
    return changed;
  }

  /// Replaces each song in [tracks] that differs from its download only in
  /// what is worked out rather than chosen (loudness, matcher generation,
  /// UP主, part name, length, a cover's moved folder) with the download's
  /// copy, which is then written by id. Copies drifted apart that way under
  /// older builds. A different name, artist or cover may be the
  /// listener's, and is kept. True when any was replaced.
  static bool _alignWithDownloads(
      List<Track> tracks, Map<String, Track> downloads, String docs) {
    var changed = false;
    for (var i = 0; i < tracks.length; i++) {
      final t = tracks[i];
      final d = downloads[t.id];
      if (d == null || identical(d, t) || !_sameChoices(t, d, docs)) continue;
      tracks[i] = d;
      changed = true;
    }
    return changed;
  }

  static bool _sameChoices(Track a, Track b, String docs) =>
      a.title == b.title &&
      a.uploader == b.uploader &&
      a.rawTitle == b.rawTitle &&
      a.named == b.named &&
      rebaseCover(a.coverUrl, docs) == rebaseCover(b.coverUrl, docs);

  static Future<bool> _legacyIsNewer() async {
    try {
      final legacy = File(await StoreFiles.pathOf(_legacyPlaylistsFile));
      if (!await legacy.exists()) return false;
      final current = File(await StoreFiles.pathOf(_playlistsFile));
      if (!await current.exists()) return true;
      return (await legacy.lastModified())
          .isAfter(await current.lastModified());
    } catch (e) {
      debugPrint('Library: playlist files not compared: $e');
      return false;
    }
  }

  /// Every song the older playlists file kept, by id.
  static Future<Map<String, Track>> _legacyCopies() async {
    final legacy = await StoreFiles.load(
            _legacyPlaylistsFile, _parsePlaylistList,
            offThread: true) ??
        const <Playlist>[];
    return {
      for (final p in legacy)
        for (final t in p.tracks) t.id: t,
    };
  }

  /// Squares the download list with the audio folder: songs whose files are
  /// there but which the list lost are added back (from the metadata kept
  /// beside each file), and entries whose files are gone are dropped.
  /// True when the list changed (and is to be saved).
  static Future<bool> _discoverAudioFiles(String docs) async {
    try {
      final audioDir = Directory('$docs/bilibeat_audio');
      // One listing answers every "is it there" below; a stat per file per
      // song made a large library slow to open.
      final names = <String>{};
      if (await audioDir.exists()) {
        final stale = DateTime.now().subtract(const Duration(days: 7));
        await for (final entity in audioDir.list()) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          // Left by a write the process did not survive.
          if (name.endsWith('.tmp')) {
            await StoreFiles.deleteQuietly(entity);
            continue;
          }
          // A download given up on (or a file being imported): kept a week
          // in case it is resumed.
          if (name.endsWith('.part') || name.endsWith('.part.json')) {
            try {
              if ((await entity.lastModified()).isBefore(stale)) {
                await StoreFiles.deleteQuietly(entity);
              }
            } catch (_) {}
            continue;
          }
          names.add(name);
        }
      }

      final known = {for (final t in _downloadedTracks) t.id};
      var added = 0;
      for (final name in names) {
        if (!name.startsWith('audio_') || !name.endsWith('.ready')) continue;
        final fileKey =
            name.substring('audio_'.length, name.length - '.ready'.length);
        // Only a download the library does not list needs its file read.
        if (known.contains(fileKey)) continue;
        if (!names.contains('audio_$fileKey.m4a') ||
            !names.contains('audio_$fileKey.json')) {
          continue;
        }
        final metaPath = '${audioDir.path}/audio_$fileKey.json';
        try {
          final metaContent = await File(metaPath).readAsString();
          final trackMap = Map<String, dynamic>.from(jsonDecode(metaContent));
          final track = Track.fromMap(trackMap);
          if (track.id.isEmpty) {
            debugPrint('Auto-discover skip empty id: $metaPath');
            continue;
          }
          if (fileKey != track.id && fileKey != track.bvid) {
            debugPrint(
                'Auto-discover id mismatch fileKey=$fileKey track.id=${track.id}');
          }
          if (known.add(track.id)) {
            _downloadedTracks.add(track);
            added++;
          }
        } catch (e) {
          debugPrint('Auto-discover track error: $e');
        }
      }

      // Prune entries whose files vanished externally (e.g. user cleared
      // cache) — including all of them when the folder itself is gone.
      final beforePrune = _downloadedTracks.length;
      _downloadedTracks.removeWhere((t) {
        // Kept if id empty (should not happen) to avoid data loss.
        final there = t.id.isEmpty ||
            (names.contains('audio_${t.id}.ready') &&
                names.contains('audio_${t.id}.m4a'));
        if (!there) {
          debugPrint('Pruning stale downloaded entry ${t.id} (file missing)');
          AudioDownloadService.invalidateMemo(t.id);
        }
        return !there;
      });
      return _downloadedTracks.length != beforePrune || added > 0;
    } catch (e) {
      debugPrint('DatabaseService audio discovery skipped: $e');
      return false;
    }
  }

  static const String _coverFolder = '/bilibeat_covers/';

  /// A cover the listener picked is stored by its full path, and on iOS the
  /// app's container moves when the app is reinstalled or re-signed. Paths
  /// into the cover folder are re-pointed at where that folder is now.
  @visibleForTesting
  static String rebaseCover(String url, String docs) {
    if (!url.startsWith('/') && !url.startsWith('file://')) return url;
    final at = url.lastIndexOf(_coverFolder);
    if (at < 0) return url;
    return '$docs$_coverFolder${url.substring(at + _coverFolder.length)}';
  }

  static void _rebaseCovers(String docs) {
    void rebase(List<Track> tracks) {
      for (var i = 0; i < tracks.length; i++) {
        final cover = rebaseCover(tracks[i].coverUrl, docs);
        if (cover != tracks[i].coverUrl) {
          tracks[i] = tracks[i].copyWith(coverUrl: cover);
        }
      }
    }

    rebase(_downloadedTracks);
    rebase(_recentlyPlayed);
    for (var i = 0; i < _playlists.length; i++) {
      final playlist = _playlists[i];
      rebase(playlist.tracks);
      final cover = playlist.coverUrl;
      if (cover != null && rebaseCover(cover, docs) != cover) {
        _playlists[i] = playlist.withCover(rebaseCover(cover, docs));
      }
    }
  }

  /// Deletes picked covers nothing shows any more (a cover that was
  /// replaced, or picked and then not saved). Recent files are left alone.
  static Future<void> _sweepCovers(String docs) async {
    try {
      final folder = Directory('$docs/bilibeat_covers');
      if (!await folder.exists()) return;
      String local(String url) =>
          url.startsWith('file://') ? url.substring('file://'.length) : url;
      final used = <String>{
        for (final t in _everyCopy()) local(t.coverUrl),
        for (final p in _playlists)
          if (p.coverUrl != null) local(p.coverUrl!),
      };
      final cutoff = DateTime.now().subtract(const Duration(days: 1));
      await for (final entity in folder.list()) {
        if (entity is! File || used.contains(entity.path)) continue;
        if ((await entity.lastModified()).isAfter(cutoff)) continue;
        await entity.delete();
      }
    } catch (e) {
      debugPrint('DatabaseService cover sweep skipped: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Saving
  // ---------------------------------------------------------------------------

  /// Each song as JSON, kept while that copy is unchanged ([Track] is
  /// immutable; an edit is a new copy). History alone is a thousand songs,
  /// rewritten on every play: re-encoding all of them each time was most
  /// of the cost of saving.
  static final Expando<String> _trackJson = Expando('track json');

  static String _tracksJson(List<Track> tracks) =>
      '[${[for (final t in tracks) _json(t)].join(',')}]';

  /// [objectJson] (an encoded map) with a `tracks` entry added.
  static String _withTracks(String objectJson, String tracksJson) {
    final body = objectJson.substring(0, objectJson.length - 1);
    return '$body${body == '{' ? '' : ','}"tracks":$tracksJson}';
  }

  static Future<void> _persistDownloaded() => StoreFiles.save(
      _downloadedFile, EncodedJson(_tracksJson(_downloadedTracks)));

  static Future<void> _persistRecentlyPlayed() =>
      StoreFiles.save(_historyFile, EncodedJson(_tracksJson(_recentlyPlayed)));

  static String _json(Track t) => _trackJson[t] ??= jsonEncode(t.toMap());

  /// Saves the playlists and tells the library they changed. A song is
  /// written as its id where it is exactly the download list's copy — most
  /// of them, and a twentieth of the size — else in full, so nothing is
  /// lost whatever becomes of the download.
  static Future<void> _persistPlaylists() async {
    final downloads = {for (final t in _downloadedTracks) t.id: t};
    String entry(Track t) {
      final download = downloads[t.id];
      final same = download != null &&
          (identical(download, t) || _json(download) == _json(t));
      return same ? jsonEncode(t.id) : _json(t);
    }

    final list = [
      for (final p in _playlists)
        _withTracks(jsonEncode(p.toMap()),
            '[${[for (final t in p.tracks) entry(t)].join(',')}]'),
    ];
    await StoreFiles.save(_playlistsFile, EncodedJson('[${list.join(',')}]'));
    _libraryChanged();
  }

  // ---------------------------------------------------------------------------
  // Every copy of a song
  // ---------------------------------------------------------------------------

  static Iterable<Track> _everyCopy() sync* {
    yield* _downloadedTracks;
    for (final p in _playlists) {
      yield* p.tracks;
    }
    yield* _recentlyPlayed;
  }

  /// The copy of [track] the library already holds: the download, else one
  /// kept in a playlist or in history.
  static Track? _knownCopy(Track track) {
    for (final t in _everyCopy()) {
      if (t.id == track.id) return t;
    }
    return null;
  }

  /// Replaces each copy of song [id] with what [change] makes of it (null:
  /// left as it is); says which stores changed.
  static ({bool downloaded, bool playlists, bool history}) _changeCopies(
      String id, Track? Function(Track) change) {
    bool patch(List<Track> list) {
      final index = list.indexWhere((t) => t.id == id);
      if (index == -1) return false;
      final changed = change(list[index]);
      if (changed == null) return false;
      list[index] = changed;
      return true;
    }

    var playlists = false;
    for (final playlist in _playlists) {
      if (patch(playlist.tracks)) playlists = true;
    }
    return (
      downloaded: patch(_downloadedTracks),
      playlists: playlists,
      history: patch(_recentlyPlayed),
    );
  }

  /// The listener's edit (编辑信息), on every copy and on the metadata kept
  /// beside the audio.
  static Future<void> updateTrackMetadata(Track updated) async {
    await _ensureLoaded();
    final changed = _changeCopies(updated.id, (_) => updated);
    if (changed.downloaded) await _persistDownloaded();
    // Deliberate edit: this one does overwrite the on-disk copy.
    await AudioDownloadService.saveTrackMetadata(updated, force: true);
    // The playlists file holds a copy of every song in every playlist:
    // not rewritten for a song that is in none.
    if (changed.playlists) {
      await _persistPlaylists();
    } else {
      _libraryChanged();
    }
    if (changed.history) await _persistRecentlyPlayed();
    _historyChanged();
  }

  /// Records a track's measured loudness on every stored copy, leaving the
  /// rest of its (possibly edited) metadata alone.
  static Future<void> setTrackLoudness(String trackId, double loudness) async {
    await _ensureLoaded();
    final changed = _changeCopies(trackId, (t) {
      if (t.loudness == loudness) return null;
      return t.copyWith(loudness: loudness);
    });
    if (changed.downloaded) {
      await _persistDownloaded();
      final download = await downloadedTrack(trackId);
      if (download != null) {
        await AudioDownloadService.saveTrackMetadata(download, force: true);
      }
    }
    if (changed.playlists) await _persistPlaylists();
    if (changed.history) await _persistRecentlyPlayed();
    // Other holders of the track (lists, sheets) pick up the new copy.
    if (changed.downloaded || changed.playlists || changed.history) {
      _libraryChanged();
    }
  }

  // ---------------------------------------------------------------------------
  // Downloads
  // ---------------------------------------------------------------------------

  static Future<List<Track>> getDownloadedTracks() async {
    await _ensureLoaded();
    return List<Track>.from(_downloadedTracks);
  }

  /// The library's copy of the download [id], without copying the library.
  static Future<Track?> downloadedTrack(String id) async {
    await _ensureLoaded();
    for (final t in _downloadedTracks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Registers [track] as available offline.
  ///
  /// If the library already knows this track, it is left exactly as it is.
  /// Playback calls this on every start with a possibly stale copy, and
  /// overwriting here reverted any title/artist/cover the user had edited —
  /// [updateTrackMetadata] is the only thing allowed to change that.
  static Future<void> saveDownloadedTrack(Track track) async {
    await _ensureLoaded();
    if (_downloadedTracks.any((t) => t.id == track.id)) return;
    // Downloaded again after 删除下载: playlists and history kept the song as
    // the listener (or the matcher) named it, and that is the copy to bring
    // back, not the raw video the search result describes.
    final kept = _knownCopy(track);
    _downloadedTracks.insert(
      0,
      kept == null || !kept.isNamed
          ? track
          : kept.copyWith(loudness: track.loudness ?? kept.loudness),
    );
    await _persistDownloaded();
    _libraryChanged();
  }

  /// Deletes the local audio for [track] but preserves the user's
  /// collection: playlist membership, Favorites, metadata and history all
  /// stay. History entries for a removed download remain visible; tapping
  /// one opens track details instead of silently re-downloading.
  static Future<void> removeDownloadedTrack(Track track) async {
    await _ensureLoaded();
    await AudioDownloadService.delete(track);
    _downloadedTracks.removeWhere((t) => t.id == track.id);
    _downloadRemovedController.add({track.id});
    // Playlists holding the song by id now write it in full — before the
    // list that id pointed into stops holding it.
    if (_playlists.any((p) => p.tracks.any((t) => t.id == track.id))) {
      await _persistPlaylists();
    }
    await _persistDownloaded();
    _libraryChanged();
  }

  // ---------------------------------------------------------------------------
  // History and play counts
  // ---------------------------------------------------------------------------

  static Future<List<Track>> getRecentlyPlayed() async {
    await _ensureLoaded();
    return List<Track>.from(_recentlyPlayed);
  }

  /// Records a play. De-duplication is by track **id** (`bvid_p<page>`)
  /// only: keying by `bvid` used to collapse the separate parts (P1/P2/…)
  /// of one video into a single entry, silently dropping tracks from the
  /// list.
  static Future<void> addRecentlyPlayed(Track track) async {
    await _ensureLoaded();
    final alreadyFirst =
        _recentlyPlayed.isNotEmpty && _recentlyPlayed.first.id == track.id;
    _recentlyPlayed.removeWhere((t) => t.id == track.id);
    _recentlyPlayed.insert(0, track);
    if (_recentlyPlayed.length > _historyLimit) _recentlyPlayed.removeLast();
    await _persistRecentlyPlayed();
    if (!alreadyFirst) _historyChanged();
  }

  /// Counts one listen of [track] — the player calls this once a play has
  /// lasted long enough to mean it ([PlayStat.counts]).
  static Future<void> recordPlay(Track track, {DateTime? at}) async {
    await _ensureLoaded();
    final before = _plays[track.id];
    _plays[track.id] = PlayStat(
      count: (before?.count ?? 0) + 1,
      last: at ?? DateTime.now(),
    );
    await StoreFiles.save(
        _playsFile, {for (final e in _plays.entries) e.key: e.value.toMap()});
    _historyChanged();
  }

  static Future<Map<String, PlayStat>> getPlayStats() async {
    await _ensureLoaded();
    return Map.unmodifiable(_plays);
  }

  // ---------------------------------------------------------------------------
  // Playlists
  // ---------------------------------------------------------------------------

  static Future<List<Playlist>> getPlaylists() async {
    await _ensureLoaded();
    return List<Playlist>.from(_playlists);
  }

  static Future<Playlist> getFavoritesPlaylist() async {
    await _ensureLoaded();
    return _playlist(Playlist.favoritesId) ?? _emptyFavorites();
  }

  static Playlist? _playlist(String id) {
    for (final p in _playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Replaces the playlist [id] with what [change] makes of it.
  static Future<void> _rebuildPlaylist(
      String id, Playlist Function(Playlist) change) async {
    await _ensureLoaded();
    final index = _playlists.indexWhere((p) => p.id == id);
    if (index == -1) return;
    _playlists[index] = change(_playlists[index]);
    await _persistPlaylists();
  }

  /// Changes the songs of playlist [id] in place; saved when [change] says
  /// it changed them.
  static Future<void> _editTracks(
      String id, bool Function(List<Track> tracks) change) async {
    await _ensureLoaded();
    final playlist = _playlist(id);
    if (playlist != null && change(playlist.tracks)) await _persistPlaylists();
  }

  static Future<Playlist> createPlaylist(String name) async {
    await _ensureLoaded();
    // Use ms + seq + random to avoid collision within same ms across restarts
    // (_playlistSeq resets to 0 on restart). Random 20 bits + seq gives <1e-9
    // collision even at 1000 playlists/sec.
    final rnd = DateTime.now().microsecondsSinceEpoch % (1 << 20);
    final newPlaylist = Playlist(
      id: 'pl_${DateTime.now().millisecondsSinceEpoch}_${_playlistSeq++}_$rnd',
      name: name.trim().isEmpty ? '新建歌单' : name.trim(),
      tracks: [],
    );
    _playlists.add(newPlaylist);
    await _persistPlaylists();
    return newPlaylist;
  }

  static Future<void> renamePlaylist(String playlistId, String newName) =>
      _rebuildPlaylist(playlistId,
          (p) => newName.trim().isEmpty ? p : p.withName(newName.trim()));

  /// Sets (or clears, with null) a playlist's cover image.
  static Future<void> setPlaylistCover(String playlistId, String? path) =>
      _rebuildPlaylist(playlistId, (p) => p.withCover(path));

  static Future<void> deletePlaylist(String playlistId) async {
    await _ensureLoaded();
    if (playlistId == Playlist.favoritesId) return;
    _playlists.removeWhere((p) => p.id == playlistId);
    await _persistPlaylists();
  }

  /// Moves a track within a playlist. Both indices are final positions —
  /// `onReorderItem` already accounts for the removal, unlike the deprecated
  /// `onReorder`, whose newIndex needed adjusting by hand.
  static Future<void> reorderPlaylist(
          String playlistId, int oldIndex, int newIndex) =>
      _editTracks(playlistId, (tracks) {
        if (oldIndex < 0 || oldIndex >= tracks.length) return false;
        final track = tracks.removeAt(oldIndex);
        tracks.insert(newIndex.clamp(0, tracks.length), track);
        return true;
      });

  static Future<void> addTrackToPlaylist(String playlistId, Track track) =>
      addTracksToPlaylist(playlistId, [track]);

  /// Adds the [tracks] the playlist does not have yet to its front, in the
  /// order given; one save for the whole batch.
  static Future<void> addTracksToPlaylist(
          String playlistId, List<Track> tracks) =>
      _editTracks(playlistId, (list) {
        final have = {for (final t in list) t.id};
        final toAdd = [
          for (final t in tracks)
            if (have.add(t.id)) t,
        ];
        list.insertAll(0, toAdd);
        return toAdd.isNotEmpty;
      });

  /// Puts [track] back into a playlist at [index] (an undone removal).
  static Future<void> insertTrackInPlaylist(
          String playlistId, Track track, int index) =>
      _editTracks(playlistId, (list) {
        if (list.any((t) => t.id == track.id)) return false;
        list.insert(index.clamp(0, list.length), track);
        return true;
      });

  static Future<void> removeTrackFromPlaylist(
          String playlistId, String trackId) =>
      removeTracksFromPlaylist(playlistId, [trackId]);

  static Future<void> removeTracksFromPlaylist(
          String playlistId, List<String> trackIds) =>
      _editTracks(playlistId, (list) {
        final ids = trackIds.toSet();
        final before = list.length;
        list.removeWhere((t) => ids.contains(t.id));
        return list.length != before;
      });

  static Future<bool> isFavorite(String trackId) async {
    final favorites = await getFavoritesPlaylist();
    return favorites.tracks.any((t) => t.id == trackId);
  }

  static Future<bool> toggleFavorite(Track track) async {
    final favorites = await getFavoritesPlaylist();
    final tracks = favorites.tracks;
    if (tracks.any((t) => t.id == track.id)) {
      tracks.removeWhere((t) => t.id == track.id);
      await _persistPlaylists();
      return false;
    }
    // The caller may hold a search result's copy of a song the library has
    // since named.
    tracks.insert(0, _knownCopy(track) ?? track);
    await _persistPlaylists();
    return true;
  }
}
