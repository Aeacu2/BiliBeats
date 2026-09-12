import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;

/// Deterministic stand-in for just_audio's [ja.AudioPlayer].
///
/// The handler only needs a small surface; everything else throws via
/// [noSuchMethod]. Timing is fully test-controlled:
/// - [setSourceDelay] slows native installation (supersession windows).
/// - [gatePlayLifetime] makes [play] return a pending future, like the real
///   playback-lifetime future, so stale-future error routing is testable.
/// - [simulateAdvance]/[simulateCompletion] drive native events.
class FakeAudioPlayer implements ja.AudioPlayer {
  Duration setSourceDelay = Duration.zero;
  Completer<void>? gatePlayLifetime;

  int? currentIndexValue;
  final currentIndexEvents = StreamController<int?>.broadcast();

  bool playingValue = false;
  ja.ProcessingState processingStateValue = ja.ProcessingState.idle;
  final playerStateEvents = StreamController<ja.PlayerState>.broadcast();

  Duration positionValue = Duration.zero;
  ja.LoopMode? lastLoopMode;

  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  int setSourceCalls = 0;

  bool _lastEmittedPlaying = false;
  ja.ProcessingState? _lastEmittedProcessing;

  /// When true, the next [setAudioSource] throws, then resets.
  bool failSourceOnce = false;

  void _emitState() {
    // Real players only emit on actual change. Unconditional re-emission
    // would loop completion handling: a pause echo with a stale
    // `completed` state would retrigger advancement forever.
    if (playingValue == _lastEmittedPlaying &&
        processingStateValue == _lastEmittedProcessing) {
      return;
    }
    _lastEmittedPlaying = playingValue;
    _lastEmittedProcessing = processingStateValue;
    playerStateEvents.add(ja.PlayerState(playingValue, processingStateValue));
  }

  /// Advances the native queue as gapless auto-advance would.
  void simulateAdvance(int index) {
    currentIndexValue = index;
    currentIndexEvents.add(index);
  }

  /// Ends the native queue so the handler's completion path runs.
  void simulateCompletion() {
    processingStateValue = ja.ProcessingState.completed;
    _emitState();
  }

  @override
  Stream<int?> get currentIndexStream => currentIndexEvents.stream;

  @override
  Stream<ja.PlayerState> get playerStateStream => playerStateEvents.stream;

  @override
  Stream<Duration> get positionStream => const Stream.empty();

  @override
  Stream<Duration?> get durationStream => const Stream.empty();

  @override
  int? get currentIndex => currentIndexValue;

  @override
  bool get playing => playingValue;

  @override
  ja.ProcessingState get processingState => processingStateValue;

  @override
  Duration get position => positionValue;

  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  double get speed => 1.0;

  @override
  Future<void> play() async {
    playCalls++;
    playingValue = true;
    if (processingStateValue == ja.ProcessingState.idle) {
      processingStateValue = ja.ProcessingState.ready;
    }
    _emitState();
    final gate = gatePlayLifetime;
    if (gate != null) {
      await gate.future;
    }
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playingValue = false;
    _emitState();
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    playingValue = false;
    processingStateValue = ja.ProcessingState.idle;
    currentIndexValue = null;
    _emitState();
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (index != null) {
      currentIndexValue = index;
      currentIndexEvents.add(index);
    }
    if (position != null) {
      positionValue = position;
    }
    // Like a real seek, leaving a terminal state moves back to ready
    // without synthesizing a completion event.
    if (processingStateValue == ja.ProcessingState.completed) {
      processingStateValue = ja.ProcessingState.ready;
    }
  }

  @override
  Future<void> setLoopMode(ja.LoopMode mode) async {
    lastLoopMode = mode;
  }

  @override
  Future<Duration?> setAudioSource(
    ja.AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    setSourceCalls++;
    await Future<void>.delayed(setSourceDelay);
    if (failSourceOnce) {
      failSourceOnce = false;
      throw Exception('fake source failure');
    }
    currentIndexValue = initialIndex;
    currentIndexEvents.add(initialIndex);
    processingStateValue = ja.ProcessingState.ready;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
