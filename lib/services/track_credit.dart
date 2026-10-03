import '../models/track.dart';
import 'lyrics_engine.dart';

/// Who performs a track, as shown everywhere a song is listed.
class TrackCredit {
  TrackCredit._();

  static final Map<String, String> _cache = {};

  /// A song that has been named carries its artist in [Track.uploader].
  /// For an untouched download that field is only the UP主, so the video
  /// title is consulted first (【周深】大鱼 → 周深), falling back to the UP主.
  static String artistOf(Track track) {
    if (track.isNamed) return track.uploader.trim();
    final key = '${track.rawTitle}\n${track.uploader}';
    final cached = _cache[key];
    if (cached != null) return cached;
    final parsed = LyricsEngine.cleanTitle(
      track.rawTitle,
      defaultArtist: track.uploader,
    )['artist'];
    final artist =
        (parsed == null || parsed.trim().isEmpty ? track.uploader : parsed)
            .trim();
    if (_cache.length > 2000) _cache.clear();
    return _cache[key] = artist;
  }
}
