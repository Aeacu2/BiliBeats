/// What Bilibili knows about a video beyond its title: the tags its uploader
/// chose (usually the singer and the song), the description, the zone it was
/// filed under, who uploaded it — and the music Bilibili itself recognised
/// in its audio.
class VideoHints {
  final List<String> tags;
  final String description;
  final String zone;

  /// The UP主, as Bilibili has it now.
  final String owner;

  /// The song Bilibili heard in the video ("视频中的音乐"), or empty. It is
  /// recognised from the sound, so it is there however the title is worded
  /// — and it is whatever music plays, which in a vlog is the backing track.
  final String musicTitle;

  /// Who that song is by: the original artists on a cover, the performers
  /// when the very recording was recognised.
  final List<String> musicArtists;

  const VideoHints({
    this.tags = const [],
    this.description = '',
    this.zone = '',
    this.owner = '',
    this.musicTitle = '',
    this.musicArtists = const [],
  });

  static const VideoHints none = VideoHints();

  bool get isEmpty =>
      tags.isEmpty &&
      description.isEmpty &&
      zone.isEmpty &&
      owner.isEmpty &&
      musicTitle.isEmpty;

  /// Distinguishes two sets of hints for the same title.
  String get key => '${tags.join('\x01')}\x02$description\x02$zone'
      '\x02$musicTitle\x02${musicArtists.join('\x01')}';
}
