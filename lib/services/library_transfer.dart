import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/playlist.dart';
import '../models/track.dart';
import 'database_service.dart';
import 'import_download_queue.dart';

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
/// restart; pasting the same text again adds what is missing,
/// but leaves a song that failed as it is — 重试 in download management
/// tries it again.
class LibraryTransfer {
  LibraryTransfer._();

  /// Marks the text and its format. Whatever surrounds it in the clipboard
  /// (a chat app's quote, a line break) is ignored.
  static const String prefix = 'BiliBeats1:';

  static final RegExp _payload =
      RegExp(r'BiliBeats1:([A-Za-z0-9_\-=]+)\.([0-9a-f]{8})');

  // ---------------------------------------------------------------------------
  // Text
  // ---------------------------------------------------------------------------

  static String encode(LibrarySnapshot snapshot) {
    final index = <String, int>{
      for (var i = 0; i < snapshot.tracks.length; i++) snapshot.tracks[i].id: i,
    };
    final json = jsonEncode({
      't': [for (final t in snapshot.tracks) trackMapForTransfer(t)],
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

  /// What a pasted library may expand to: tens of thousands of songs fit
  /// in a few MB, and a few hundred bytes of crafted text could otherwise
  /// expand until the app runs out of memory.
  static const int _maxExpanded = 64 << 20;

  static List<int> _inflate(List<int> packed) {
    final out = _CappedSink(_maxExpanded);
    final input = gzip.decoder.startChunkedConversion(out);
    for (var i = 0; i < packed.length; i += 4096) {
      input.add(packed.sublist(i, math.min(i + 4096, packed.length)));
    }
    input.close();
    return out.bytes.takeBytes();
  }

  /// The library in [text], or null when it holds none that can be read.
  static LibrarySnapshot? decode(String text) {
    final match = _payload.firstMatch(text);
    if (match == null) return null;
    try {
      final body = match.group(1)!;
      if (_seal(body) != match.group(2)) return null;
      final json = jsonDecode(utf8.decode(_inflate(base64Url.decode(body))));
      if (json is! Map) return null;
      final tracks = <Track>[];
      final byIndex = <int, Track>{};
      final seen = <String>{};
      final rawTracks = json['t'] as List? ?? const [];
      for (var i = 0; i < rawTracks.length; i++) {
        final raw = rawTracks[i];
        if (raw is! Map) continue;
        try {
          // Only what export writes: no download address (a pasted one
          // would be fetched as the song), no artwork path of another
          // device.
          final map = Map<String, dynamic>.from(raw)
            ..remove('audioUrl')
            ..remove('loudness');
          if (map['coverUrl'] case final String cover
              when !cover.startsWith('https://') &&
                  !cover.startsWith('http://')) {
            map.remove('coverUrl');
          }
          final track = Track.fromMap(map);
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
    // Grows as playlists are made, so two of the same name become one.
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
        if (same.isNotEmpty) {
          id = same.first.id;
        } else {
          final created = await DatabaseService.createPlaylist(name);
          existing.add(created);
          id = created.id;
        }
      }
      await DatabaseService.addTracksToPlaylist(id, p.tracks);
      merged++;
    }

    final queued = await ImportDownloadQueue.enqueueDownloads(snapshot.tracks);
    return (
      queued: queued,
      present: snapshot.tracks.where((t) => here.contains(t.id)).length,
      playlists: merged,
    );
  }
}

/// Collects decompressed bytes, refusing more than [limit].
class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.limit);

  final int limit;
  final BytesBuilder bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('library text expands too far');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}
