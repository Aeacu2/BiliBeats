import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;

/// Deterministic stand-in for just_audio's [ja.AudioPlayer], modelling the
/// native playlist the handler now relies on: a sequence of tagged sources,
/// a current index, shuffle indices and a loop mode, all published through
/// [sequenceStateStream] like the real player.
///
/// Tests drive "native" behaviour with [simulateAutoAdvance] and
/// [simulateCompleted]; [setSourceDelay] and [failNextSource] exercise the
/// install path. Anything the handler does not use throws via
/// [noSuchMethod].
class FakeAudioPlayer implements ja.AudioPlayer {
  Duration setSourceDelay = Duration.zero;
  bool failNextSource = false;

  List<ja.IndexedAudioSource> _children = [];
  int? _index;
  bool _shuffle = false;
  List<int> _shuffleIndices = [];
  ja.LoopMode _loop = ja.LoopMode.off;
  bool _playing = false;
  ja.ProcessingState _processing = ja.ProcessingState.idle;

  Duration positionValue = Duration.zero;
  Duration? durationValue = const Duration(seconds: 200);

  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  int setSourceCalls = 0;
  double volumeValue = 1.0;

  @override
  Future<void> setVolume(double volume) async => volumeValue = volume;

  final _sequenceEvents = StreamController<ja.SequenceState>.broadcast();
  final _playingEvents = StreamController<bool>.broadcast();
  final _playbackEvents = StreamController<ja.PlaybackEvent>.broadcast();
  final _durationEvents = StreamController<Duration?>.broadcast();
  final _processingEvents = StreamController<ja.ProcessingState>.broadcast();
  final _discontinuities =
      StreamController<ja.PositionDiscontinuity>.broadcast();
  // ignore: close_sinks
  final _errors = StreamController<ja.PlayerException>.broadcast();
  final _positions = StreamController<Duration>.broadcast();

  // ---------------------------------------------------------------------------
  // Test controls
  // ---------------------------------------------------------------------------

  /// The track tag of the current native item.
  Object? get currentTag =>
      _index == null || _children.isEmpty ? null : _children[_index!].tag;

  List<Object?> get tags => [for (final c in _children) c.tag];

  ja.LoopMode get nativeLoopMode => _loop;

  /// Gapless move to the next item in play order, as the platform does at
  /// the end of a track.
  void simulateAutoAdvance() {
    final order = _order;
    if (order.isEmpty || _index == null) return;
    final position = order.indexOf(_index!);
    if (_loop == ja.LoopMode.one) {
      // Repeat: same item, position back to zero.
    } else if (position + 1 < order.length) {
      _index = order[position + 1];
    } else if (_loop == ja.LoopMode.all) {
      _index = order.first;
    } else {
      simulateCompleted();
      return;
    }
    positionValue = Duration.zero;
    _emitSequence();
    _discontinuities.add(ja.PositionDiscontinuity(
      ja.PositionDiscontinuityReason.autoAdvance,
      ja.PlaybackEvent(),
      ja.PlaybackEvent(),
    ));
  }

  void simulateCompleted() {
    _processing = ja.ProcessingState.completed;
    _processingEvents.add(_processing);
    _playbackEvents.add(ja.PlaybackEvent(processingState: _processing));
  }

  void emitPosition(Duration position) {
    positionValue = position;
    _positions.add(position);
  }

  List<int> get _order => _shuffle
      ? _shuffleIndices
      : List<int>.generate(_children.length, (i) => i);

  void _emitSequence() => _sequenceEvents.add(sequenceState);

  void _setPlaying(bool playing) {
    if (_playing == playing) return;
    _playing = playing;
    _playingEvents.add(playing);
  }

  List<int> _shuffledWithFirst(int? first) {
    final rest = [
      for (var i = _children.length - 1; i >= 0; i--)
        if (i != first) i,
    ];
    return [if (first != null) first, ...rest];
  }

  // ---------------------------------------------------------------------------
  // AudioPlayer surface used by the handler
  // ---------------------------------------------------------------------------

  @override
  ja.SequenceState get sequenceState => ja.SequenceState(
        sequence: List.unmodifiable(_children),
        currentIndex: _index,
        shuffleIndices: List.unmodifiable(_shuffleIndices),
        shuffleModeEnabled: _shuffle,
        loopMode: _loop,
      );

  @override
  Stream<ja.SequenceState> get sequenceStateStream => _sequenceEvents.stream;

  @override
  Stream<bool> get playingStream => _playingEvents.stream;

  @override
  Stream<ja.PlaybackEvent> get playbackEventStream => _playbackEvents.stream;

  @override
  Stream<Duration?> get durationStream => _durationEvents.stream;

  @override
  Stream<ja.ProcessingState> get processingStateStream =>
      _processingEvents.stream;

  @override
  Stream<ja.PositionDiscontinuity> get positionDiscontinuityStream =>
      _discontinuities.stream;

  @override
  Stream<ja.PlayerException> get errorStream => _errors.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  List<ja.AudioSource> get audioSources => List.unmodifiable(_children);

  @override
  bool get shuffleModeEnabled => _shuffle;

  @override
  bool get playing => _playing;

  @override
  ja.ProcessingState get processingState => _processing;

  @override
  Duration get position => positionValue;

  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  double get speed => 1.0;

  @override
  Duration? get duration => durationValue;

  @override
  Future<Duration?> setAudioSources(
    List<ja.AudioSource> audioSources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ja.ShuffleOrder? shuffleOrder,
  }) async {
    setSourceCalls++;
    await Future<void>.delayed(setSourceDelay);
    if (failNextSource) {
      failNextSource = false;
      throw ja.PlayerException(1, 'fake source failure', initialIndex);
    }
    _children = audioSources.cast<ja.IndexedAudioSource>().toList();
    _index = _children.isEmpty ? null : (initialIndex ?? 0);
    _shuffleIndices = _shuffledWithFirst(_index);
    positionValue = initialPosition ?? Duration.zero;
    _processing = ja.ProcessingState.ready;
    _processingEvents.add(_processing);
    _playbackEvents.add(ja.PlaybackEvent(processingState: _processing));
    _durationEvents.add(durationValue);
    _emitSequence();
    return durationValue;
  }

  @override
  Future<void> play() async {
    playCalls++;
    if (_processing == ja.ProcessingState.idle && _children.isNotEmpty) {
      _processing = ja.ProcessingState.ready;
      _processingEvents.add(_processing);
    }
    _setPlaying(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _setPlaying(false);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _setPlaying(false);
    _processing = ja.ProcessingState.idle;
    _processingEvents.add(_processing);
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (position != null) positionValue = position;
    if (_processing == ja.ProcessingState.completed) {
      _processing = ja.ProcessingState.ready;
      _processingEvents.add(_processing);
    }
    if (index != null && index != _index) {
      _index = index;
      _emitSequence();
    }
  }

  @override
  Future<void> setLoopMode(ja.LoopMode mode) async {
    _loop = mode;
    _emitSequence();
  }

  @override
  Future<void> setShuffleModeEnabled(bool enabled) async {
    _shuffle = enabled;
    _emitSequence();
  }

  @override
  Future<void> shuffle() async {
    _shuffleIndices = _shuffledWithFirst(_index);
    _emitSequence();
  }

  @override
  Future<void> removeAudioSourceAt(int index) async {
    _children.removeAt(index);
    _shuffleIndices = [
      for (final i in _shuffleIndices)
        if (i != index) i > index ? i - 1 : i,
    ];
    final current = _index;
    if (_children.isEmpty) {
      _index = null;
    } else if (current != null && current > index) {
      _index = current - 1;
    } else if (current != null && current >= _children.length) {
      _index = _children.length - 1;
    }
    _emitSequence();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
