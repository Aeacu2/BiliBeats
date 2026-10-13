import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import '../models/video_hints.dart';
import 'audio_player_handler.dart';
import 'bilibili_sdk.dart';
import 'database_service.dart';
import 'lyrics_engine.dart';
import 'song_judge.dart';
import 'song_reader.dart';
import 'song_reader_service.dart';

/// Matches downloads to the songs they are (设置 → 自动匹配歌曲信息).
///
/// A download arrives named like its video — 【4K60帧】周深《大鱼》现场 纯享版 —
/// and credited to whoever uploaded it. [identify] asks the music catalogues
/// which song that is and has the on-device model read the video too;
/// [autoName] applies what the two settle on ([SongJudge]) — name, artist,
/// and the original release's artwork when the video is that very recording
/// — to songs the listener has not named themselves.
class TrackNaming {
  TrackNaming._();

  static bool enabled = true;

  /// The matcher's generation, recorded on every song it names
  /// ([Track.matcher]). Raise it when matching gets better: songs named by
  /// an older generation are then looked at again the next time they play.
  static const int matcher = 5;
  static BiliBeatsAudioHandler? _handler;

  /// Where the evidence comes from; replaced in tests.
  @visibleForTesting
  static Future<VideoHints> Function(String bvid, {int cid}) hintsFor =
      BilibiliSdk.fetchVideoHints;

  @visibleForTesting
  static Future<SongIdentity?> Function(
    String rawTitle, {
    String uploader,
    int durationSeconds,
    String context,
    VideoHints hints,
  }) identifyWith = LyricsEngine.identify;

  /// The model's reading of a video ([SongReaderService.read]); null — as
  /// in tests, and until [init] — leaves the catalogue to answer alone.
  @visibleForTesting
  static Future<SongReading?> Function({
    required String title,
    required String uploader,
    List<String> tags,
    String musicTitle,
    List<String> musicArtists,
    int durationSeconds,
  })? readWith;

  /// Runs the naming of [track] now (what [autoName] queues).
  @visibleForTesting
  static Future<void> nameNow(Track track) => _name(track);

  /// Tried this session; a title the catalogues do not know is not asked
  /// about again until the next launch. (A lookup that failed for lack of a
  /// connection is — see [_name].)
  static final Set<String> _attempted = {};
  static Future<void> _queue = Future.value();

  static Future<void> init(BiliBeatsAudioHandler handler) async {
    _handler = handler;
    readWith ??= SongReaderService.read;
    enabled = await DatabaseService.getPref('autoName') != false;
    // Older downloads are named the first time they play, one at a time —
    // never as a sweep of the whole library.
    // Deleted and downloaded again is a new download: name it afresh.
    DatabaseService.downloadRemovedStream.listen((ids) async {
      _attempted.removeAll(ids);
      final map = await _gaveUp();
      if (ids.any(map.containsKey)) {
        ids.forEach(map.remove);
        await DatabaseService.setPref(_gaveUpPref, map);
      }
    });
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
      Track track, VideoHints hints, String uploader) async {
    final q = _question(track);
    final found = await identifyWith(
      q.title,
      uploader: uploader,
      durationSeconds: track.duration,
      context: q.context,
      hints: hints,
    );
    final read = readWith;
    // One part of a longer video is the catalogue's to name alone: the
    // model was taught whole videos. And what can never be one song (a
    // medley, a compilation) is not for the model to name after one of them.
    if (read == null ||
        q.context.isNotEmpty ||
        LyricsEngine.neverOneSong(q.title, track.duration)) {
      return found;
    }
    // The catalogue could not be asked (offline): nothing to settle yet.
    if (found == null &&
        !LyricsEngine.identitySettled(
          q.title,
          uploader: uploader,
          durationSeconds: track.duration,
          context: q.context,
          hints: hints,
        )) {
      return null;
    }
    final reading = await read(
      title: q.title,
      uploader: uploader,
      tags: hints.tags,
      musicTitle: hints.musicTitle,
      musicArtists: hints.musicArtists,
      durationSeconds: track.duration,
    );
    return SongJudge.decide(catalogue: found, reading: reading);
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

  static const String _gaveUpPref = 'unnamedBy';

  static Future<Map<String, dynamic>> _gaveUp() async {
    final saved = await DatabaseService.getPref(_gaveUpPref);
    return saved is Map ? Map<String, dynamic>.from(saved) : {};
  }

  static Future<bool> _gaveUpOn(String id) async =>
      (await _gaveUp())[id] == matcher;

  /// Remembers, across launches, that this generation of the matcher found
  /// no song for [id].
  static Future<void> _giveUpOn(String id) async {
    final map = await _gaveUp();
    if (map[id] == matcher) return;
    if (map.length >= 2000) map.remove(map.keys.first);
    map[id] = matcher;
    await DatabaseService.setPref(_gaveUpPref, map);
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
    // Switched off while this one waited its turn: ask again if it is
    // ever switched back on.
    if (!enabled) {
      _attempted.remove(track.id);
      return;
    }
    // Only a downloaded song is named, and as the library has it now.
    final before = await _stored(track.id);
    if (before == null || _settled(before)) return;

    final wasNamed = before.isNamed;
    // The catalogues had nothing for it last time, and the matcher is the
    // same one: the answer has not changed.
    if (!wasNamed && await _gaveUpOn(before.id)) return;
    // What can never be one song (a compilation, an hour of music) is known
    // from the title and length alone: nothing to ask Bilibili about.
    if (!wasNamed) {
      final asked = _question(before);
      if (LyricsEngine.neverOneSong(asked.title, before.duration)) return;
    }
    final hints = await hintsFor(before.bvid, cid: before.cid);
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
        // As the library has it now: an edit made during the fetch stands.
        final now = await _stored(track.id);
        if (now == null ||
            now.title != before.title ||
            now.uploader != before.uploader ||
            now.matcher != before.matcher) {
          return;
        }
        await _save(now.copyWith(rawUploader: owner, matcher: 0));
        return;
      }
    }

    // Without all of Bilibili's evidence (a request failed) the answer
    // would rest on the title alone and still be recorded as final.
    if (!hints.complete) {
      _attempted.remove(track.id);
      return;
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
    if (!enabled ||
        stored == null ||
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
      if (found == null && !wasNamed) await _giveUpOn(stored.id);
      if (wasNamed) {
        await _save(stored.copyWith(
          partName: stored.partTitle,
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
      // …and when a re-check finds it is not that recording after all,
      // the release artwork an earlier matcher gave it goes back.
      coverUrl: found.coverUrl ??
          (wasNamed && before.matcher != null && hints.cover.isNotEmpty
              ? hints.cover
              : null),
      named: true,
      partName: stored.partTitle,
      rawUploader: uploader,
      matcher: matcher,
    ));
  }
}
