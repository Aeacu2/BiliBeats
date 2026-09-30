import 'package:flutter/foundation.dart';

import 'track.dart';

enum LoopMode { off, all, one }

/// Sleep-timer mode. Duration counts down regardless of track changes;
/// end-of-track pauses when the current track finishes.
enum SleepTimerMode { off, endOfTrack, duration }

/// Immutable sleep-timer view for UI. `remaining` is zero when off.
@immutable
class SleepTimerState {
  final SleepTimerMode mode;
  final Duration remaining;

  const SleepTimerState({
    required this.mode,
    this.remaining = Duration.zero,
  });

  static const off = SleepTimerState(mode: SleepTimerMode.off);

  bool get isActive => mode != SleepTimerMode.off;

  @override
  bool operator ==(Object other) =>
      other is SleepTimerState &&
      other.mode == mode &&
      other.remaining.inSeconds == remaining.inSeconds;

  @override
  int get hashCode => Object.hash(mode, remaining.inSeconds);
}

/// What the player is actually queued to play, in play order.
///
/// Derived entirely from the native player's sequence — there is no second,
/// Dart-side queue that could disagree with what is audible. [currentIndex]
/// indexes [tracks] (play order, so shuffle is already applied).
@immutable
class PlaybackQueueSnapshot {
  final List<Track> tracks;
  final int currentIndex;
  final bool isShuffle;
  final LoopMode loopMode;

  PlaybackQueueSnapshot({
    required List<Track> tracks,
    required this.currentIndex,
    required this.isShuffle,
    required this.loopMode,
  }) : tracks = List<Track>.unmodifiable(tracks);

  static final empty = PlaybackQueueSnapshot(
    tracks: const [],
    currentIndex: -1,
    isShuffle: false,
    loopMode: LoopMode.all,
  );

  Track? get currentTrack {
    if (currentIndex < 0 || currentIndex >= tracks.length) return null;
    return tracks[currentIndex];
  }

  /// Queue positions following the current item (no loop wrapping).
  int get upcomingCount {
    if (tracks.isEmpty) return 0;
    if (currentIndex < 0) return tracks.length;
    final remaining = tracks.length - currentIndex - 1;
    return remaining > 0 ? remaining : 0;
  }
}

/// The listening session persisted across process deaths, so a system kill
/// is invisible: the next launch shows the same track, queue and position.
@immutable
class PlaybackSession {
  /// Queue in its natural (unshuffled) order.
  final List<String> trackIds;
  final String? currentId;
  final Duration position;
  final bool shuffle;
  final LoopMode loopMode;

  const PlaybackSession({
    required this.trackIds,
    required this.currentId,
    required this.position,
    required this.shuffle,
    required this.loopMode,
  });

  Map<String, dynamic> toMap() => {
        'trackIds': trackIds,
        'currentId': currentId,
        'positionMs': position.inMilliseconds,
        'shuffle': shuffle,
        'loop': loopMode.name,
      };

  static PlaybackSession? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final ids = raw['trackIds'];
    if (ids is! List) return null;
    final loopName = raw['loop'];
    final positionMs = raw['positionMs'];
    return PlaybackSession(
      trackIds: [for (final id in ids) if (id is String && id.isNotEmpty) id],
      currentId: raw['currentId'] is String ? raw['currentId'] as String : null,
      position: Duration(
        milliseconds: positionMs is num ? positionMs.toInt() : 0,
      ),
      shuffle: raw['shuffle'] == true,
      loopMode: LoopMode.values.firstWhere(
        (m) => m.name == loopName,
        orElse: () => LoopMode.all,
      ),
    );
  }
}
