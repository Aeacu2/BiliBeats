import 'package:flutter/foundation.dart';

class LyricLine {
  final double time; // in seconds
  final String text;
  final String? translation;

  const LyricLine({
    required this.time,
    required this.text,
    this.translation,
  });

  Map<String, dynamic> toMap() {
    return {
      'time': time,
      'text': text,
      'translation': translation,
    };
  }

  factory LyricLine.fromMap(Map<String, dynamic> map) {
    return LyricLine(
      time: (map['time'] as num).toDouble(),
      text: map['text'] ?? '',
      translation: map['translation'],
    );
  }
}

/// One song's lyrics, as found, chosen or written.
///
/// Timing corrections are kept apart from the lines ([offset]) so calibrating
/// never rewrites the text and can always be redone or undone.
@immutable
class Lyrics {
  /// Where the lines came from: `netease`, `lrclib`, `user` (pasted or
  /// edited), or `none`.
  final String source;

  /// The provider's own name for the song, used to recognise a stale match.
  final String? title;
  final String? artist;
  final List<LyricLine> lines;

  /// Seconds added to every line's time when displayed.
  final double offset;

  /// The listener picked or wrote these. Pinned lyrics are never replaced by
  /// an automatic lookup and never evicted from the store.
  final bool pinned;

  const Lyrics({
    required this.source,
    required this.lines,
    this.title,
    this.artist,
    this.offset = 0.0,
    this.pinned = false,
  });

  static const Lyrics none = Lyrics(source: 'none', lines: []);

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;

  /// False for plain text without timestamps: shown as a readable page, with
  /// no highlight to follow and nothing to seek to.
  bool get synced => lines.length > 1 && lines.last.time > 0;

  /// Text-only identity, for telling two candidates apart.
  String get fingerprint => lines
      .map((line) => line.text.trim())
      .where((text) => text.isNotEmpty)
      .join('\n');

  Lyrics copyWith({
    String? source,
    List<LyricLine>? lines,
    double? offset,
    bool? pinned,
  }) {
    return Lyrics(
      source: source ?? this.source,
      title: title,
      artist: artist,
      lines: lines ?? this.lines,
      offset: offset ?? this.offset,
      pinned: pinned ?? this.pinned,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'source': source,
      'songTitle': title,
      'artistName': artist,
      'lines': lines.map((l) => l.toMap()).toList(),
      if (offset != 0.0) 'offset': offset,
      if (pinned) 'pinned': true,
    };
  }

  /// Reads both this version's files and older ones, where a deliberate
  /// choice was only recognisable by its source (`user` / `current`).
  factory Lyrics.fromMap(Map<String, dynamic> map) {
    final rawLines = map['lines'] as List? ?? const [];
    var source = map['source'] as String? ?? 'none';
    final legacyPinned = source == 'user' || source == 'current';
    if (source == 'current') source = 'user';
    final offset = map['offset'];
    return Lyrics(
      source: source,
      title: map['songTitle'] as String?,
      artist: map['artistName'] as String?,
      lines: rawLines
          .map((l) => LyricLine.fromMap(Map<String, dynamic>.from(l as Map)))
          .toList(),
      offset: offset is num ? offset.toDouble() : 0.0,
      pinned: map['pinned'] == true || legacyPinned,
    );
  }
}
