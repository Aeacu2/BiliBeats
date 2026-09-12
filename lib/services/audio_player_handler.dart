import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../models/track.dart';
import 'audio_download_service.dart';
import 'database_service.dart';

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

  bool get isActive => mode != SleepTimerMode.off;
}

/// An immutable view of the handler's logical playback queue.
///
/// Tracks are already immutable. The list is copied and made unmodifiable
/// so widgets cannot mutate the handler's queue.
///
/// Order is playback order, including shuffle.
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

  Track? get currentTrack {
    if (currentIndex < 0 || currentIndex >= tracks.length) {
      return null;
    }

    return tracks[currentIndex];
  }

  /// Queue positions following the current item.
  ///
  /// This deliberately does not synthesize loop wrapping or repeat-one
  /// entries. Loop behavior is described separately by [loopMode].
  int get upcomingCount {
    if (tracks.isEmpty) return 0;
    if (currentIndex < 0) return tracks.length;

    final remaining = tracks.length - currentIndex - 1;
    return remaining > 0 ? remaining : 0;
  }
}

/// Playback engine built on a native just_audio queue.
///
/// Architecture (download-then-play):
///  * Every track is fully downloaded to disk before it plays; the native
///    player (ExoPlayer on Android, AVPlayer on iOS) reads the local file
///    directly. No loopback proxy, no Dart byte-forwarding, no ATS issues.
///  * A [ja.Playlist] holds a small window of downloaded files
///    so the OS can transition to the next track gaplessly. The next track is
///    pre-downloaded in the background as soon as the current one starts.
///  * Loop/shuffle/advance logic lives in Dart; the native queue is only a
///    sliding window that mirrors the logical playlist around [_currentIndex].
class BiliBeatAudioHandler extends BaseAudioHandler with SeekHandler {
  final ja.AudioPlayer _player;
  // ignore: deprecated_member_use
  final ja.ConcatenatingAudioSource _queueSource =
      // ignore: deprecated_member_use
      ja.ConcatenatingAudioSource(children: []);

  /// The playlist in the order it is currently played (shuffled or not).
  final List<Track> _playlist = [];

  /// The playlist in its natural order, kept so turning shuffle off restores
  /// exactly what the user had before.
  final List<Track> _naturalOrder = [];

  int _currentIndex = -1;

  /// Logical playlist index of `_queueSource` child 0. Player index `i`
  /// therefore maps to logical index `_queueBaseIndex + i`.
  int _queueBaseIndex = 0;

  bool _isPlaying = false;
  LoopMode _loopMode = LoopMode.all;
  bool _isShuffle = false;
  bool _isRebuilding = false;
  String? _prefetchingId;

  /// Number of open surfaces that have asked playback not to move on by itself
  /// (the lyrics panel and the 信息/歌词 editor). A counter rather than a flag
  /// so the editor closing over the lyrics panel does not release the panel's
  /// hold. Repeat-one is unaffected — it repeats the same track, which is what
  /// the user asked for in that mode.
  int _autoAdvanceHolds = 0;

  /// Guards against overlapping [_startCurrent] runs when the user taps
  /// next/previous faster than a track can be prepared.
  int _startToken = 0;

  /// Serializes all application-side logical queue changes, native source
  /// mutations, indexed seeks, and queue re-anchoring. Audio downloads run
  /// outside this gate so a slow download cannot block a newer selection,
  /// Pause, or Stop. The gate serializes Dart operations; it does not freeze
  /// native playback, which is reconciled from source tags.
  Future<void> _queueGate = Future<void>.value();

  /// Invalidates prefetch plans after the queue/order changes.
  int _queueRevision = 0;

  /// A track start whose selection is announced but whose source may not be
  /// installed yet. While set, native-index reconciliation is suppressed:
  /// the announced selection and the installed source may differ.
  int? _pendingStartToken;

  /// Prefetch ownership: an old prefetch's cleanup cannot clear a newer
  /// prefetch's state.
  int _prefetchSerial = 0;
  int? _prefetchOwner;

  /// Explicit transport intent, independent of native preparation events.
  /// Only `playerStateStream` writes normal playing state.
  bool _playRequested = false;
  int _transportToken = 0;

  bool get _queueTransitioning => _isRebuilding || _pendingStartToken != null;

  final StreamController<PlaybackQueueSnapshot> _queueSnapshotController =
      StreamController<PlaybackQueueSnapshot>.broadcast();

  PlaybackQueueSnapshot _queueSnapshot = PlaybackQueueSnapshot(
    tracks: const [],
    currentIndex: -1,
    isShuffle: false,
    loopMode: LoopMode.all,
  );

  /// Read immediately when attaching a UI.
  PlaybackQueueSnapshot get queueSnapshot => _queueSnapshot;

  /// Subsequent authoritative snapshots.
  ///
  /// Consumers should subscribe and use [queueSnapshot] as initial data.
  /// This controller follows the handler's existing process-lifetime stream
  /// ownership: do not close it in `stop()`. Stopping playback does not
  /// dispose the handler.
  Stream<PlaybackQueueSnapshot> get queueSnapshotStream =>
      _queueSnapshotController.stream;

  /// Sleep timer state. Session-only: armed in the playback layer (never a
  /// screen timer), cleared by stop, cancel, firing, or replacement.
  SleepTimerMode _sleepMode = SleepTimerMode.off;
  DateTime? _sleepDeadline;
  String? _sleepTrackId;
  int _sleepSerial = 0;
  Timer? _sleepTimer;
  Timer? _sleepTicker;
  final StreamController<SleepTimerState> _sleepTimerController =
      StreamController<SleepTimerState>.broadcast();
  SleepTimerState _sleepTimerState =
      const SleepTimerState(mode: SleepTimerMode.off);

  /// Read immediately when attaching a UI.
  SleepTimerState get sleepTimerState => _sleepTimerState;

  /// Countdown updates (1s cadence) while armed.
  Stream<SleepTimerState> get sleepTimerStream =>
      _sleepTimerController.stream;

  bool _sameTrackInstances(
    List<Track> previous,
    List<Track> next,
  ) {
    if (previous.length != next.length) return false;

    for (var i = 0; i < previous.length; i++) {
      // Track.operator == compares only id.
      //
      // Identity comparison also detects edited metadata represented by
      // a new Track instance with the same id.
      if (!identical(previous[i], next[i])) return false;
    }

    return true;
  }

  /// Publish only from the queue gate's finalizer, after reconciliation.
  ///
  /// This describes the logical queue and logical selection. It does not
  /// claim that a selected track has finished preparing or is audible.
  void _publishQueueSnapshot() {
    final previous = _queueSnapshot;

    final tracksChanged = !_sameTrackInstances(previous.tracks, _playlist);

    final selectionChanged = previous.currentIndex != _currentIndex;

    final modeChanged =
        previous.isShuffle != _isShuffle || previous.loopMode != _loopMode;

    if (!tracksChanged && !selectionChanged && !modeChanged) {
      return;
    }

    final next = PlaybackQueueSnapshot(
      tracks: _playlist,
      currentIndex: _currentIndex,
      isShuffle: _isShuffle,
      loopMode: _loopMode,
    );

    // Assign before emitting so synchronous reads see the newest state.
    _queueSnapshot = next;

    // audio_service expects the same logical order used by queueIndex and
    // skipToQueueItem. Never publish the small native prefetch window here.
    if (tracksChanged) {
      queue.add(
        List<MediaItem>.unmodifiable(
          next.tracks.map(_mediaItemForTrack),
        ),
      );
    }

    _queueSnapshotController.add(next);
  }

  /// Never call this from inside another _withQueueGate callback.
  /// Locked helpers below deliberately do not reacquire the gate.
  Future<T> _withQueueGate<T>(Future<T> Function() action) {
    final result = _queueGate.then<T>((_) async {
      _isRebuilding = true;

      try {
        return await action();
      } finally {
        _isRebuilding = false;

        try {
          if (_pendingStartToken == null) {
            _reconcileActiveTrack();
          }
        } finally {
          _publishQueueSnapshot();
        }
      }
    });

    // A failed operation must not poison the serialization chain.
    _queueGate = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );

    return result;
  }

  void _runDetached(Future<void> future, String operation) {
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          debugPrint('$operation failed: $error\n$stack');
        },
      ),
    );
  }

  Track? _nativeTrackAt(int index) {
    if (index < 0 || index >= _queueSource.length) return null;

    final source = _queueSource.children[index];
    if (source is! ja.IndexedAudioSource) return null;

    final tag = source.tag;
    return tag is Track ? tag : null;
  }

  /// Returns a reusable native index only when the entire native window
  /// agrees with the current logical order.
  ///
  /// Merely finding the requested id is insufficient after shuffle or
  /// replacement of the logical playlist.
  int? _reusableNativeIndex(Track track) {
    final logicalIndex = _playlist.indexWhere((item) => item.id == track.id);

    if (logicalIndex < 0) return null;

    for (var nativeIndex = 0;
        nativeIndex < _queueSource.length;
        nativeIndex++) {
      if (_nativeTrackAt(nativeIndex)?.id != track.id) continue;

      final base = logicalIndex - nativeIndex;
      var matches = true;

      for (var i = 0; i < _queueSource.length; i++) {
        final logical = base + i;

        if (logical < 0 ||
            logical >= _playlist.length ||
            _nativeTrackAt(i)?.id != _playlist[logical].id) {
          matches = false;
          break;
        }
      }

      if (matches) return nativeIndex;
    }

    return null;
  }

  void _publishPlaybackError(Object error, StackTrace stack) {
    debugPrint('Playback error: $error\n$stack');

    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        errorCode: 1,
        errorMessage: error.toString(),
      ),
    );
  }

  /// Call only while holding the queue gate.
  ///
  /// play() completes when playback pauses/stops/completes, not when audio
  /// starts. Its lifetime must never own the preparation gate.
  void _launchPlayLocked(int startToken) {
    if (!_playRequested || startToken != _startToken) return;

    final transportToken = _transportToken;

    void report(Object error, StackTrace stack) {
      // Old playback futures may settle after another selection or Pause.
      if (startToken != _startToken || transportToken != _transportToken) {
        debugPrint('Superseded playback error: $error');
        return;
      }

      _playRequested = false;
      _publishPlaybackError(error, stack);
    }

    try {
      final lifetime = _player.play();

      unawaited(
        lifetime.then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            report(error, stack);
          },
        ),
      );
    } catch (error, stack) {
      report(error, stack);
    }
  }

  final StreamController<Track?> _currentTrackController =
      StreamController<Track?>.broadcast();
  final StreamController<bool> _playerStateController =
      StreamController<bool>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _shuffleController =
      StreamController<bool>.broadcast();
  final StreamController<LoopMode> _loopModeController =
      StreamController<LoopMode>.broadcast();

  Duration _duration = Duration.zero;

  Stream<Track?> get currentTrackStream => _currentTrackController.stream;
  Stream<bool> get playerStateStream => _playerStateController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration> get durationStream => _durationController.stream;
  Stream<bool> get shuffleStream => _shuffleController.stream;
  Stream<LoopMode> get loopModeStream => _loopModeController.stream;

  Track? get currentTrack =>
      (_currentIndex >= 0 && _currentIndex < _playlist.length)
          ? _playlist[_currentIndex]
          : null;
  bool get isPlaying => _isPlaying;
  LoopMode get loopMode => _loopMode;
  bool get isShuffle => _isShuffle;

  /// [player] is injectable for tests: production passes nothing and gets
  /// the real platform player. A fake lets instrumented tests drive native
  /// events, delays and failures deterministically.
  BiliBeatAudioHandler({ja.AudioPlayer? player})
      : _player = player ?? ja.AudioPlayer() {
    _initAudioPlayerListeners();
  }

  bool get autoAdvanceHeld =>
      _autoAdvanceHolds > 0 && _loopMode != LoopMode.one;

  /// Stops the queue from moving on when the current track ends, until the
  /// returned callback is invoked. The native queue is trimmed as well, since
  /// a prefetched next track would otherwise start gaplessly without ever
  /// reaching [_handleQueueCompleted].
  VoidCallback holdAutoAdvance() {
    _autoAdvanceHolds++;

    if (_autoAdvanceHolds == 1) {
      _runDetached(
        _trimQueueAfterCurrent(),
        'trim for auto-advance hold',
      );
    }

    var released = false;
    return () {
      if (released) return;
      released = true;
      _autoAdvanceHolds--;
      if (_autoAdvanceHolds == 0 && _loopMode != LoopMode.one) {
        _runDetached(
          _prefetchNext(),
          'prefetch after auto-advance release',
        );
      }
    };
  }

  /// An auto-advance hold still cannot retroactively undo a native transition
  /// already underway. Capturing the editor target remains necessary in the
  /// lyrics patch.

  void updateCurrentTrackMetadata(Track updatedTrack) {
    _runDetached(
      _withQueueGate<void>(() async {
        var changed = false;

        for (final list in [_playlist, _naturalOrder]) {
          final index = list.indexWhere((track) => track.id == updatedTrack.id);

          if (index >= 0) {
            list[index] = updatedTrack;
            changed = true;
          }
        }

        if (!changed) return;

        if (currentTrack?.id == updatedTrack.id) {
          _currentTrackController.add(updatedTrack);
          _updateMediaItem(updatedTrack);
        }
      }),
      'update queue metadata',
    );
  }

  /// Metadata changes do not invalidate a prefetch because they do not alter
  /// track identity or order. The append uses the latest playlist instance.

  void _initAudioPlayerListeners() {
    // Position is forwarded to the UI only. We deliberately do NOT broadcast
    // playback state here: pushing a PlaybackState to audio_service on every
    // tick causes notification/MediaSession churn. The system UI interpolates
    // the notification position from the last state + speed.
    _player.positionStream.listen(_positionController.add);

    _player.durationStream.listen((dur) {
      if (dur != null && dur > Duration.zero) {
        _duration = dur;
        _durationController.add(dur);
        _broadcastState();
      }
    });

    _player.playerStateStream.listen((state) {
      _isPlaying = state.playing;
      _playerStateController.add(_isPlaying);
      _broadcastState();

      if (state.processingState == ja.ProcessingState.completed) {
        _handleQueueCompleted();
      }
    });

    // Fires when the native player advances to the next queued file (gapless
    // auto-advance). Reconciliation runs through the gate and reads the
    // actual native index there: the event's index may already be stale.
    _player.currentIndexStream.listen((playerIndex) {
      if (playerIndex == null || _queueTransitioning) return;

      _runDetached(
        _withQueueGate<void>(() async {
          if (_pendingStartToken != null) return;
          _reconcileActiveTrack();
        }),
        'native-index reconciliation',
      );
    });
  }

  /// Called whenever the actively-playing track changes (manual or auto).
  void _onActiveTrackChanged(Track track) {
    _announce(track);
    _maybeTrimHead();
    _runDetached(_prefetchNext(), 'prefetch after native advance');
  }

  void _maybeTrimHead() {
    Future<void> trim() async {
      await _withQueueGate<void>(() async {
        if (_pendingStartToken != null) return;
        if (_queueSource.length <= 3) return;

        final playerIndex = _player.currentIndex;
        if (playerIndex == null || playerIndex <= 0) return;

        final excess = _queueSource.length - 3;
        final count = excess < playerIndex ? excess : playerIndex;

        if (count <= 0) return;

        ++_queueRevision;

        await _queueSource.removeRange(0, count);

        // The gate's final reconciliation reads the actual native tag.
        // This provisional base update keeps bookkeeping sensible even
        // before that reconciliation runs.
        _queueBaseIndex += count;
      });

      await _prefetchNext();
    }

    _runDetached(trim(), 'trim native queue head');
  }

  /// Re-syncs the announced track with the platform player's actual position
  /// by reading the current native child's tag — never a possibly stale base
  /// index. Called only from the gate body or its finalizer.
  void _reconcileActiveTrack() {
    if (_pendingStartToken != null) return;

    final nativeIndex = _player.currentIndex;
    if (nativeIndex == null) return;

    final nativeTrack = _nativeTrackAt(nativeIndex);
    if (nativeTrack == null) return;

    final logicalIndex =
        _playlist.indexWhere((track) => track.id == nativeTrack.id);

    // The previous native source may belong to a replaced playlist.
    // Never invent a logical mapping for it.
    if (logicalIndex < 0) return;

    final nextBase = logicalIndex - nativeIndex;
    final changedTrack = logicalIndex != _currentIndex;
    final changedBase = nextBase != _queueBaseIndex;

    if (!changedTrack && !changedBase) return;

    ++_queueRevision;
    _currentIndex = logicalIndex;
    _queueBaseIndex = nextBase;

    if (changedTrack) {
      _onActiveTrackChanged(_playlist[logicalIndex]);
    }
  }

  /// Public entry for UI lifecycle (e.g. AppLifecycleState.resumed).
  ///
  /// Reconciliation is queued through the gate now; callers must not assume
  /// the state is synchronously healed before this method returns. Existing
  /// UI stream listeners receive any resulting track change.
  void syncOnResume() {
    _runDetached(
      _withQueueGate<void>(() async {
        if (_pendingStartToken != null) return;

        _reconcileActiveTrack();

        final track = currentTrack;
        if (track != null) {
          _updateMediaItem(track);
          _broadcastState();
        }
      }),
      'resume reconciliation',
    );
  }

  /// Announce the newly active track to every observer: the UI stream, the
  /// system media session, the recently-played history and the duration.
  void _announce(Track track) {
    _currentTrackController.add(track);
    _updateMediaItem(track);
    unawaited(DatabaseService.addRecentlyPlayed(track));
    _duration = Duration(seconds: track.duration > 0 ? track.duration : 180);
    _durationController.add(_duration);
    _broadcastState();
    // An end-of-track timer follows whatever is current: re-arm for the
    // new track so a manual skip does not inherit a stale deadline.
    // Same-track re-announces (metadata edits, reconciliations) keep it.
    if (_sleepMode == SleepTimerMode.endOfTrack &&
        _sleepTrackId != track.id) {
      _armSleepEndOfTrack(track);
    }
  }

  // ---------------------------------------------------------------------------
  // Public playback API
  // ---------------------------------------------------------------------------

  /// Shared entry point for track-changing commands. Selection happens
  /// inside the gate; downloading happens outside it.
  Future<void> _requestStart(
    Track? Function() select, {
    bool autoplay = true,
  }) async {
    final token = ++_startToken;

    ++_transportToken;
    _playRequested = autoplay;
    _pendingStartToken = token;

    try {
      final active = await _withQueueGate<Track?>(() async {
        if (token != _startToken) {
          return null;
        }

        final selected = select();

        if (selected == null) {
          if (_pendingStartToken == token) {
            _pendingStartToken = null;
          }
          return null;
        }

        ++_queueRevision;

        // Invalidate an earlier prefetch, including its cleanup ownership.
        _prefetchingId = null;
        _prefetchOwner = null;

        _announce(selected);
        _positionController.add(Duration.zero);

        _broadcastState(
          processingOverride: AudioProcessingState.loading,
        );

        return selected;
      });

      if (active == null || token != _startToken) return;

      await _startCurrent(
        active: active,
        token: token,
      );
    } catch (error, stack) {
      await _failStart(token, error, stack);
    }
  }

  /// Failure behavior: if a replaced playlist no longer contains the old
  /// native track, this does not invent a mapping or insert that old track
  /// into the new playlist. It leaves the failed selection and publishes an
  /// error. A complete "restore previous playback session" policy would be
  /// a separate product change.
  Future<void> _failStart(
    int token,
    Object error,
    StackTrace stack,
  ) async {
    await _withQueueGate<void>(() async {
      if (token != _startToken) return;

      if (_pendingStartToken == token) {
        _pendingStartToken = null;
      }

      _playRequested = false;

      // If the previous native track still belongs to the logical queue,
      // restore its authoritative identity before publishing the failure.
      _reconcileActiveTrack();
      _broadcastState();
      _publishPlaybackError(error, stack);
    });
  }

  Future<void> playTrack(Track track, {List<Track>? newQueue}) {
    // Snapshot caller-owned lists before waiting for the gate.
    final replacement = newQueue == null ? null : List<Track>.of(newQueue);

    // An absolute selection supersedes any pending skip steps.
    _navDelta = 0;

    return _requestStart(() {
      if (replacement != null && replacement.isNotEmpty) {
        _naturalOrder
          ..clear()
          ..addAll(replacement);

        _playlist
          ..clear()
          ..addAll(replacement);

        if (_isShuffle) {
          _applyShuffleOrder(pinned: track);
        }
      }

      if (!_playlist.any((item) => item.id == track.id)) {
        _playlist.insert(0, track);
        _naturalOrder.insert(0, track);
      }

      _currentIndex = _playlist.indexWhere((item) => item.id == track.id);

      return currentTrack;
    });
  }

  @override
  Future<void> play() async {
    final transport = ++_transportToken;
    _playRequested = true;

    final needsStart = await _withQueueGate<bool>(() async {
      if (transport != _transportToken || !_playRequested) {
        return false;
      }

      // Resume intent applies to the pending selection, not the old source.
      if (_pendingStartToken != null) return false;

      final active = currentTrack;
      if (active == null) {
        _playRequested = false;
        return false;
      }

      final nativeIndex = _reusableNativeIndex(active);

      if (nativeIndex == null || nativeIndex != _player.currentIndex) {
        return true;
      }

      _launchPlayLocked(_startToken);
      return false;
    });

    if (needsStart && transport == _transportToken && _playRequested) {
      await _requestStart(() => currentTrack);
    }
  }

  @override
  Future<void> pause() async {
    final transport = ++_transportToken;
    _playRequested = false;

    await _withQueueGate<void>(() async {
      if (transport != _transportToken) return;

      await _player.pause();

      if (transport == _transportToken) {
        _broadcastState();
      }
    });
  }

  @override
  Future<void> stop() async {
    final token = ++_startToken;
    ++_transportToken;
    _navDelta = 0;

    _playRequested = false;

    // Blocks reconciliation of a superseded, partially installed source
    // until this stop operation reaches the gate.
    _pendingStartToken = token;

    await _withQueueGate<void>(() async {
      if (token != _startToken) return;

      ++_queueRevision;
      _prefetchingId = null;
      _prefetchOwner = null;
      _resetSleepTimer();

      await _player.stop();
      if (token != _startToken) return;

      _pendingStartToken = null;
      _broadcastState();
      _publishSleepTimer();

      await super.stop();
    });
  }

  @override
  Future<void> seek(Duration position) {
    final token = _startToken;

    return _withQueueGate<void>(() async {
      if (token != _startToken || _pendingStartToken != null) {
        return;
      }

      await _player.seek(position);

      if (token != _startToken) return;

      _positionController.add(position);
      _broadcastState();
    });
  }

  /// Seeking during a pending track replacement is ignored rather than
  /// seeking the previous source.

  @override
  Future<void> skipToQueueItem(int index) {
    return _playAtIndex(index);
  }

  /// Selects an existing logical-queue item by stable track id.
  ///
  /// Unlike playTrack, this never inserts a missing track into the queue.
  /// Unlike an index captured by a widget, the id survives queue reordering.
  ///
  /// This duplicates the small start-intent setup from [_requestStart]
  /// deliberately, so a nonexistent/stale queue selection can be rejected
  /// before changing playback intent. Do not route queue selection through
  /// playTrack, because that method is allowed to insert tracks.
  Future<void> selectQueueTrack(String trackId) async {
    final observedStartToken = _startToken;
    _navDelta = 0;

    final plan = await _withQueueGate<
        ({
          Track track,
          int token,
        })?>(() async {
      // A newer track-start intent was submitted while this click waited.
      if (observedStartToken != _startToken) return null;

      final index = _playlist.indexWhere((track) => track.id == trackId);

      // A stale UI row must not resurrect a removed queue item.
      if (index < 0) return null;

      final token = ++_startToken;

      ++_transportToken;
      _playRequested = true;
      _pendingStartToken = token;

      ++_queueRevision;
      _prefetchingId = null;
      _prefetchOwner = null;

      _currentIndex = index;
      final selected = _playlist[index];

      _announce(selected);
      _positionController.add(Duration.zero);

      _broadcastState(
        processingOverride: AudioProcessingState.loading,
      );

      return (
        track: selected,
        token: token,
      );
    });

    if (plan == null || plan.token != _startToken) return;

    await _startCurrent(
      active: plan.track,
      token: plan.token,
    );
  }

  @override
  Future<void> skipToNext() async {
    if (_playlist.isEmpty) return;

    // Record the intent now: stale selection callbacks drop out without
    // consuming, and the latest one applies the accumulated total.
    _navDelta++;
    int? endToken;

    await _requestStart(() {
      if (_playlist.isEmpty) {
        _navDelta = 0;
        return null;
      }

      final steps = _navDelta;
      _navDelta = 0;
      if (steps <= 0) return null;

      final target = _currentIndex + steps;
      if (target < _playlist.length) {
        _currentIndex = target;
      } else if (_loopMode != LoopMode.off) {
        _currentIndex = target % _playlist.length;
      } else {
        endToken = _startToken;
        return null;
      }

      return currentTrack;
    });

    // End of a non-looping queue: an old end-of-queue action must not pause
    // a newer selection.
    final token = endToken;
    if (token == null) return;

    await _withQueueGate<void>(() async {
      if (token != _startToken) return;

      _playRequested = false;
      ++_transportToken;

      await _player.seek(Duration.zero);
      if (token != _startToken) return;

      await _player.pause();
      if (token != _startToken) return;

      _positionController.add(Duration.zero);
      _broadcastState();
    });
  }

  @override
  Future<void> skipToPrevious() async {
    if (_playlist.isEmpty) return;

    if (_pendingStartToken == null &&
        _player.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }

    _navDelta--;
    await _requestStart(() {
      if (_playlist.isEmpty) {
        _navDelta = 0;
        return null;
      }

      final steps = _navDelta;
      _navDelta = 0;
      if (steps >= 0) return null;

      final target = _currentIndex + steps;
      if (target >= 0) {
        _currentIndex = target;
      } else if (_loopMode != LoopMode.off) {
        final length = _playlist.length;
        _currentIndex = ((target % length) + length) % length;
      } else {
        _currentIndex = 0;
      }

      return currentTrack;
    });
  }

  /// Net pending skip steps (forward positive). Each Next/Previous press
  /// records its intent synchronously; only the latest selection callback
  /// consumes the total, so rapid presses land exactly N tracks away while
  /// obsolete downloads/installations are still superseded. Absolute
  /// selections (tap, queue click, auto-advance, stop) reset this.
  int _navDelta = 0;

  /// Switch to a logical index and start it. The fast path for an already
  /// installed window lives in [_startCurrent]; this only selects.
  ///
  /// System advance carries a simultaneously recorded skip: dropping it
  /// would lose a press that landed between the completion event and this
  /// selection. Absolute user selections (tap, queue click) reset instead.
  Future<void> _playAtIndex(int index) {
    final carry = _navDelta;
    _navDelta = 0;
    return _requestStart(() {
      if (index < 0 || index >= _playlist.length) return null;

      _currentIndex = (index + carry).clamp(0, _playlist.length - 1);
      return currentTrack;
    });
  }

  /// Cycle the single play-mode control: 列表循环 -> 单曲循环 -> 随机 -> 列表循环.
  Future<void> cyclePlayMode() async {
    if (_isShuffle) {
      await setShuffle(false);
      await setLoopMode(LoopMode.all);
    } else if (_loopMode != LoopMode.one) {
      await setLoopMode(LoopMode.one);
    } else {
      await setLoopMode(LoopMode.all);
      await setShuffle(true);
    }
  }

  Future<void> setLoopMode(LoopMode mode) async {
    await _withQueueGate<void>(() async {
      if (_loopMode == mode) return;

      ++_queueRevision;
      _loopMode = mode;
      _loopModeController.add(mode);

      // just_audio's LoopMode.one repeats the *current* item of the queue, so
      // no rebuild is needed — the playing track keeps its position.
      await _player.setLoopMode(
        mode == LoopMode.one ? ja.LoopMode.one : ja.LoopMode.off,
      );

      if (mode == LoopMode.one) {
        await _trimQueueAfterCurrentLocked();
      }

      _broadcastState();
    });

    _runDetached(_prefetchNext(), 'prefetch after loop change');
  }

  Future<void> setShuffle(bool on) async {
    await _withQueueGate<void>(() async {
      if (_isShuffle == on) return;

      // Anchor to the native track before changing its logical order,
      // unless a deliberate replacement is still pending.
      if (_pendingStartToken == null) {
        _reconcileActiveTrack();
      }

      final pinned = currentTrack;

      ++_queueRevision;
      _isShuffle = on;
      _shuffleController.add(on);

      if (_playlist.isEmpty) return;

      if (on) {
        _applyShuffleOrder(pinned: pinned);
      } else {
        _playlist
          ..clear()
          ..addAll(_naturalOrder);
      }

      _currentIndex = pinned == null
          ? 0
          : _playlist.indexWhere((track) => track.id == pinned.id);

      if (_currentIndex < 0 && _playlist.isNotEmpty) {
        _currentIndex = 0;
      }

      await _trimQueueAfterCurrentLocked();

      // Old head items are not generally contiguous with the new order.
      // Retain only the currently installed native item.
      final nativeIndex = _player.currentIndex;

      if (nativeIndex != null && nativeIndex > 0) {
        await _queueSource.removeRange(0, nativeIndex);
      }

      final actualIndex = _player.currentIndex;
      final nativeTrack =
          actualIndex == null ? null : _nativeTrackAt(actualIndex);

      if (actualIndex != null && nativeTrack?.id == currentTrack?.id) {
        _queueBaseIndex = _currentIndex - actualIndex;
      }

      _broadcastState();
    });

    _runDetached(_prefetchNext(), 'prefetch after shuffle change');
  }

  // ---------------------------------------------------------------------------
  // Sleep timer (playback layer, never a screen timer)
  // ---------------------------------------------------------------------------

  /// Arms, replaces, or clears the sleep timer. Duration mode survives
  /// track changes; end-of-track re-arms on every new track and pauses at
  /// its end. Pause keeps the countdown running; stop clears it.
  void setSleepTimer(SleepTimerMode mode, {Duration? duration}) {
    _clearSleepTimer();
    if (mode == SleepTimerMode.off) return;
    if (mode == SleepTimerMode.duration) {
      final d = duration ?? const Duration(minutes: 30);
      if (d <= Duration.zero) return;
      _sleepDeadline = DateTime.now().add(d);
    } else {
      final current = currentTrack;
      if (current == null) return;
      _armSleepEndOfTrack(current);
      // _armSleepEndOfTrack publishes; the ticker starts below.
      _sleepMode = SleepTimerMode.endOfTrack;
      _publishSleepTimer();
      _startSleepTicker();
      return;
    }
    _sleepMode = SleepTimerMode.duration;
    _armSleepTimer(_sleepDeadline!.difference(DateTime.now()));
    _publishSleepTimer();
    _startSleepTicker();
  }

  /// Arms the one-shot for the target track's remaining time. Used at set
  /// time and re-armed by [_announce] when the track changes.
  void _armSleepEndOfTrack(Track track) {
    _sleepTrackId = track.id;
    final total = _duration.inSeconds > 0
        ? _duration
        : Duration(seconds: track.duration > 0 ? track.duration : 180);
    var remaining = total - _player.position;
    if (remaining <= Duration.zero) {
      remaining = const Duration(seconds: 1);
    }
    _armSleepTimer(remaining);
  }

  void _armSleepTimer(Duration after) {
    final serial = ++_sleepSerial;
    _sleepTimer?.cancel();
    _sleepTimer = Timer(after.isNegative ? Duration.zero : after, () {
      unawaited(_onSleepTimerFired(serial));
    });
  }

  /// Firing pauses through the transport (cancelling pending autoplay
  /// intents like any pause), then resets. Stale firings are dropped.
  Future<void> _onSleepTimerFired(int serial) async {
    if (serial != _sleepSerial || _sleepMode == SleepTimerMode.off) return;
    _clearSleepTimer();
    await pause();
  }

  /// Silent reset: cancel timers and drop state without publishing.
  void _resetSleepTimer() {
    ++_sleepSerial;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTicker?.cancel();
    _sleepTicker = null;
    _sleepMode = SleepTimerMode.off;
    _sleepDeadline = null;
    _sleepTrackId = null;
  }

  void _clearSleepTimer() {
    _resetSleepTimer();
    _publishSleepTimer();
  }

  void _startSleepTicker() {
    _sleepTicker?.cancel();
    _sleepTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_sleepMode == SleepTimerMode.off) {
        _sleepTicker?.cancel();
        _sleepTicker = null;
        return;
      }
      _publishSleepTimer();
    });
  }

  Duration get _sleepRemaining {
    if (_sleepMode == SleepTimerMode.duration) {
      final deadline = _sleepDeadline;
      if (deadline == null) return Duration.zero;
      final remaining = deadline.difference(DateTime.now());
      return remaining.isNegative ? Duration.zero : remaining;
    }
    if (_sleepMode == SleepTimerMode.endOfTrack) {
      final targetId = _sleepTrackId;
      final current = currentTrack;
      if (targetId == null || current == null) return Duration.zero;
      final total = _duration.inSeconds > 0
          ? _duration
          : Duration(
              seconds:
                  current.duration > 0 ? current.duration : 180);
      final remaining = total - _player.position;
      return remaining.isNegative ? Duration.zero : remaining;
    }
    return Duration.zero;
  }

  void _publishSleepTimer() {
    final next = SleepTimerState(
      mode: _sleepMode,
      remaining: _sleepRemaining,
    );
    _sleepTimerState = next;
    _sleepTimerController.add(next);
  }

  /// Reorders [_playlist] randomly, keeping [pinned] where it is so the
  /// currently-playing track is never yanked out from under playback.
  void _applyShuffleOrder({Track? pinned}) {
    final others = _naturalOrder.where((t) => t.id != pinned?.id).toList()
      ..shuffle();
    _playlist
      ..clear()
      ..addAll([if (pinned != null) pinned, ...others]);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Drops every queued item after the one the player is currently on, so the
  /// prefetch window can be rebuilt without interrupting playback.
  Future<void> _trimQueueAfterCurrent() {
    return _withQueueGate<void>(_trimQueueAfterCurrentLocked);
  }

  /// Must be called while holding the queue gate.
  Future<void> _trimQueueAfterCurrentLocked() async {
    ++_queueRevision;
    _prefetchingId = null;
    _prefetchOwner = null;

    final playerIndex = _player.currentIndex;

    if (playerIndex == null) {
      if (_queueSource.length > 0) {
        await _queueSource.clear();
      }
      return;
    }

    if (_queueSource.length > playerIndex + 1) {
      await _queueSource.removeRange(
        playerIndex + 1,
        _queueSource.length,
      );
    }
  }

  Future<void> _startCurrent({
    required Track active,
    required int token,
  }) async {
    try {
      // Preserve the fast path for a track already present in a valid
      // native window. No download or source replacement is necessary.
      final reused = await _withQueueGate<bool>(() async {
        if (token != _startToken || currentTrack?.id != active.id) {
          return false;
        }

        final nativeIndex = _reusableNativeIndex(active);
        if (nativeIndex == null) return false;

        ++_queueRevision;
        _queueBaseIndex = _currentIndex - nativeIndex;

        await _player.seek(Duration.zero, index: nativeIndex);

        if (token != _startToken) return false;

        if (_pendingStartToken == token) {
          _pendingStartToken = null;
        }

        _broadcastState();
        _launchPlayLocked(token);
        return true;
      });

      if (token != _startToken) return;

      if (reused) {
        _runDetached(_prefetchNext(), 'prefetch after native seek');
        return;
      }

      // Intentionally outside the queue gate.
      final path = await AudioDownloadService.ensureDownloaded(active);

      if (token != _startToken) return;

      final installed = await _withQueueGate<bool>(() async {
        if (token != _startToken || currentTrack?.id != active.id) {
          return false;
        }

        ++_queueRevision;
        _prefetchingId = null;
        _prefetchOwner = null;

        await _queueSource.clear();
        if (token != _startToken) return false;

        // Use the latest metadata instance for the selected track.
        final installing = currentTrack;
        if (installing == null || installing.id != active.id) {
          return false;
        }

        await _queueSource.add(
          ja.AudioSource.file(path, tag: installing),
        );
        if (token != _startToken) return false;

        _queueBaseIndex = _currentIndex;

        await _player.setLoopMode(
          _loopMode == LoopMode.one ? ja.LoopMode.one : ja.LoopMode.off,
        );
        if (token != _startToken) return false;

        await _player.setAudioSource(
          _queueSource,
          initialIndex: 0,
          initialPosition: Duration.zero,
        );
        if (token != _startToken) return false;

        if (_pendingStartToken == token) {
          _pendingStartToken = null;
        }

        // Source preparation is complete. Launching play does not retain
        // this gate for the duration of the song.
        _broadcastState();
        _launchPlayLocked(token);

        return true;
      });

      if (installed && token == _startToken) {
        _runDetached(_prefetchNext(), 'prefetch after source install');
      }
    } catch (error, stack) {
      await _failStart(token, error, stack);
    }
  }

  /// Background-download the next logical track and append it to the native
  /// queue. Downloads run outside the gate; both the selection snapshot and
  /// the append commit run inside it.
  ///
  /// Scope: this preserves existing prefetch download behavior. The separate
  /// local-only queue change prevents nonlocal items from entering automatic
  /// playback/prefetch; this patch does not implement that product decision.
  Future<void> _prefetchNext() async {
    final plan = await _withQueueGate<
        ({
          Track track,
          int revision,
          int startToken,
          int owner,
        })?>(() async {
      if (_pendingStartToken != null) return null;
      if (_loopMode == LoopMode.one || autoAdvanceHeld) return null;
      if (_playlist.isEmpty || _currentIndex < 0) return null;

      final active = currentTrack;
      if (active == null) return null;

      final nativeIndex = _reusableNativeIndex(active);

      if (nativeIndex == null || nativeIndex != _player.currentIndex) {
        return null;
      }

      // Only the contiguous successor is prefetched: the window's player
      // index must stay a simple offset from the logical index. Wrapping
      // past the end is handled by [_handleQueueCompleted] instead.
      final nextIndex = _currentIndex + 1;
      if (nextIndex >= _playlist.length) return null;

      if (nativeIndex != _queueSource.length - 1) return null;

      final next = _playlist[nextIndex];
      if (_prefetchingId == next.id) return null;

      final owner = ++_prefetchSerial;

      _prefetchingId = next.id;
      _prefetchOwner = owner;

      return (
        track: next,
        revision: _queueRevision,
        startToken: _startToken,
        owner: owner,
      );
    });

    if (plan == null) return;

    try {
      final path = await AudioDownloadService.ensureDownloaded(plan.track);

      await _withQueueGate<void>(() async {
        if (_prefetchOwner != plan.owner ||
            _queueRevision != plan.revision ||
            _startToken != plan.startToken ||
            _pendingStartToken != null) {
          return;
        }

        if (_loopMode == LoopMode.one || autoAdvanceHeld) return;

        final active = currentTrack;
        if (active == null) return;

        final nativeIndex = _reusableNativeIndex(active);

        if (nativeIndex == null ||
            nativeIndex != _player.currentIndex ||
            nativeIndex != _queueSource.length - 1) {
          return;
        }

        final nextIndex = _currentIndex + 1;

        if (nextIndex >= _playlist.length ||
            _playlist[nextIndex].id != plan.track.id) {
          return;
        }

        ++_queueRevision;

        await _queueSource.add(
          ja.AudioSource.file(
            path,
            tag: _playlist[nextIndex],
          ),
        );
      });
    } catch (error, stack) {
      debugPrint('Prefetch failed: $error\n$stack');
    } finally {
      await _withQueueGate<void>(() async {
        if (_prefetchOwner != plan.owner) return;

        _prefetchOwner = null;
        _prefetchingId = null;
      });
    }
  }

  /// The native queue ran out. The completion event must not mutate the
  /// logical queue outside the gate; advancement goes through [_playAtIndex].
  void _handleQueueCompleted() {
    final observedToken = _startToken;

    Future<void> advance() async {
      final nextIndex = await _withQueueGate<int?>(() async {
        if (observedToken != _startToken ||
            _pendingStartToken != null ||
            _playlist.isEmpty ||
            _player.processingState != ja.ProcessingState.completed) {
          return null;
        }

        _reconcileActiveTrack();

        // A sleep timer for end-of-track pauses explicitly here instead
        // of advancing — before the repeat-one shortcut below, so it
        // also applies under repeat-one. Merely preventing auto-advance
        // would leave native playing state inconsistent. The seek mirrors
        // the end-of-queue branch below: it moves the native state off
        // `completed` so this pause's own state event cannot retrigger
        // advancement.
        if (_sleepMode == SleepTimerMode.endOfTrack) {
          _playRequested = false;
          ++_transportToken;
          _resetSleepTimer();

          await _player.seek(Duration.zero);
          if (observedToken != _startToken) return null;

          await _player.pause();
          _broadcastState();
          _publishSleepTimer();
          return null;
        }

        // Native repeat-one owns repetition of the current source.
        if (_loopMode == LoopMode.one) return null;

        if (autoAdvanceHeld) {
          _playRequested = false;
          ++_transportToken;

          await _player.pause();
          _broadcastState();
          return null;
        }

        final next = _currentIndex + 1;

        if (next < _playlist.length) return next;
        if (_loopMode == LoopMode.all) return 0;

        _playRequested = false;
        ++_transportToken;

        await _player.pause();
        _broadcastState();
        return null;
      });

      if (nextIndex != null && observedToken == _startToken) {
        await _playAtIndex(nextIndex);
      }
    }

    _runDetached(advance(), 'automatic queue advance');
  }

  void _broadcastState({AudioProcessingState? processingOverride}) {
    final playing = _player.playing;
    final mapped = const {
      ja.ProcessingState.idle: AudioProcessingState.idle,
      ja.ProcessingState.loading: AudioProcessingState.loading,
      ja.ProcessingState.buffering: AudioProcessingState.buffering,
      ja.ProcessingState.ready: AudioProcessingState.ready,
      ja.ProcessingState.completed: AudioProcessingState.completed,
    }[_player.processingState];

    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState:
          processingOverride ?? mapped ?? AudioProcessingState.idle,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      repeatMode: _loopMode == LoopMode.one
          ? AudioServiceRepeatMode.one
          : (_loopMode == LoopMode.all
              ? AudioServiceRepeatMode.all
              : AudioServiceRepeatMode.none),
      shuffleMode: _isShuffle
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      queueIndex: _currentIndex >= 0 ? _currentIndex : null,
    ));
  }

  MediaItem _mediaItemForTrack(Track track) {
    return MediaItem(
      id: track.id,
      album: 'BiliBeat',
      title: track.title,
      artist: track.uploader,

      // Preserve the existing handler behavior in this focused patch.
      duration: Duration(
        seconds: track.duration > 0 ? track.duration : 180,
      ),

      artUri: track.coverUrl.isEmpty ? null : Uri.tryParse(track.coverUrl),
    );
  }

  void _updateMediaItem(Track track) {
    mediaItem.add(_mediaItemForTrack(track));
  }
}
