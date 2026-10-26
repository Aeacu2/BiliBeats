import 'package:flutter/foundation.dart';

/// How often a song has been listened to, and when last.
@immutable
class PlayStat {
  final int count;
  final DateTime last;

  const PlayStat({required this.count, required this.last});

  /// A play counts once this much of it has been heard: half the song, or
  /// four minutes of a long one (as scrobblers count). A song skipped after
  /// a few seconds says nothing about liking it.
  static Duration needed(Duration length) {
    const cap = Duration(minutes: 4);
    final half = length ~/ 2;
    if (length <= Duration.zero) return const Duration(seconds: 30);
    return half < cap ? half : cap;
  }

  Map<String, dynamic> toMap() =>
      {'n': count, 'at': last.millisecondsSinceEpoch};

  static PlayStat? fromMap(Object? map) {
    if (map is! Map) return null;
    final n = map['n'];
    final at = map['at'];
    if (n is! int || n <= 0 || at is! int) return null;
    return PlayStat(count: n, last: DateTime.fromMillisecondsSinceEpoch(at));
  }
}
