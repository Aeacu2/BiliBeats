import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import 'audio_player_handler.dart';
import 'database_service.dart';
import 'lyrics_engine.dart';

/// Turns raw video titles into song names.
///
/// A download arrives named like its video — 【4K60帧】周深《大鱼》现场 纯享版 —
/// and credited to whoever uploaded it. [identify] asks the lyric databases
/// which song that is; [autoName] applies the answer to songs the listener
/// has not named themselves, when (and only when) a database confirms it —
/// along with the original release's artwork when the video is that very
/// recording.
class TrackNaming {
  TrackNaming._();

  static bool enabled = true;
  static BiliBeatAudioHandler? _handler;

  /// Tried this session; an unconfirmed title is not asked about again
  /// until the next launch.
  static final Set<String> _attempted = {};
  static Future<void> _queue = Future.value();

  static Future<void> init(BiliBeatAudioHandler handler) async {
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
    return LyricsEngine.identify(
      track.rawTitle.isEmpty ? track.title : track.rawTitle,
      uploader: track.uploader,
      durationSeconds: track.duration,
    );
  }

  /// Names [track] in the background if it still carries its video title.
  static void autoName(Track track) {
    if (!enabled ||
        track.title != track.rawTitle ||
        !_attempted.add(track.id)) {
      return;
    }
    _queue = _queue.then((_) => _name(track)).catchError((Object error) {
      debugPrint('Auto-naming ${track.id} failed: $error');
    });
  }

  static Future<void> _name(Track track) async {
    final found = await identify(track);
    if (found == null) return;

    // Only a downloaded song still wearing its video title is renamed: the
    // listener may have edited (or deleted) it while the lookup ran.
    final stored = (await DatabaseService.getDownloadedTracks())
        .where((t) => t.id == track.id)
        .firstOrNull;
    if (stored == null || stored.title != stored.rawTitle) return;
    final named = stored.copyWith(
      title: found.title,
      uploader: found.artist,
      // The original release's artwork replaces a video thumbnail.
      coverUrl: found.coverUrl,
    );
    if (named.title == stored.title &&
        named.uploader == stored.uploader &&
        named.coverUrl == stored.coverUrl) {
      return;
    }
    await DatabaseService.updateTrackMetadata(named);
    _handler?.updateTrackMetadata(named);
  }
}
