import 'package:flutter/foundation.dart';

/// One caption of a video's subtitles, timed against the video itself.
@immutable
class SubtitleLine {
  /// Seconds from the start of the video.
  final double from;
  final double to;
  final String text;

  const SubtitleLine({required this.from, required this.to, required this.text});
}

/// A video part's subtitles: the uploader's own (CC), or Bilibili's
/// speech recognition (AI), which mishears and has no punctuation.
@immutable
class Subtitles {
  /// Bilibili's language code: `zh-CN`, `ai-zh`, `ja`…
  final String language;
  final bool ai;
  final List<SubtitleLine> lines;

  const Subtitles({
    required this.language,
    required this.ai,
    required this.lines,
  });

  bool get isEmpty => lines.isEmpty;
}
