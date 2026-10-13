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
    final missing = [
      for (final t in snapshot.tracks)
        if (!here.contains(t.id)) t,
    ];

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

    await _enqueue(missing);
    return (
      queued: missing.length,
      present: snapshot.tracks.length - missing.length,
      playlists: merged,
    );
  }

  // ---------------------------------------------------------------------------
  // The download queue
  // ---------------------------------------------------------------------------

  /// Songs still to fetch, with the times each has failed.
  static final List<({Track track, int attempts})> _pending = [];
  static final Set<String> _running = {};

  /// Not tried twice in one run: what stopped it (no network, a video
  /// that is gone) is usually still there a second later.
  static final Set<String> _failedThisRun = {};
  static bool _loaded = false;

  /// Songs an import has yet to download.
  static final ValueNotifier<int> remaining = ValueNotifier(0);

  /// Replaces the downloader in tests.
  @visibleForTesting
  static Future<bool> Function(Track track)? downloadWith;

  static Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final text = await DatabaseService.readStoreFile(_file);
      if (text == null) return;
      final payload = DatabaseService.unwrapStorePayload(jsonDecode(text));
      for (final raw in payload as List? ?? const []) {
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
      await DatabaseService.writeStoreFile(_file, [
        for (final p in _pending)
          {'track': _trackMap(p.track), 'attempts': p.attempts},
      ]);
    } catch (e) {
      debugPrint('LibraryTransfer queue not saved: $e');
    }
  }

  static Future<void> _enqueue(List<Track> tracks) async {
    await _load();
    for (final track in tracks) {
      final at = _pending.indexWhere((p) => p.track.id == track.id);
      // Asked for again: its earlier failures no longer count against it.
      if (at != -1) _pending.removeAt(at);
      _failedThisRun.remove(track.id);
      _pending.add((track: track, attempts: 0));
    }
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
    for (final next in List.of(_pending)) {
      if (_running.length >= _concurrency) return;
      if (!waiting(next)) continue;
      if (!_running.add(next.track.id)) continue;
      unawaited(_fetch(next.track));
    }
  }

  static Future<bool> _download(Track track) async {
    await DownloadManager.instance.startDownload(track);
    return AudioDownloadService.isDownloaded(track);
  }

  static Future<void> _fetch(Track track) async {
    var done = false;
    try {
      done = await (downloadWith ?? _download)(track);
    } catch (e) {
      debugPrint('LibraryTransfer download failed: $e');
    }
    final at = _pending.indexWhere((p) => p.track.id == track.id);
    if (at != -1) {
      if (done) {
        _pending.removeAt(at);
      } else {
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
    _pending.clear();
    _running.clear();
    _failedThisRun.clear();
    _loaded = false;
    remaining.value = 0;
    downloadWith = null;
  }
}
