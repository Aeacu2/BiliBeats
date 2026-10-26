import '../models/track.dart';

/// Backing tracks (伴奏): how a video says it is one, and how a song's name
/// says so once it is named — 「大鱼（伴奏）」. The mark is part of the
/// title, so the listener can edit it away like any other part of a name.
class Accompaniment {
  Accompaniment._();

  /// What a title says to mark a backing track: the music without the
  /// voice (去人声, 消音). The opposite — the voice without the music (无伴奏
  /// a cappella, 去伴奏/消伴奏 vocals only) — is not one.
  static final RegExp _mark = RegExp(
    r'(?<![无去消除])伴奏|消音|(?:去|消|除|无)人声|\boff[ -]?vocal\b|'
    r'\bkaraoke\b|\binstrumental\b',
    caseSensitive: false,
  );

  static const String _suffix = '（伴奏）';
  static final RegExp _trailingSuffix = RegExp(r'\s*[（(]伴奏[）)]\s*$');

  /// Whether [title] says it is a backing track.
  static bool marks(String title) => _mark.hasMatch(title);

  /// Whether [track]'s video is a backing track: its title, or (for one
  /// part of a longer video) that part's name, says so.
  static bool isVideo(Track track) =>
      marks(track.rawTitle) || marks(track.partTitle ?? '');

  /// Whether [track] is held as a backing track: its name says so (the
  /// video's title, until the song is named).
  static bool isTrack(Track track) => marks(track.title);

  /// [song] as the name of its backing track, unless it already says so.
  static String titled(String song) => marks(song) ? song : '$song$_suffix';

  /// The song a name is of, without the backing-track mark: what lyrics
  /// are looked up by (a backing track follows the song's lyrics).
  static String songOf(String title) => title.replaceFirst(_trailingSuffix, '');
}
