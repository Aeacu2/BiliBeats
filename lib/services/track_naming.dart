import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import '../models/video_hints.dart';
import 'audio_player_handler.dart';
import 'bilibili_sdk.dart';
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

  /// The matcher's generation, recorded on every song it names
  /// ([Track.matcher]). Raise it when matching gets better: songs named by
  /// an older generation are then looked at again the next time they play.
  static const int matcher = 4;
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

  /// What the music catalogues say [track] is, or null when they do not
  /// recognise it.
  static Future<SongIdentity?> identify(Track track) async {
    final hints = await BilibiliSdk.fetchVideoHints(track.bvid, cid: track.cid);
    return _ask(track, hints, _uploaderOf(track, hints));
  }

  /// The UP主. Once a song is named, [Track.uploader] is its artist; the
  /// uploader is then the one recorded at naming or, for songs named before
  /// that was kept, whoever Bilibili says owns the video.
  static String _uploaderOf(Track track, VideoHints hints) =>
      track.rawUploader ??
      (track.isNamed && hints.owner.isNotEmpty ? hints.owner : track.uploader);

  static Future<SongIdentity?> _ask(
      Track track, VideoHints hints, String uploader) {
    final q = _question(track);
    return LyricsEngine.identify(
      q.title,
      uploader: uploader,
      durationSeconds: track.duration,
      context: q.context,
      hints: hints,
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

  /// Whether the matcher has nothing more to say about [track]: the listener
  /// named it, or this generation of the matcher already did.
  @visibleForTesting
  static bool settled(Track track) => _settled(track);

  static bool _settled(Track track) =>
      track.isNamed && (track.matcher == 0 || track.matcher == matcher);

  /// Names [track] in the background if it still carries its video title,
  /// or was named by an earlier generation of the matcher.
  static void autoName(Track track) {
    if (!enabled || _settled(track) || !_attempted.add(track.id)) {
      return;
    }
    _queue = _queue.then((_) => _name(track)).catchError((Object error) {
      debugPrint('Auto-naming ${track.id} failed: $error');
    });
  }

  static Future<Track?> _stored(String id) async =>
      (await DatabaseService.getDownloadedTracks())
          .where((t) => t.id == id)
          .firstOrNull;

  static Future<void> _save(Track track) async {
    await DatabaseService.updateTrackMetadata(track);
    _handler?.updateTrackMetadata(track);
  }

  static Future<void> _name(Track track) async {
    // Only a downloaded song is named, and as the library has it now.
    final before = await _stored(track.id);
    if (before == null || _settled(before)) return;

    final hints =
        await BilibiliSdk.fetchVideoHints(before.bvid, cid: before.cid);
    final wasNamed = before.isNamed;
    // Named before [Track.matcher] was recorded: by the listener, or by the
    // first matcher — which credited the UP主 whenever it could not read the
    // singer. Only that mistake is worth a second look; any other artist
    // stands as the listener's.
    final legacy = wasNamed && before.matcher == null;
    if (legacy) {
      // Offline: who uploaded it is not known yet. Ask again next time.
      if (hints.owner.isEmpty && before.rawUploader == null) {
        _attempted.remove(track.id);
        return;
      }
      final owner = before.rawUploader ?? hints.owner;
      if (before.uploader.trim() != owner.trim()) {
        await _save(before.copyWith(rawUploader: owner, matcher: 0));
        return;
      }
    }

    final uploader = _uploaderOf(before, hints);
    final found = await _ask(before, hints, uploader);
    final q = _question(before);
    final settled = LyricsEngine.identitySettled(
      q.title,
      uploader: uploader,
      durationSeconds: before.duration,
      context: q.context,
      hints: hints,
    );
    if (found == null && !settled) {
      // Offline is not "unknown": ask again the next time it plays.
      _attempted.remove(track.id);
      return;
    }

    // The listener may have edited (or deleted) it while the lookup ran.
    final stored = await _stored(track.id);
    if (stored == null ||
        stored.title != before.title ||
        stored.uploader != before.uploader ||
        stored.matcher != before.matcher ||
        stored.named != before.named) {
      return;
    }

    // Nothing better to offer: a named song keeps its name, and is not
    // asked about again until the matcher improves.
    final same = found != null &&
        found.title == stored.title &&
        found.artist == stored.uploader;
    final noBetter =
        found == null || same || (legacy && found.artist.trim() == uploader);
    if (noBetter) {
      if (wasNamed) {
        await _save(stored.copyWith(
          rawUploader: uploader,
          matcher: legacy ? 0 : matcher,
        ));
      }
      return;
    }

    await _save(stored.copyWith(
      title: found.title,
      uploader: found.artist,
      // The original release's artwork replaces a video thumbnail.
      coverUrl: found.coverUrl,
      named: true,
      rawUploader: uploader,
      matcher: matcher,
    ));
  }
}
