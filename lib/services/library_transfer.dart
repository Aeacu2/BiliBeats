import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/playlist.dart';
import '../models/track.dart';
import 'audio_download_service.dart';
import 'database_service.dart';
import 'download_manager.dart';

@immutable
class ImportQueueState {
  const ImportQueueState(
      {this.pending = 0,
      this.failed = 0,
      this.completed = 0,
      this.paused = false});
  final int pending;
  final int failed;
  final int completed;
  final bool paused;
  int get total => completed + pending;
}

/// A library as it travels between two devices.
@immutable
class LibrarySnapshot {
  /// Every song, the downloaded ones first, each once.
  final List<Track> tracks;

  /// Name, whether it is 收藏, and its songs in order.
  final List<({String name, bool favorites, List<Track> tracks})> playlists;

  const LibrarySnapshot({required this.tracks, required this.playlists});
}

/// What an import set in motion.
typedef ImportSummary = ({int queued, int present, int playlists});

/// The library as a piece of text: copied on one device, pasted on another,
/// which then downloads the same songs itself.
///
/// The text carries what names a song — the video, the part, and the name
/// and artist it was given — and the playlists. It carries no audio, no
/// artwork chosen from the photo library and no lyrics.
///
/// Importing only adds: songs already here are left alone, playlists of the
/// same name are merged. Downloads run a few at a time and survive a
/// restart ([resume]); pasting the same text again picks up what is missing.
class LibraryTransfer {
  LibraryTransfer._();

  /// Marks the text and its format. Whatever surrounds it in the clipboard
  /// (a chat app's quote, a line break) is ignored.
  static const String prefix = 'BiliBeats1:';

  static const String _file = 'bilibeat_import.json';

  /// Downloads running at once: quick enough for a whole library, slow
  /// enough not to look like a crawler to Bilibili.
  static const int _concurrency = 2;

  /// A song that failed this many times (a deleted video, usually) is no
  /// longer tried on every start.
  static const int _maxAttempts = 3;

  static final RegExp _payload =
      RegExp(r'BiliBeats1:([A-Za-z0-9_\-=]+)\.([0-9a-f]{8})');

  // ---------------------------------------------------------------------------
  // Text
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _trackMap(Track t) {
    final map = t.toMap()
      ..remove('audioUrl') // signed for one device and one hour
      ..remove('loudness'); // measured again with the download
    // Artwork picked on this device is a path that exists only here.
    if (!t.coverUrl.startsWith('http')) map.remove('coverUrl');
    return map;
  }

  static String encode(LibrarySnapshot snapshot) {
    final index = <String, int>{
      for (var i = 0; i < snapshot.tracks.length; i++) snapshot.tracks[i].id: i,
    };
    final json = jsonEncode({
      't': [for (final t in snapshot.tracks) _trackMap(t)],
      'p': [
        for (final p in snapshot.playlists)
          {
            'n': p.name,
            if (p.favorites) 'f': true,
            'i': [
              for (final t in p.tracks)
                if (index[t.id] != null) index[t.id],
            ],
          },
      ],
    });
    final body = base64Url.encode(gzip.encode(utf8.encode(json)));
    return '$prefix$body.${_seal(body)}';
  }

  /// Tells a whole copy from one that lost its end on the way.
  static String _seal(String body) =>
      sha256.convert(ascii.encode(body)).toString().substring(0, 8);

  /// The library in [text], or null when it holds none that can be read.
  static LibrarySnapshot? decode(String text) {
    final match = _payload.firstMatch(text);
    if (match == null) return null;
    try {
      final body = match.group(1)!;
      if (_seal(body) != match.group(2)) return null;
      final json = jsonDecode(utf8.decode(gzip.decode(base64Url.decode(body))));
      if (json is! Map) return null;
      final tracks = <Track>[];
      final byIndex = <int, Track>{};
      final seen = <String>{};
      final rawTracks = json['t'] as List? ?? const [];
      for (var i = 0; i < rawTracks.length; i++) {
        final raw = rawTracks[i];
        if (raw is! Map) continue;
        try {
          final track = Track.fromMap(Map<String, dynamic>.from(raw));
          if (track.bvid.isEmpty) continue;
          byIndex[i] = track;
          if (seen.add(track.id)) tracks.add(track);
        } catch (_) {
          // One unreadable song does not cost the rest.
        }
      }
      final playlists = <({String name, bool favorites, List<Track> tracks})>[];
      for (final raw in json['p'] as List? ?? const []) {
        if (raw is! Map) continue;
        final name = raw['n'];
        final members = [
          for (final i in raw['i'] as List? ?? const [])
            if (i is int && byIndex[i] != null) byIndex[i]!,
        ];
        playlists.add((
          name: name is String ? name : '',
          favorites: raw['f'] == true,
          tracks: members,
        ));
      }
      if (tracks.isEmpty) return null;
      return LibrarySnapshot(tracks: tracks, playlists: playlists);
    } catch (e) {
      debugPrint('LibraryTransfer decode failed: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // This device
  // ---------------------------------------------------------------------------

  /// Everything downloaded and every playlist, as it is now.
  static Future<LibrarySnapshot> snapshot() async {
    final downloaded = await DatabaseService.getDownloadedTracks();
    final playlists = await DatabaseService.getPlaylists();
    final tracks = <Track>[];
    final seen = <String>{};
    for (final t in [...downloaded, ...playlists.expand((p) => p.tracks)]) {
      if (seen.add(t.id)) tracks.add(t);
    }
    return LibrarySnapshot(
      tracks: tracks,
      playlists: [
        for (final p in playlists)
          if (p.tracks.isNotEmpty)
            (
              name: p.name,
              favorites: p.id == Playlist.favoritesId,
              tracks: List<Track>.of(p.tracks),
            ),
      ],
    );
  }

  static Future<String> export() async => encode(await snapshot());

  /// Adds [snapshot] to this library: its playlists at once, its songs as
  /// they download.
  static Future<ImportSummary> import(LibrarySnapshot snapshot) async {
    final here = {
      for (final t in await DatabaseService.getDownloadedTracks()) t.id,
    };

    var merged = 0;
    final existing = await DatabaseService.getPlaylists();
    for (final p in snapshot.playlists) {
      if (p.tracks.isEmpty) continue;
      final String id;
      if (p.favorites) {
        id = Playlist.favoritesId;
      } else {
        final name = p.name.trim();
        final same = existing.where(
            (e) => e.id != Playlist.favoritesId && e.name.trim() == name);
        id = same.isNotEmpty
            ? same.first.id
            : (await DatabaseService.createPlaylist(name)).id;
      }
      await DatabaseService.addTracksToPlaylist(id, p.tracks);
      merged++;
    }

    final queued = await enqueueDownloads(snapshot.tracks);
    return (
      queued: queued,
      present: snapshot.tracks.where((t) => here.contains(t.id)).length,
      playlists: merged,
    );
  }

  // ---------------------------------------------------------------------------
  // The download queue
  // ---------------------------------------------------------------------------

  /// Songs still to fetch, with the times each has failed.
  static final List<({Track track, int attempts})> _pending = [];
  static final Set<String> _running = {};
  static final Map<String, Object> _jobTokens = {};
  static final Set<Object> _interrupted = {};

  /// Not tried twice in one run: what stopped it (no network, a video
  /// that is gone) is usually still there a second later.
  static final Set<String> _failedThisRun = {};
  static bool _loaded = false;
  static Future<void>? _loading;
  static bool _paused = false;
  static int _completed = 0;
  static int _generation = 0;
  static final ValueNotifier<ImportQueueState> status =
      ValueNotifier(const ImportQueueState());

  static List<Track> get queuedTracks => [
        for (final p in _pending)
          if (!_running.contains(p.track.id) &&
              !_failedThisRun.contains(p.track.id) &&
              p.attempts < _maxAttempts)
            p.track,
      ];

  static List<Track> get failedTracks => [
        for (final p in _pending)
          if (_failedThisRun.contains(p.track.id) || p.attempts >= _maxAttempts)
            p.track,
      ];

  static bool contains(String id) => _pending.any((p) => p.track.id == id);

  /// Songs an import has yet to download.
  static final ValueNotifier<int> remaining = ValueNotifier(0);

  /// Replaces the downloader in tests.
  @visibleForTesting
  static Future<bool> Function(Track track)? downloadWith;

  static Future<void> _load() => _loading ??= _readQueue();

  static Future<void> _readQueue() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final text = await DatabaseService.readStoreFile(_file);
      if (text == null) return;
      final payload = DatabaseService.unwrapStorePayload(jsonDecode(text));
      _paused = payload is Map && payload['paused'] == true;
      _completed = payload is Map && payload['completed'] is int
          ? payload['completed'] as int
          : 0;
      final items = payload is Map ? payload['items'] : payload;
      for (final raw in items as List? ?? const []) {
        if (raw is! Map) continue;
        final track =
            Track.fromMap(Map<String, dynamic>.from(raw['track'] as Map));
        if (_pending.any((p) => p.track.id == track.id)) continue;
        _pending.add((
          track: track,
          attempts: (raw['attempts'] as num?)?.toInt() ?? 0,
        ));
      }
    } catch (e) {
      // A queue that cannot be read is only a paste away.
      debugPrint('LibraryTransfer queue skipped: $e');
    }
  }

  static Future<void> _save() async {
    try {
      await DatabaseService.writeStoreFile(_file, {
        'paused': _paused,
        'completed': _completed,
        'items': [
          for (final p in _pending)
            {'track': _trackMap(p.track), 'attempts': p.attempts}
        ],
      });
    } catch (e) {
      debugPrint('LibraryTransfer queue not saved: $e');
    }
  }

  static Future<int> enqueueDownloads(List<Track> tracks) async {
    await _load();
    final here = {
      for (final t in await DatabaseService.getDownloadedTracks()) t.id
    };
    if (_pending.isEmpty) _completed = 0;
    var added = 0;
    for (final track in tracks) {
      if (here.contains(track.id)) continue;
      final at = _pending.indexWhere((p) => p.track.id == track.id);
      // Do not reorder or reset work that is already queued or running.
      if (at != -1) continue;
      added++;
      _failedThisRun.remove(track.id);
      _pending.add((track: track, attempts: 0));
      _jobTokens[track.id] = Object();
    }
    await _save();
    _pump();
    return added;
  }

  static Future<void> pause() async {
    await _load();
    _paused = true;
    for (final id in _running) {
      final token = _jobTokens[id];
      if (token != null) _interrupted.add(token);
      DownloadManager.instance.cancelDownload(id);
    }
    await _save();
    _pump();
  }

  static Future<void> continueDownloads() async {
    await _load();
    _paused = false;
    await _save();
    _pump();
  }

  static Future<void> cancelTrack(String id) async {
    await _load();
    _pending.removeWhere((p) => p.track.id == id);
    if (DownloadManager.instance.isFailed(id)) {
      DownloadManager.instance.dismissFailed(id);
    }
    _jobTokens.remove(id);
    _failedThisRun.remove(id);
    DownloadManager.instance.cancelDownload(id);
    await _save();
    _pump();
  }

  static Future<void> cancelAll() async {
    await _load();
    for (final p in _pending) {
      if (DownloadManager.instance.isFailed(p.track.id)) {
        DownloadManager.instance.dismissFailed(p.track.id);
      }
    }
    _pending.clear();
    _jobTokens.clear();
    _failedThisRun.clear();
    _completed = 0;
    _paused = false;
    for (final id in _running) {
      DownloadManager.instance.cancelDownload(id);
    }
    await _save();
    _pump();
  }

  static Future<void> retryTrack(String id) async {
    await _load();
    final at = _pending.indexWhere((p) => p.track.id == id);
    if (at == -1) return;
    _pending[at] = (track: _pending[at].track, attempts: 0);
    _failedThisRun.remove(id);
    await _save();
    _pump();
  }

  static Future<void> retryFailed() async {
    await _load();
    for (var i = 0; i < _pending.length; i++) {
      final p = _pending[i];
      if (_failedThisRun.contains(p.track.id) || p.attempts >= _maxAttempts) {
        _pending[i] = (track: p.track, attempts: 0);
      }
    }
    _failedThisRun.clear();
    await _save();
    _pump();
  }

  /// Carries on with an import the last run of the app did not finish.
  static Future<void> resume() async {
    await _load();
    _pump();
  }

  static void _pump() {
    bool waiting(({Track track, int attempts}) p) =>
        p.attempts < _maxAttempts && !_failedThisRun.contains(p.track.id);
    remaining.value = _pending.where(waiting).length;
    status.value = ImportQueueState(
      pending: _pending.length,
      failed: _pending.where((p) => !waiting(p)).length,
      completed: _completed,
      paused: _paused,
    );
    if (_paused) return;
    for (final next in List.of(_pending)) {
      if (_running.length >= _concurrency) return;
      if (!waiting(next)) continue;
      if (!_running.add(next.track.id)) continue;
      final token = _jobTokens.putIfAbsent(next.track.id, Object.new);
      unawaited(_fetch(next.track, _generation, token));
    }
  }

  static Future<bool> _download(Track track) async {
    await DownloadManager.instance.startDownload(track);
    return AudioDownloadService.isDownloaded(track);
  }

  static Future<void> _fetch(Track track, int generation, Object token) async {
    var done = false;
    try {
      done = await (downloadWith ?? _download)(track);
    } catch (e) {
      debugPrint('LibraryTransfer download failed: $e');
    }
    if (generation != _generation) return;
    final interrupted = _interrupted.remove(token);
    final at = identical(_jobTokens[track.id], token)
        ? _pending.indexWhere((p) => p.track.id == track.id)
        : -1;
    if (at != -1) {
      if (done) {
        _pending.removeAt(at);
        _jobTokens.remove(track.id);
        _completed++;
      } else if (!_paused && !interrupted) {
        final failed = _pending[at];
        _pending[at] = (track: failed.track, attempts: failed.attempts + 1);
        _failedThisRun.add(track.id);
      }
    }
    await _save();
    _running.remove(track.id);
    _pump();
  }

  @visibleForTesting
  static void resetForTest() {
    _generation++;
    _interrupted.clear();
    _jobTokens.clear();
    _pending.clear();
    _running.clear();
    _failedThisRun.clear();
    _loaded = false;
    _loading = null;
    _paused = false;
    _completed = 0;
    remaining.value = 0;
    status.value = const ImportQueueState();
    downloadWith = null;
  }
}
