import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/lyrics.dart';
import '../models/subtitles.dart';
import '../models/track.dart';
import '../services/audio_player_handler.dart';
import '../services/bilibili_sdk.dart';
import '../services/lyrics_engine.dart';
import '../services/lyrics_store.dart';
import '../services/subtitle_match.dart';

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
  LyricsController(
    this._handler, {
    Future<Subtitles?> Function(String bvid, {int cid})? subtitles,
  }) : _subtitles = subtitles ?? BilibiliSdk.fetchSubtitles {
    _handler.nowPlaying.addListener(_onTrackChanged);
    _onTrackChanged();
  }

  final BiliBeatsAudioHandler _handler;

  /// The playing video's subtitles (when logged in to Bilibili): lyrics of
  /// last resort, and the clock automatic lyrics are set against.
  final Future<Subtitles?> Function(String bvid, {int cid}) _subtitles;

  final ValueNotifier<LyricsState> state = ValueNotifier(LyricsState.empty);

  int _generation = 0;
  String? _trackId;
  String? _nameKey;

  /// Songs the databases had nothing for, this session: no network request
  /// on every replay.
  final Map<String, String> _misses = {};

  void dispose() {
    ++_generation;
    _handler.nowPlaying.removeListener(_onTrackChanged);
    state.dispose();
  }

  bool _isCurrent(String trackId) => _handler.currentTrack?.id == trackId;

  static String _nameKeyOf(Track track) => '${track.title}\n${track.uploader}';

  /// The song named by the listener (edited title), if they named it.
  static ({String? song, String? artist}) _namedBy(Track track) => track.isNamed
      ? (song: track.title, artist: track.uploader)
      : (song: track.partTitle, artist: null);

  /// The search a person would type for [track].
  static String defaultQuery(Track track) {
    if (track.isNamed) {
      return '${track.uploader} ${track.title}'.trim();
    }
    final parsed = LyricsEngine.cleanTitle(track.rawTitle);
    // A part of a multi-part video is the song its own name says.
    final song = track.partTitle ?? parsed['songTitle'] ?? '';
    return '${parsed['artist'] ?? ''} $song'.trim();
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
    final previous = LyricsStore.peek(track.id);
    final cleared = LyricsStore.clear(track.id);
    Future<void>? loading;
    if (_isCurrent(track.id)) {
      final generation = ++_generation;
      state.value = LyricsState.loading;
      loading = _load(track, generation);
    }
    await cleared;
    // Lyrics the listener settled are not thrown away for nothing: when
    // the new lookup finds none, they come back.
    if (loading != null &&
        previous != null &&
        previous.pinned &&
        previous.isNotEmpty) {
      await loading;
      final found = LyricsStore.peek(track.id);
      if (found == null || found.isEmpty) await choose(track, previous);
    }
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
      _trackId = track.id;
      _nameKey = nameKey;
      final generation = ++_generation;
      state.value = LyricsState.loading;
      // Lyrics found under the old name say nothing about the new one.
      unawaited(_load(track, generation, renamed: true));
      return;
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
    // Judged the way the lookup accepted it (subtitle stripped: "问 (Live)"
    // is 问), and against the song's name once it has one.
    if (track.isNamed) {
      return LyricsEngine.matchesSongQuery(storedTitle, track.title);
    }
    final parsed = track.partTitle ??
        LyricsEngine.cleanTitle(track.rawTitle)['songTitle'] ??
        '';
    return LyricsEngine.matchesSongQuery(storedTitle, parsed) ||
        LyricsEngine.matchesSongQuery(storedTitle, track.title);
  }

  /// What the video's subtitles say, as lyrics, when they read like a
  /// song: timed against this very video. Null when there are none.
  Future<Lyrics?> _fromSubtitles(Track track) async {
    final subtitles = await _subtitles(track.bvid, cid: track.cid);
    if (subtitles == null || !SubtitleMatcher.looksSung(subtitles)) return null;
    return Lyrics(
      source: 'bilibili',
      title: track.isNamed
          ? track.title
          : track.partTitle ??
              LyricsEngine.cleanTitle(track.rawTitle)['songTitle'] ??
              track.title,
      artist: 'B站字幕',
      lines: SubtitleMatcher.asLyrics(subtitles),
    );
  }

  /// Library lyrics are timed for the record; the video may run ahead of
  /// it or behind (an intro, a live take). Where the video's subtitles
  /// hear enough of the lyrics at one steady shift, the lyrics are moved
  /// by it — as the automatic answer, which a calibration still overrides.
  Future<void> _setAgainstVideo(Track track, Lyrics lyrics, int revision,
      bool Function() owns) async {
    if (!lyrics.synced || lyrics.source == 'bilibili') return;
    final subtitles = await _subtitles(track.bvid, cid: track.cid);
    if (subtitles == null || subtitles.isEmpty) return;
    final match = SubtitleMatcher.compare(subtitles, lyrics.lines);
    final offset = match.offset;
    if (!match.confirms || offset == null) return;
    final rounded = (offset * 100).round() / 100;
    if ((rounded - lyrics.offset).abs() < 0.3) return;
    final shifted = lyrics.copyWith(offset: rounded);
    final stands = await LyricsStore.putAutomatic(track.id, shifted,
        expectedRevision: revision);
    if (stands && owns()) {
      state.value = LyricsState(LyricsStatus.ready, shifted);
    }
  }

  Future<void> _load(Track track, int generation,
      {bool renamed = false}) async {
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
          (stored.pinned || (!renamed && _matches(stored, track)))) {
        publish(stored);
        return;
      }
      if (_misses[track.id] == _nameKeyOf(track)) {
        publish(Lyrics.none);
        return;
      }

      final named = _namedBy(track);
      final failuresBefore = LyricsEngine.httpFailures;
      var fresh = await LyricsEngine.autoFetchLyrics(
        track.rawTitle,
        song: named.song,
        artist: named.artist,
        durationSeconds: track.duration,
      );
      // "Nothing found" is only remembered when every provider answered:
      // a lookup made offline is tried again the next time the song plays.
      final asked = LyricsEngine.httpFailures == failuresBefore;
      if (fresh.isEmpty && asked) {
        fresh = await _fromSubtitles(track) ?? fresh;
      }
      if (fresh.isEmpty && asked) _misses[track.id] = _nameKeyOf(track);
      if (!owns()) return;
      if (fresh.isEmpty && !asked) {
        // Could not ask: what is stored stays, and shows if it fits.
        publish(
            stored != null && _matches(stored, track) ? stored : Lyrics.none);
        return;
      }

      final stands = await LyricsStore.putAutomatic(
        track.id,
        fresh,
        expectedRevision: revision,
      );
      if (!stands || !owns()) return;
      publish(fresh);
      await _setAgainstVideo(track, fresh, revision, owns);
    } catch (error, stack) {
      debugPrint('Lyrics load failed for ${track.id}: $error\n$stack');
      if (owns()) publish(Lyrics.none);
    }
  }
}
