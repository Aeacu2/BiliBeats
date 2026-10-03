import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import 'audio_player_handler.dart';
import 'database_service.dart';
import 'lyrics_engine.dart';

/// Matches downloads to the songs they are (设置 → 自动匹配歌曲信息).
///
/// A download arrives named like its video — 【4K60帧】周深《大鱼》现场 纯享版 —
/// and credited to whoever uploaded it. [identify] asks the music catalogues
/// which song that is; [autoName] applies the answer — name, artist, and the
/// original release's artwork when the video is that very recording — to
/// songs the listener has not named themselves, when (and only when) a
/// catalogue confirms it.
class TrackNaming {
  TrackNaming._();

  static bool enabled = true;
  static BiliBeatsAudioHandler? _handler;

  /// Tried this session; a title the catalogues do not know is not asked
  /// about again until the next launch. (A lookup that failed for lack of a
  /// connection is — see [_name].)
  static final Set<String> _attempted = {};
  static Future<void> _queue = Future.value();

  static Future<void> init(BiliBeatsAudioHandler handler) async {
    _handler = handler;
    enabled = await DatabaseService.getPref('autoName') != false;
    // Older downloads are named the first time they play, one at a time —
    // never as a sweep of the whole library.
    handler.nowPlaying.addListener(() {
      final track = handler.nowPlaying.value;
      if (track != null) autoName(track);
    });
  }

  static Future<void> setEnabled(bool on) async {
    enabled = on;
    await DatabaseService.setPref('autoName', on);
  }

  /// What the lyric databases say [track] is, or null when they do not
  /// recognise it.
  static Future<SongIdentity?> identify(Track track) {
    final q = _question(track);
    return LyricsEngine.identify(
      q.title,
      uploader: track.uploader,
      durationSeconds: track.duration,
      context: q.context,
    );
  }

  /// One part of a multi-part video (an album, a concert) is asked about by
  /// its own name, with the video's title as context for who sings it.
  static ({String title, String context}) _question(Track track) {
    final part = track.partTitle;
    if (part != null) return (title: part, context: track.rawTitle);
    return (
      title: track.rawTitle.isEmpty ? track.title : track.rawTitle,
      context: '',
    );
  }

  /// Names [track] in the background if it still carries its video title.
  static void autoName(Track track) {
    if (!enabled || track.isNamed || !_attempted.add(track.id)) {
      return;
    }
    _queue = _queue.then((_) => _name(track)).catchError((Object error) {
      debugPrint('Auto-naming ${track.id} failed: $error');
    });
  }

  static Future<void> _name(Track track) async {
    final found = await identify(track);
    if (found == null) {
      // Offline is not "unknown": ask again the next time it plays.
      final q = _question(track);
      if (!LyricsEngine.identitySettled(
        q.title,
        uploader: track.uploader,
        durationSeconds: track.duration,
        context: q.context,
      )) {
        _attempted.remove(track.id);
      }
      return;
    }

    // Only a downloaded song still wearing its video title is renamed: the
    // listener may have edited (or deleted) it while the lookup ran.
    final stored = (await DatabaseService.getDownloadedTracks())
        .where((t) => t.id == track.id)
        .firstOrNull;
    if (stored == null || stored.isNamed) return;
    final named = stored.copyWith(
      title: found.title,
      uploader: found.artist,
      // The original release's artwork replaces a video thumbnail.
      coverUrl: found.coverUrl,
      named: true,
    );
    await DatabaseService.updateTrackMetadata(named);
    _handler?.updateTrackMetadata(named);
  }
}
