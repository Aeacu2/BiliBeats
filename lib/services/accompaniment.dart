import '../models/track.dart';
import 'lyrics_engine.dart';

/// Backing tracks (伴奏): how a video says it is one, and how the library
/// holds one — credited to 伴奏 instead of a singer. They then gather under
/// 伴奏 among the artists (where they can be played on their own) and stay
/// out of the singers' own lists. The credit is an ordinary artist name: the
/// listener can edit it away like any other.
class Accompaniment {
  Accompaniment._();

  /// The artist a backing track is credited to.
  static const String artist = '伴奏';

  /// What a title says to mark a backing track: the music without the
  /// voice (去人声, 消音). The opposite — the voice without the music (无伴奏
  /// a cappella, 去伴奏/消伴奏 vocals only) — is not one.
  static final RegExp _mark = RegExp(
    r'(?<![无去消除])伴奏|消音|(?:去|消|除|无)人声|\boff[ -]?vocal\b|'
    r'\bkaraoke\b|\binstrumental\b',
    caseSensitive: false,
  );

  /// A bracketed backing-track mark at the end of a name: 「大鱼 (伴奏版)」,
  /// 「Lemon (Off Vocal)」.
  static final RegExp _trailingMark = RegExp(
    r'\s*[（(\[【][^（()）\[\]【】]*(?:伴奏|off[ -]?vocal|karaoke|instrumental)'
    r'[^（()）\[\]【】]*[)）\]】]\s*$',
    caseSensitive: false,
  );

  /// Whether [title] says it is a backing track.
  static bool marks(String title) => _mark.hasMatch(title);

  /// Whether [track]'s video is a backing track: its title, or (for one
  /// part of a longer video) that part's name, says so.
  static bool isVideo(Track track) =>
      marks(track.rawTitle) || marks(track.partTitle ?? '');

  /// The singer [track]'s video title names (「【伴奏】周深《大鱼》」: 周深), read
  /// with the backing-track words left out — the parser would otherwise
  /// take 【伴奏】 for the artist. Null when it names none.
  static String? singerIn(Track track) {
    final singer =
        LyricsEngine.cleanTitle(readable(track.rawTitle))['artist']?.trim() ??
            '';
    return singer.isEmpty || isCredit(singer) ? null : singer;
  }

  /// [title] with its backing-track words left out, for the title parser.
  static String readable(String title) => title.replaceAll(_mark, ' ');

  /// Whether [name] is the backing-track credit rather than a singer.
  static bool isCredit(String name) => name.trim() == artist;

  /// [title] without a bracketed backing-track mark at its end: the song's
  /// name, the credit already saying what it is.
  static String songOf(String title) {
    final song = title.replaceFirst(_trailingMark, '').trim();
    return song.isEmpty ? title : song;
  }
}
