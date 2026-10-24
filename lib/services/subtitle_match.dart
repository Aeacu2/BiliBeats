import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/lyrics.dart';
import '../models/subtitles.dart';

/// How a video's subtitles line up with a song's lyrics.
///
/// Subtitles are what is heard in the video (Bilibili's speech recognition,
/// or the uploader's own captions); lyrics are what the song says. When
/// enough of one is found in the other, the video sings that song — whoever
/// sings it: a cover has the same words. And the times the two give the same
/// line say how far the lyrics are off against this recording.
///
/// The evidence only ever points one way. Recognition mishears singing,
/// fails on other languages and on heavy mixes, and many videos have no
/// subtitles at all, so a poor match says nothing against a song.
@immutable
class SubtitleMatch {
  /// Subtitle lines found in the lyrics.
  final int matched;

  /// Subtitle lines long enough to compare.
  final int considered;

  /// Share of the song's (distinct) lines heard in the subtitles.
  final double coverage;

  /// Seconds to add to the lyrics' times to meet the video's, when enough
  /// lines agree on one shift; null otherwise (or for untimed lyrics).
  final double? offset;

  /// When, in the video, the first line of the song is heard.
  final double? firstSung;

  const SubtitleMatch({
    required this.matched,
    required this.considered,
    required this.coverage,
    this.offset,
    this.firstSung,
  });

  static const SubtitleMatch none =
      SubtitleMatch(matched: 0, considered: 0, coverage: 0);

  /// Share of what was said or sung that is the song.
  double get precision => considered == 0 ? 0 : matched / considered;

  /// Thresholds, set conservatively until measured on the hold-out
  /// (tool/song_model/subtitles.py): a few lines of a chorus that every
  /// other song shares must not be enough.
  static const int minMatched = 6;
  static const double minPrecision = 0.5;
  static const double minCoverage = 0.3;

  /// The video sings this song.
  bool get confirms =>
      matched >= minMatched &&
      precision >= minPrecision &&
      coverage >= minCoverage;
}

class SubtitleMatcher {
  SubtitleMatcher._();

  static final RegExp _notWord = RegExp(r'[^\p{L}\p{N}]', unicode: true);

  static String normalize(String text) =>
      text.toLowerCase().replaceAll(_notWord, '');

  static Set<String> _grams(String norm) => {
        for (var i = 0; i + 1 < norm.length; i++) norm.substring(i, i + 2),
      };

  /// One line heard as another: most of the shorter one's character pairs
  /// are in the longer. Recognition splits and joins lines differently from
  /// the lyrics, so containment, not equality.
  static bool _same(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return false;
    final small = a.length <= b.length ? a : b;
    final large = identical(small, a) ? b : a;
    final shared = small.where(large.contains).length;
    return shared >= 2 && shared / small.length >= 0.6;
  }

  static SubtitleMatch compare(Subtitles subtitles, List<LyricLine> lyrics,
      {bool timed = true}) {
    final lyricGrams = <({int index, Set<String> grams})>[];
    for (var j = 0; j < lyrics.length; j++) {
      final grams = _grams(normalize(lyrics[j].text));
      if (grams.length >= 2) lyricGrams.add((index: j, grams: grams));
    }
    final distinctLyrics = {
      for (final l in lyricGrams) normalize(lyrics[l.index].text),
    };
    if (lyricGrams.isEmpty) return SubtitleMatch.none;

    var considered = 0;
    final heard = <String>{};
    // Per subtitle line: its start, and every shift a matching lyric line
    // (a chorus matches each time it comes) would imply.
    final candidates = <({double from, List<double> shifts})>[];
    for (final line in subtitles.lines) {
      final grams = _grams(normalize(line.text));
      if (grams.length < 2) continue;
      considered++;
      final shifts = <double>[];
      for (final l in lyricGrams) {
        if (_same(grams, l.grams)) {
          heard.add(normalize(lyrics[l.index].text));
          shifts.add(line.from - lyrics[l.index].time);
        }
      }
      if (shifts.isNotEmpty) candidates.add((from: line.from, shifts: shifts));
    }

    final matched = candidates.length;
    final coverage =
        distinctLyrics.isEmpty ? 0.0 : heard.length / distinctLyrics.length;
    final offset = timed ? _commonShift(candidates) : null;
    return SubtitleMatch(
      matched: matched,
      considered: considered,
      coverage: coverage,
      offset: offset,
      firstSung: candidates.isEmpty ? null : candidates.first.from,
    );
  }

  /// The shift most matched lines agree on (within a second), as their
  /// median; null when too few do for it to be more than chance.
  static double? _commonShift(
      List<({double from, List<double> shifts})> candidates) {
    if (candidates.length < SubtitleMatch.minMatched) return null;
    const window = 1.0;
    double? best;
    var support = 0;
    for (final c in candidates) {
      for (final d in c.shifts) {
        var n = 0;
        for (final other in candidates) {
          if (other.shifts.any((x) => (x - d).abs() <= window)) n++;
        }
        if (n > support) {
          support = n;
          best = d;
        }
      }
    }
    if (best == null ||
        support < SubtitleMatch.minMatched ||
        support * 2 < candidates.length) {
      return null;
    }
    final agreeing = <double>[
      for (final c in candidates)
        c.shifts
            .reduce((a, b) => (a - best!).abs() <= (b - best).abs() ? a : b),
    ].where((x) => (x - best!).abs() <= window).toList()
      ..sort();
    return agreeing[agreeing.length ~/ 2];
  }

  /// The subtitle lines that are lines of [lyrics], in order.
  static List<SubtitleLine> linesOf(
      Subtitles subtitles, List<LyricLine> lyrics) {
    final lyricGrams = [
      for (final l in lyrics)
        if (_grams(normalize(l.text)) case final g when g.length >= 2) g,
    ];
    return [
      for (final line in subtitles.lines)
        if (_grams(normalize(line.text)) case final g
            when g.length >= 2 && lyricGrams.any((l) => _same(g, l)))
          line,
    ];
  }

  /// Whether subtitles read like a song rather than talk, with no lyrics to
  /// compare them to: the uploader's own captions on a music video usually
  /// are the lyrics; machine captions are believed only when lines come
  /// back (a chorus).
  static bool looksSung(Subtitles subtitles) {
    final lines = [
      for (final l in subtitles.lines)
        if (normalize(l.text).length >= 2) normalize(l.text),
    ];
    if (lines.length < 8) return false;
    // Talk runs in long sentences; a song in short lines.
    final average = lines.fold<int>(0, (n, l) => n + l.length) / lines.length;
    if (average > 16) return false;
    if (!subtitles.ai) return true;
    final grams = [for (final l in lines) _grams(l)];
    var repeated = 0;
    for (var i = 0; i < grams.length; i++) {
      for (var j = 0; j < grams.length; j++) {
        if (i != j && _same(grams[i], grams[j])) {
          repeated++;
          break;
        }
      }
    }
    return repeated / lines.length >= 0.2;
  }

  /// Subtitles shown as lyrics: timed against this very video, so with no
  /// shift to make.
  static List<LyricLine> asLyrics(Subtitles subtitles) => [
        for (final l in subtitles.lines)
          LyricLine(time: math.max(0, l.from), text: l.text),
      ];
}
