import 'lyrics_engine.dart';
import 'song_reader.dart';

/// Settles what a video is from two readings of it: the catalogue's
/// ([LyricsEngine.identify] — NetEase, and the music Bilibili recognised)
/// and the model's ([SongReader]).
///
/// They fail differently. The catalogue knows which songs exist and whose
/// they are, and takes any word that is also a song's name for one; the
/// model reads a title the way a person does, and knows nothing it was not
/// shown. A name is written into the library when they agree, or when the
/// model is sure on its own; otherwise the video keeps its title.
class SongJudge {
  SongJudge._();

  /// How sure the model has to be to be believed against the catalogue, or
  /// where the catalogue found nothing.
  static const double sure = 0.9;

  static SongIdentity? decide({
    required SongIdentity? catalogue,
    required SongReading? reading,
  }) {
    // No model (not installed, or the question is one it was not taught):
    // the catalogue's answer is all there is.
    if (reading == null) return catalogue;
    final song = reading.song;
    // Not a song, as far as the model can tell.
    if (song == null) return null;

    final sameSong = catalogue != null && _same(catalogue.title, song);
    if (sameSong && _sameNames(_names(catalogue.artist), reading.performers)) {
      return catalogue;
    }
    // (A video whose uploader has no name left — a deleted account — has
    // nobody to credit a cover to.)
    if (reading.confidence < sure ||
        reading.performers.isEmpty ||
        reading.performers.any((name) => name.trim().isEmpty)) {
      return null;
    }
    return SongIdentity(
      // The catalogue's spelling of a name both mean; the video's otherwise.
      title: sameSong ? catalogue.title : song.trim(),
      artist: reading.performers.join(' & '),
      exact: false,
    );
  }

  static List<String> _names(String artist) => [
        for (final name in artist.split(RegExp(r'\s*&\s*')))
          if (name.trim().isNotEmpty) name.trim(),
      ];

  /// One name, however it is written: the same once folded, or one inside
  /// the other (邓紫棋 and G.E.M.邓紫棋).
  static bool _same(String a, String b) {
    final x = SongReader.fold(a), y = SongReader.fold(b);
    if (x.isEmpty || y.isEmpty) return false;
    return x == y ||
        (x.length >= 2 && y.length >= 2 && (x.contains(y) || y.contains(x)));
  }

  static bool _sameNames(List<String> a, List<String> b) {
    if (SongReader.fold(a.join()) == SongReader.fold(b.join())) return true;
    if (a.length != b.length) return false;
    final left = [...b];
    for (final name in a) {
      final at = left.indexWhere((other) => _same(name, other));
      if (at < 0) return false;
      left.removeAt(at);
    }
    return true;
  }
}
