import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/lyric_line.dart';
import '../models/track.dart';
import '../services/audio_player_handler.dart';
import '../services/database_service.dart';
import '../services/lyrics_engine.dart';

/// Lyrics for whatever the player is actually playing.
///
/// Follows [BiliBeatAudioHandler.nowPlaying]; every track change invalidates
/// earlier work (including A→B→A), and a deliberate choice made in the
/// editor always wins over an automatic lookup finishing late.
class LyricsController {
  LyricsController(this._handler) {
    _handler.nowPlaying.addListener(_onTrackChanged);
    _onTrackChanged();
  }

  final BiliBeatAudioHandler _handler;

  /// Lines for the current track; empty while loading or when none exist.
  final ValueNotifier<List<LyricLine>> lines = ValueNotifier(const []);

  int _generation = 0;
  String? _trackId;

  void dispose() {
    ++_generation;
    _handler.nowPlaying.removeListener(_onTrackChanged);
    lines.dispose();
  }

  /// Publishes [result] immediately when it belongs to the current track.
  void publishIfCurrent(String trackId, LyricsResult result) {
    if (_handler.currentTrack?.id != trackId) return;
    lines.value = result.source == 'none' ? const [] : result.lines;
  }

  void _onTrackChanged() {
    final track = _handler.currentTrack;
    final generation = ++_generation;

    if (track == null) {
      _trackId = null;
      lines.value = const [];
      return;
    }
    // Metadata edits re-notify with the same id; lyrics stay.
    if (track.id == _trackId) return;

    _trackId = track.id;
    // Never leave the previous song's lyrics visible while loading.
    lines.value = const [];
    unawaited(_load(track, generation));
  }

  bool _owns(Track track, int generation) =>
      generation == _generation && _handler.currentTrack?.id == track.id;

  void _publishManual(Track track, int generation) {
    if (!_owns(track, generation)) return;
    final manual = DatabaseService.manualLyricsFor(track.id);
    if (manual != null) {
      lines.value = manual.source == 'none' ? const [] : manual.lines;
    }
  }

  Future<void> _load(Track track, int generation) async {
    final revision = DatabaseService.lyricsRevisionFor(track.id);
    bool owns() =>
        _owns(track, generation) &&
        DatabaseService.lyricsRevisionFor(track.id) == revision;

    try {
      final manual = DatabaseService.manualLyricsFor(track.id);
      if (manual != null) {
        _publishManual(track, generation);
        return;
      }

      final cached = await DatabaseService.getCachedLyrics(track.id);
      if (!owns()) {
        _publishManual(track, generation);
        return;
      }

      final cleanTitle =
          LyricsEngine.cleanTitle(track.rawTitle)['songTitle'] ?? '';

      var cacheValid = false;
      if (cached != null && cached.lines.isNotEmpty && cached.source != 'none') {
        // Pasted/edited lyrics are deliberate; title validation would reject
        // them (a paste is cached as 「自定义歌词」).
        if (cached.source == 'user' || cached.source == 'current') {
          cacheValid = true;
        } else {
          final cachedTitle = cached.songTitle ?? '';
          cacheValid = cachedTitle.isNotEmpty &&
              LyricsEngine.isTitleMatching(cachedTitle, cleanTitle);
        }
      }
      if (cacheValid) {
        lines.value = cached!.lines;
        return;
      }

      final fresh = await LyricsEngine.autoFetchLyrics(track.rawTitle);
      if (!owns()) {
        _publishManual(track, generation);
        return;
      }

      final accepted = await DatabaseService.cacheAutomaticLyrics(
        track.id,
        fresh,
        expectedRevision: revision,
      );
      if (!accepted || !owns()) {
        _publishManual(track, generation);
        return;
      }

      // "Not found" carries placeholder lines; an empty list lets the view
      // offer search/paste instead.
      lines.value = fresh.source == 'none' ? const [] : fresh.lines;
    } catch (error, stack) {
      debugPrint('Lyrics load failed for ${track.id}: $error\n$stack');
      _publishManual(track, generation);
    }
  }
}
