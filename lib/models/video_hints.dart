/// What Bilibili knows about a video beyond its title: the tags its uploader
/// chose (usually the singer and the song), the description, the zone it was
/// filed under, and who uploaded it.
class VideoHints {
  final List<String> tags;
  final String description;
  final String zone;

  /// The UP主, as Bilibili has it now.
  final String owner;

  const VideoHints({
    this.tags = const [],
    this.description = '',
    this.zone = '',
    this.owner = '',
  });

  static const VideoHints none = VideoHints();

  bool get isEmpty =>
      tags.isEmpty && description.isEmpty && zone.isEmpty && owner.isEmpty;

  /// Distinguishes two sets of hints for the same title.
  String get key => '${tags.join('\x01')}\x02$description\x02$zone';
}
