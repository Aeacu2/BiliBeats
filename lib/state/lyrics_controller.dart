import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/lyrics.dart';
import '../models/track.dart';
import '../services/audio_player_handler.dart';
import '../services/lyrics_engine.dart';
import '../services/lyrics_store.dart';

enum LyricsStatus { loading, ready, empty }

/// What the lyrics view should show for the playing song.
@immutable
class LyricsState {
  final LyricsStatus status;
  final Lyrics lyrics;

  const LyricsState(this.status, [this.lyrics = Lyrics.none]);

  static const loading = LyricsState(LyricsStatus.loading);
  static const empty = LyricsState(LyricsStatus.empty);
}

/// Lyrics for whatever the player is actually playing.
///
/// Follows [BiliBeatsAudioHandler.nowPlaying]; every track change invalidates
/// earlier work (including A→B→A). Everything the listener does to lyrics —
/// choosing, pasting, calibrating — goes through here with the track it is
/// meant for, so it is saved for that song even if playback has moved on,
/// and shown only when that song is the one playing.
class LyricsController {
  LyricsController(this._handler) {
    _handler.nowPlaying.addListener(_onTrackChanged);
    _onTrackChanged();
  }

  final BiliBeatsAudioHandler _handler;

  final ValueNotifier<LyricsState> state = ValueNotifier(LyricsState.empty);

  int _generation = 0;
  String? _trackId;
  String? _nameKey;

  /// Songs the databases had nothing for, this session: no network request
  /// on every replay.
  final Set<String> _misses = {};

  void dispose() {
    ++_generation;
    _handler.nowPlaying.removeListener(_onTrackChanged);
    state.dispose();
  }

  bool _isCurrent(String trackId) => _handler.currentTrack?.id == trackId;

  static String _nameKeyOf(Track track) => '${track.title}\n${track.uploader}';

  /// The song named by the listener (edited title), if they named it.
  static ({String? song, String? artist}) _namedBy(Track track) =>
      track.isNamed
          ? (song: track.title, artist: track.uploader)
          : (song: track.partTitle, artist: null);

  /// The search a person would type for [track].
  static String defaultQuery(Track track) {
    if (track.isNamed) {
      return '${track.uploader} ${track.title}'.trim();
    }
    final parsed = LyricsEngine.cleanTitle(track.rawTitle);
    return '${parsed['artist'] ?? ''} ${parsed['songTitle'] ?? ''}'.trim();
  }

  // ---------------------------------------------------------------------------
  // Deliberate changes
  // ---------------------------------------------------------------------------

  /// Uses [lyrics] for [track] from now on. Shown at once; the returned
  /// future fails if it could not be written to disk.
  Future<void> choose(Track track, Lyrics lyrics) {
    final save = LyricsStore.pin(track.id, lyrics);
    _misses.remove(track.id);
    if (_isCurrent(track.id)) {
      ++_generation; // an automatic lookup in flight must not land on top
      state.value = LyricsState(
        lyrics.isEmpty ? LyricsStatus.empty : LyricsStatus.ready,
        lyrics.copyWith(pinned: true),
      );
    }
    return save;
  }

  /// Shifts [track]'s lyrics by [offset] seconds (absolute, not cumulative).
  Future<void> setOffset(Track track, double offset) {
    final current = LyricsStore.peek(track.id) ??
        (_isCurrent(track.id) ? state.value.lyrics : null);
    if (current == null || current.isEmpty) return Future.value();
    return choose(track, current.copyWith(offset: offset));
  }

  /// Drops whatever [track] has and matches it again automatically.
  Future<void> rematch(Track track) async {
    _misses.remove(track.id);
    final cleared = LyricsStore.clear(track.id);
    if (_isCurrent(track.id)) {
      final generation = ++_generation;
      state.value = LyricsState.loading;
      unawaited(_load(track, generation));
    }
    await cleared;
  }

  // ---------------------------------------------------------------------------
  // Following the player
  // ---------------------------------------------------------------------------

  void _onTrackChanged() {
    final track = _handler.currentTrack;

    if (track == null) {
      ++_generation;
      _trackId = null;
      _nameKey = null;
      state.value = LyricsState.empty;
      return;
    }

    final nameKey = _nameKeyOf(track);
    if (track.id == _trackId) {
      // Same song, edited metadata. A better name deserves a fresh lookup —
      // unless the listener already settled the lyrics themselves.
      if (nameKey == _nameKey || state.value.lyrics.pinned) return;
      _misses.remove(track.id);
    }

    _trackId = track.id;
    _nameKey = nameKey;
    final generation = ++_generation;
    // Never leave the previous song's lyrics visible while loading.
    final known = LyricsStore.peek(track.id);
    state.value = known != null && known.pinned
        ? LyricsState(LyricsStatus.ready, known)
        : LyricsState.loading;
    unawaited(_load(track, generation));
  }

  bool _matches(Lyrics stored, Track track) {
    final storedTitle = stored.title ?? '';
    if (storedTitle.isEmpty) return false;
    final parsed = LyricsEngine.cleanTitle(track.rawTitle)['songTitle'] ?? '';
    return LyricsEngine.isTitleMatching(storedTitle, parsed) ||
        LyricsEngine.isTitleMatching(storedTitle, track.title);
  }

  Future<void> _load(Track track, int generation) async {
    final revision = LyricsStore.revisionOf(track.id);
    bool owns() =>
        generation == _generation &&
        _isCurrent(track.id) &&
        LyricsStore.revisionOf(track.id) == revision;

    void publish(Lyrics lyrics) {
      state.value = lyrics.isEmpty
          ? LyricsState.empty
          : LyricsState(LyricsStatus.ready, lyrics);
    }

    try {
      final stored = await LyricsStore.get(track.id);
      if (!owns()) return;
      if (stored != null &&
          stored.isNotEmpty &&
          (stored.pinned || _matches(stored, track))) {
        publish(stored);
        return;
      }
      if (_misses.contains(track.id)) {
        publish(Lyrics.none);
        return;
      }

      final named = _namedBy(track);
      final fresh = await LyricsEngine.autoFetchLyrics(
        track.rawTitle,
        song: named.song,
        artist: named.artist,
      );
      if (fresh.isEmpty) _misses.add(track.id);
      if (!owns()) return;

      final stands = await LyricsStore.putAutomatic(
        track.id,
        fresh,
        expectedRevision: revision,
      );
      if (!stands || !owns()) return;
      publish(fresh);
    } catch (error, stack) {
      debugPrint('Lyrics load failed for ${track.id}: $error\n$stack');
      if (owns()) publish(Lyrics.none);
    }
  }
}
