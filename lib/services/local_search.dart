import '../models/track.dart';

/// In-memory search over the downloaded library.
///
/// Instant (runs on every keystroke), offline, and forgiving about the way
/// Bilibili titles are written:
///  * case- and width-insensitive (`ＧＥＭ` finds `G.E.M.`),
///  * ignores spaces and punctuation inside words (`光年之外` finds
///    `光年 之外`, `gem` finds `G.E.M.`),
///  * every space-separated term must match somewhere — title, artist/UP主
///    or the original video title — so `周深 逆光` narrows rather than widens.
///
/// Ranking puts title hits ahead of artist hits, and prefix hits ahead of
/// mid-string ones; ties keep library order (most recently downloaded
/// first).
class LocalSearch {
  LocalSearch._();

  static List<Track> search(Iterable<Track> tracks, String query) {
    final terms = query
        .split(RegExp(r'\s+'))
        .map(normalize)
        .where((term) => term.isNotEmpty)
        .toList();
    if (terms.isEmpty) return const [];

    final scored = <({Track track, int score, int order})>[];
    var order = 0;
    for (final track in tracks) {
      final score = _score(track, terms);
      if (score > 0) scored.add((track: track, score: score, order: order));
      order++;
    }

    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.order.compareTo(b.order);
    });
    return [for (final hit in scored) hit.track];
  }

  /// 0 when some term matches nothing.
  static int _score(Track track, List<String> terms) {
    final title = normalize(track.title);
    final artist = normalize(track.uploader);
    final raw = normalize(track.rawTitle);

    var total = 0;
    for (final term in terms) {
      var best = 0;
      if (title == term) {
        best = 100;
      } else if (title.startsWith(term)) {
        best = 70;
      } else if (title.contains(term)) {
        best = 50;
      }
      if (best < 40) {
        if (artist == term || artist.startsWith(term)) {
          best = 40;
        } else if (artist.contains(term)) {
          best = 30;
        }
      }
      if (best == 0 && raw.contains(term)) best = 15;
      if (best == 0) return 0;
      total += best;
    }
    return total;
  }

  static final RegExp _separators =
      RegExp(r'''[\s\-_.,，。·・•、/\\|:：;；'"“”‘’!！?？()（）\[\]【】《》<>「」『』~～]''');

  /// Lowercase, full-width ASCII folded to half-width, separators removed.
  static String normalize(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      var code = rune;
      if (code == 0x3000) {
        code = 0x20; // ideographic space
      } else if (code >= 0xFF01 && code <= 0xFF5E) {
        code -= 0xFEE0; // full-width ASCII block
      }
      buffer.writeCharCode(code);
    }
    return buffer.toString().toLowerCase().replaceAll(_separators, '');
  }
}
