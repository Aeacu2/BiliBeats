import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../models/playback_state.dart';
import '../models/track.dart';
import 'audio_download_service.dart';
import 'database_service.dart';

export '../models/playback_state.dart';

/// Playback engine.
///
/// **One source of truth.** The whole queue lives in the native player
/// (ExoPlayer / AVQueuePlayer) as local files, each tagged with its [Track].
/// What the app shows as "now playing" is read back from the native player's
/// current item — never predicted or tracked separately in Dart. The earlier
/// design kept a Dart playlist and mirrored a small window of it natively,
/// then tried to reconcile the two; whenever they drifted (slow downloads,
/// background throttling, failed starts) the screen showed one song while
/// another was audible. That class of bug cannot occur here.
///
/// **Nothing unplayable enters the queue.** Every queued item is already on
/// disk. A track that still needs downloading is fetched *before* the queue
/// changes, while the current song keeps playing and keeps being shown;
/// [preparing] tells the UI what is being fetched.
///
/// **Survives process death.** The queue, current track and position are
/// saved continuously and restored on the next launch ([restoreSession]).
///
/// **Background-safe on Android.** The media service stays in the foreground
/// while paused (see `main.dart`), so resuming after an audio interruption
/// never has to start a foreground service from the background — which
/// Android 12+ forbids and answers by killing the process. After a long
/// pause the service is stopped deliberately ([_idleStopAfter]).
class BiliBeatAudioHandler extends BaseAudioHandler with SeekHandler {
  BiliBeatAudioHandler({
    ja.AudioPlayer? player,
    bool manageAudioSession = true,
  }) : _player = player ??
            ja.AudioPlayer(
              // Interruptions are handled below so a resume can be cancelled
              // once the service has been stopped.
              handleInterruptions: false,
              // A missing or corrupt file skips ahead instead of stalling.
              maxSkipsOnError: 3,
            ) {
    _listenToPlayer();
    _downloadRemovedSub =
        DatabaseService.downloadRemovedStream.listen(removeTracks);
    if (manageAudioSession) unawaited(_configureAudioSession());
  }

  final ja.AudioPlayer _player;

  // ---------------------------------------------------------------------------
  // Observable state (read by the UI; all derived from the native player)
  // ---------------------------------------------------------------------------

  /// The track the native player is on. Notifies on metadata edits too.
  final TrackNotifier nowPlaying = TrackNotifier();

  final ValueNotifier<bool> playingNotifier = ValueNotifier(false);

  final ValueNotifier<Duration> durationNotifier = ValueNotifier(Duration.zero);

  final ValueNotifier<PlaybackQueueSnapshot> queueNotifier =
      ValueNotifier(PlaybackQueueSnapshot.empty);

  /// A requested track that is being downloaded before it can start. The
  /// current song keeps playing (and keeps being shown) meanwhile.
  final ValueNotifier<Track?> preparing = ValueNotifier(null);

  final ValueNotifier<SleepTimerState> sleepTimerNotifier =
      ValueNotifier(SleepTimerState.off);

  final StreamController<String> _messages =
      StreamController<String>.broadcast();

  /// Short, user-facing notices (a start that failed, a skipped file).
  Stream<String> get messages => _messages.stream;

  Track? get currentTrack => nowPlaying.value;
  bool get isPlaying => _player.playing;
  bool get isShuffle => _player.shuffleModeEnabled;
  LoopMode get loopMode => _loopMode;
  PlaybackQueueSnapshot get queueSnapshot => queueNotifier.value;
  SleepTimerState get sleepTimerState => sleepTimerNotifier.value;
  Duration get position => _player.position;
  Stream<Duration> get positionStream => _player.positionStream;

  // ---------------------------------------------------------------------------
  // Internal state
  // ---------------------------------------------------------------------------

  LoopMode _loopMode = LoopMode.all;

  /// Latest metadata per id. Native tags are immutable, so edits made while
  /// a track is queued are applied when reading tags back.
  final Map<String, Track> _latest = {};

  /// Bumped by every queue-replacing request. A slower, older request that
  /// finishes later cannot overwrite a newer one.
  int _selection = 0;

  /// While > 0 a new queue is being installed; publishing is held until it
  /// lands so an intermediate state is never shown.
  int _installing = 0;

  /// Target of an in-flight skip, so rapid Next presses each move one track.
  int? _navTarget;

  bool _recordHistory = true;
  bool _restoreStarted = false;
  bool _resumeAfterInterruption = false;
  int _autoAdvanceHolds = 0;

  static const Duration _idleStopAfter = Duration(minutes: 30);
  Timer? _idleTimer;
  Timer? _sessionSaveTimer;
  Timer? _progressSaveTimer;

  StreamSubscription<Set<String>>? _downloadRemovedSub;

  Track _resolve(Track tag) => _latest[tag.id] ?? tag;

  Track? _trackOf(ja.IndexedAudioSource? source) {
    final tag = source?.tag;
    return tag is Track ? _resolve(tag) : null;
  }

  /// Sequence indices in play order.
  static List<int> _order(ja.SequenceState state) => state.shuffleModeEnabled
      ? state.shuffleIndices
      : List<int>.generate(state.sequence.length, (i) => i);

  // ---------------------------------------------------------------------------
  // Native player → published state
  // ---------------------------------------------------------------------------

  void _listenToPlayer() {
    _player.sequenceStateStream.listen((_) => _publish());

    _player.playingStream.listen((playing) {
      playingNotifier.value = playing;
      _broadcastState();
      _onPlayingChanged(playing);
    });

    _player.playbackEventStream.listen(
      (_) => _broadcastState(),
      onError: (Object error, StackTrace stack) {
        debugPrint('Playback event error: $error');
        _broadcastState();
      },
    );

    _player.durationStream.listen(_onDuration);
    _player.processingStateStream.listen(_onProcessingState);
    _player.positionDiscontinuityStream.listen(_onDiscontinuity);

    _player.errorStream.listen((error) {
      debugPrint('Player error: ${error.code} ${error.message}');
      _messages.add('有歌曲无法播放，已跳过');
    });
  }

  void _publish() {
    if (_installing > 0) return;

    final state = _player.sequenceState;
    final order = _order(state);
    final tracks = <Track>[];
    for (final i in order) {
      final track = _trackOf(state.sequence[i]);
      if (track != null) tracks.add(track);
    }

    final current = _trackOf(state.currentSource);
    final index = current == null || state.currentIndex == null
        ? -1
        : order.indexOf(state.currentIndex!);

    final previous = nowPlaying.value;
    if (current?.id != previous?.id) {
      _announce(current);
    } else if (current != null && !identical(current, previous)) {
      // Same track, edited metadata.
      nowPlaying.value = current;
      mediaItem.add(_mediaItemFor(current));
    }

    final old = queueNotifier.value;
    final tracksChanged = !_sameInstances(old.tracks, tracks);
    if (tracksChanged ||
        old.currentIndex != index ||
        old.isShuffle != state.shuffleModeEnabled ||
        old.loopMode != _loopMode) {
      queueNotifier.value = PlaybackQueueSnapshot(
        tracks: tracks,
        currentIndex: index,
        isShuffle: state.shuffleModeEnabled,
        loopMode: _loopMode,
      );
      if (tracksChanged) {
        queue.add(List<MediaItem>.unmodifiable(tracks.map(_mediaItemFor)));
      }
    }

    _broadcastState();
    _scheduleSessionSave();
  }

  static bool _sameInstances(List<Track> a, List<Track> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  void _announce(Track? track) {
    nowPlaying.value = track;
    if (track == null) {
      durationNotifier.value = Duration.zero;
      return;
    }

    final known = _player.duration;
    durationNotifier.value = known != null && known > Duration.zero
        ? known
        : Duration(seconds: track.duration > 0 ? track.duration : 0);
    mediaItem.add(_mediaItemFor(track));

    if (_recordHistory) unawaited(DatabaseService.addRecentlyPlayed(track));
  }

  void _onDuration(Duration? duration) {
    if (duration == null || duration <= Duration.zero) return;
    durationNotifier.value = duration;
    final track = nowPlaying.value;
    final item = mediaItem.value;
    if (track != null && item != null && item.id == track.id &&
        item.duration != duration) {
      mediaItem.add(item.copyWith(duration: duration));
    }
  }

  void _onProcessingState(ja.ProcessingState state) {
    if (state != ja.ProcessingState.completed) return;
    // End of a non-looping queue: park at the start, paused, rather than
    // leaving the player "playing" a finished queue.
    unawaited(() async {
      await _player.pause();
      final order = _order(_player.sequenceState);
      if (order.isNotEmpty) {
        await _player.seek(Duration.zero, index: order.first);
      }
    }());
  }

  void _onDiscontinuity(ja.PositionDiscontinuity discontinuity) {
    if (discontinuity.reason != ja.PositionDiscontinuityReason.autoAdvance) {
      return;
    }
    // Fallback for end-of-track sleep when the position check missed the
    // last tick.
    if (_sleepMode == SleepTimerMode.endOfTrack) _fireSleepTimer();
  }

  void _onPlayingChanged(bool playing) {
    _idleTimer?.cancel();
    _progressSaveTimer?.cancel();

    if (playing) {
      _progressSaveTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => unawaited(saveSession()),
      );
      return;
    }

    unawaited(saveSession());
    if (_player.processingState != ja.ProcessingState.idle) {
      _idleTimer = Timer(_idleStopAfter, () {
        if (!_player.playing) unawaited(stop());
      });
    }
  }

  void _broadcastState() {
    final playing = _player.playing;
    final state = _player.sequenceState;
    final current = state.currentIndex;
    final queueIndex = current == null ? null : _order(state).indexOf(current);

    playbackState.add(playbackState.value.copyWith(
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
      processingState: const {
        ja.ProcessingState.idle: AudioProcessingState.idle,
        ja.ProcessingState.loading: AudioProcessingState.loading,
        ja.ProcessingState.buffering: AudioProcessingState.buffering,
        ja.ProcessingState.ready: AudioProcessingState.ready,
        ja.ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: queueIndex != null && queueIndex >= 0 ? queueIndex : null,
      repeatMode: switch (_loopMode) {
        LoopMode.off => AudioServiceRepeatMode.none,
        LoopMode.all => AudioServiceRepeatMode.all,
        LoopMode.one => AudioServiceRepeatMode.one,
      },
      shuffleMode: state.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    ));
  }

  MediaItem _mediaItemFor(Track track) {
    final known = nowPlaying.value?.id == track.id ? _player.duration : null;
    return MediaItem(
      id: track.id,
      album: 'BiliBeats',
      title: track.title,
      artist: track.uploader,
      duration: known ??
          (track.duration > 0 ? Duration(seconds: track.duration) : null),
      artUri: track.coverUrl.isEmpty
          ? null
          : Uri.tryParse(
              track.coverUrl.startsWith('/')
                  ? 'file://${track.coverUrl}'
                  : track.coverUrl,
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // Audio session: interruptions and headphone unplug
  // ---------------------------------------------------------------------------

  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              // The OS ducks media streams itself.
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (_player.playing) {
                // Only a transient interruption (a call, a navigation
                // prompt) earns an automatic resume.
                _resumeAfterInterruption =
                    event.type == AudioInterruptionType.pause;
                unawaited(_player.pause());
              }
          }
        } else {
          final resume = _resumeAfterInterruption &&
              event.type == AudioInterruptionType.pause;
          _resumeAfterInterruption = false;
          if (resume) _startPlayback();
        }
      });

      session.becomingNoisyEventStream.listen((_) {
        _resumeAfterInterruption = false;
        unawaited(_player.pause());
      });
    } catch (error, stack) {
      debugPrint('Audio session setup failed: $error\n$stack');
    }
  }

  // ---------------------------------------------------------------------------
  // Queue installation
  // ---------------------------------------------------------------------------

  /// Replaces the native queue. Returns false when superseded or failed.
  Future<bool> _install(
    List<Track> tracks,
    int startIndex, {
    required int token,
    Duration position = Duration.zero,
    bool autoplay = true,
    bool recordHistory = true,
    bool? shuffle,
  }) async {
    if (tracks.isEmpty) return false;

    final sources = <ja.AudioSource>[
      for (final track in tracks)
        ja.AudioSource.file(
          await AudioDownloadService.audioPathForId(track.id),
          tag: track,
        ),
    ];
    if (token != _selection) return false;

    _installing++;
    var interrupted = false;
    Object? failure;
    StackTrace? failureStack;
    try {
      if (shuffle != null && shuffle != _player.shuffleModeEnabled) {
        await _player.setShuffleModeEnabled(shuffle);
      }
      await _applyNativeLoopMode();
      await _player.setAudioSources(
        sources,
        initialIndex: startIndex,
        initialPosition: position,
      );
    } on ja.PlayerInterruptedException {
      interrupted = true;
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      _installing--;
    }

    if (_installing == 0) {
      _recordHistory = recordHistory;
      _publish();
      _recordHistory = true;
    }

    if (interrupted || token != _selection) return false;

    if (failure != null) {
      debugPrint('Queue install failed: $failure\n$failureStack');
      _messages.add('无法播放「${tracks[startIndex].title}」');
      return false;
    }

    if (autoplay) _startPlayback();
    return true;
  }

  void _startPlayback() {
    _idleTimer?.cancel();
    unawaited(_player.play().catchError((Object error, StackTrace stack) {
      debugPrint('Play failed: $error\n$stack');
    }));
  }

  /// Downloads [track] first if needed, without touching the current queue.
  Future<bool> _ensureLocal(Track track, int token) async {
    if (await AudioDownloadService.isDownloaded(track)) return true;
    if (token != _selection) return false;

    preparing.value = track;
    try {
      await AudioDownloadService.ensureDownloaded(track);
      return token == _selection;
    } catch (error, stack) {
      debugPrint('Download before play failed: $error\n$stack');
      if (token == _selection) {
        _messages.add('「${track.title}」下载失败，未能播放');
      }
      return false;
    } finally {
      if (token == _selection) preparing.value = null;
    }
  }

  /// Downloaded tracks, keyed by id, with their latest stored metadata.
  Future<Map<String, Track>> _library() async {
    final library = await DatabaseService.getDownloadedTracks();
    return {for (final track in library) track.id: _resolve(track)};
  }

  // ---------------------------------------------------------------------------
  // Public playback API
  // ---------------------------------------------------------------------------

  /// Plays [track] within [queue] (default: the whole downloaded library).
  /// Only downloaded items of [queue] are queued. If [track] itself is not
  /// downloaded yet it is downloaded first; until then nothing changes.
  Future<void> playTrack(Track track, {List<Track>? queue}) async {
    final token = ++_selection;
    preparing.value = null;

    if (!await _ensureLocal(track, token)) return;

    final library = await _library();
    if (token != _selection) return;

    final base = (queue == null || queue.isEmpty) ? library.values : queue;
    final tracks = <Track>[];
    final seen = <String>{};
    for (final item in base) {
      final local = library[item.id];
      if (local != null && seen.add(local.id)) tracks.add(local);
    }

    var start = tracks.indexWhere((t) => t.id == track.id);
    if (start < 0) {
      tracks.insert(0, library[track.id] ?? _resolve(track));
      start = 0;
    }

    await _install(tracks, start, token: token);
  }

  /// Starts a whole collection (本地, 收藏, a playlist) with list looping.
  /// Non-downloaded items are left out.
  Future<void> playCollection(
    List<Track> collection, {
    bool shuffle = false,
  }) async {
    final token = ++_selection;
    preparing.value = null;

    final library = await _library();
    if (token != _selection) return;

    final tracks = <Track>[];
    final seen = <String>{};
    for (final item in collection) {
      final local = library[item.id];
      if (local != null && seen.add(local.id)) tracks.add(local);
    }
    if (tracks.isEmpty) {
      _messages.add('没有已下载的歌曲可以播放');
      return;
    }

    _loopMode = LoopMode.all;
    final start = shuffle ? Random().nextInt(tracks.length) : 0;
    await _install(tracks, start, token: token, shuffle: shuffle);
  }

  /// Restores the last session, paused. Safe to call more than once.
  Future<void> restoreSession() async {
    if (_restoreStarted) return;
    _restoreStarted = true;
    if (_player.audioSources.isNotEmpty) return;

    final token = _selection;
    final session = await DatabaseService.loadPlaybackSession();
    if (session == null) return;

    final library = await _library();
    if (token != _selection) return;

    final tracks = [
      for (final id in session.trackIds)
        if (library[id] != null) library[id]!,
    ];
    if (tracks.isEmpty) return;

    var start = tracks.indexWhere((t) => t.id == session.currentId);
    final position = start < 0 ? Duration.zero : session.position;
    if (start < 0) start = 0;

    _loopMode = session.loopMode;
    await _install(
      tracks,
      start,
      token: token,
      position: position,
      autoplay: false,
      recordHistory: false,
      shuffle: session.shuffle,
    );
  }

  /// Persists the current session now.
  Future<void> saveSession() async {
    _sessionSaveTimer?.cancel();
    final sequence = _player.sequenceState.sequence;
    // Never overwrite a saved session with the empty state of a launch that
    // has not restored yet.
    if (sequence.isEmpty) return;

    await DatabaseService.savePlaybackSession(PlaybackSession(
      trackIds: [
        for (final source in sequence)
          if (_trackOf(source) != null) _trackOf(source)!.id,
      ],
      currentId: nowPlaying.value?.id,
      position: _player.position,
      shuffle: _player.shuffleModeEnabled,
      loopMode: _loopMode,
    ));
  }

  void _scheduleSessionSave() {
    _sessionSaveTimer?.cancel();
    _sessionSaveTimer =
        Timer(const Duration(seconds: 2), () => unawaited(saveSession()));
  }

  @override
  Future<void> play() async {
    _resumeAfterInterruption = false;
    if (_player.audioSources.isEmpty) {
      // A media button can cold-start the service before the UI restores.
      await restoreSession();
      if (_player.audioSources.isEmpty) return;
    }
    if (_player.processingState == ja.ProcessingState.completed) {
      final order = _order(_player.sequenceState);
      if (order.isNotEmpty) {
        await _player.seek(Duration.zero, index: order.first);
      }
    }
    _startPlayback();
  }

  @override
  Future<void> pause() async {
    _resumeAfterInterruption = false;
    await _player.pause();
  }

  Future<void> togglePlayPause() => _player.playing ? pause() : play();

  @override
  Future<void> stop() async {
    _resumeAfterInterruption = false;
    _idleTimer?.cancel();
    _progressSaveTimer?.cancel();
    _clearSleepTimer();
    await saveSession();
    await _player.stop();
    _broadcastState();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    // Swiping the app away while paused ends the session; while playing,
    // music keeps going like any other player.
    if (!_player.playing) await stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _skip(1);

  @override
  Future<void> skipToPrevious() async {
    if (_navTarget == null &&
        _player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    await _skip(-1);
  }

  /// Manual skips move through the queue even under repeat-one (only
  /// automatic advance repeats the track).
  Future<void> _skip(int offset) async {
    final state = _player.sequenceState;
    final order = _order(state);
    final from = _navTarget ?? state.currentIndex;
    if (order.isEmpty || from == null) return;

    final position = order.indexOf(from);
    if (position < 0) return;

    var next = position + offset;
    if (next >= order.length) {
      // Past the end of a non-looping queue: park at the start, paused.
      if (_loopMode == LoopMode.off) await _player.pause();
      next = 0;
    } else if (next < 0) {
      next = _loopMode == LoopMode.off ? 0 : order.length - 1;
    }

    final target = order[next];
    _navTarget = target;
    try {
      await _player.seek(Duration.zero, index: target);
    } finally {
      if (_navTarget == target) _navTarget = null;
    }
  }

  /// [index] is a position in play order (the published queue).
  @override
  Future<void> skipToQueueItem(int index) async {
    final order = _order(_player.sequenceState);
    if (index < 0 || index >= order.length) return;
    await _player.seek(Duration.zero, index: order[index]);
    if (!_player.playing) _startPlayback();
  }

  /// Jumps to a queued track by id (ids survive reshuffles; indices don't).
  Future<void> selectQueueTrack(String trackId) async {
    final index = queueNotifier.value.tracks.indexWhere((t) => t.id == trackId);
    if (index >= 0) await skipToQueueItem(index);
  }

  /// Drops tracks whose files were deleted.
  Future<void> removeTracks(Set<String> ids) async {
    final sequence = _player.sequenceState.sequence;
    for (var i = sequence.length - 1; i >= 0; i--) {
      final track = _trackOf(sequence[i]);
      if (track != null && ids.contains(track.id)) {
        await _player.removeAudioSourceAt(i);
      }
    }
    if (_player.sequenceState.sequence.isEmpty) {
      await _player.stop();
      _announce(null);
      _publish();
    }
  }

  /// 列表循环 → 单曲循环 → 随机播放 → 列表循环.
  Future<void> cyclePlayMode() async {
    if (_player.shuffleModeEnabled) {
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
    _loopMode = mode;
    await _applyNativeLoopMode();
    _publish();
  }

  Future<void> setShuffle(bool on) async {
    if (on) {
      // Reshuffle around the current track so it stays first.
      await _player.shuffle();
    }
    await _player.setShuffleModeEnabled(on);
    _publish();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      setLoopMode(switch (repeatMode) {
        AudioServiceRepeatMode.none => LoopMode.off,
        AudioServiceRepeatMode.one => LoopMode.one,
        _ => LoopMode.all,
      });

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      setShuffle(shuffleMode != AudioServiceShuffleMode.none);

  Future<void> _applyNativeLoopMode() => _player.setLoopMode(
        _autoAdvanceHolds > 0 || _loopMode == LoopMode.one
            ? ja.LoopMode.one
            : _loopMode == LoopMode.all
                ? ja.LoopMode.all
                : ja.LoopMode.off,
      );

  /// While held (lyric editing), the current track repeats instead of
  /// moving on, so the song being timed stays the song being heard.
  VoidCallback holdAutoAdvance() {
    _autoAdvanceHolds++;
    if (_autoAdvanceHolds == 1) unawaited(_applyNativeLoopMode());

    var released = false;
    return () {
      if (released) return;
      released = true;
      _autoAdvanceHolds--;
      if (_autoAdvanceHolds == 0) unawaited(_applyNativeLoopMode());
    };
  }

  /// Applies edited metadata to queued copies of the track.
  void updateTrackMetadata(Track updated) {
    _latest[updated.id] = updated;
    _publish();
  }

  // ---------------------------------------------------------------------------
  // Sleep timer
  // ---------------------------------------------------------------------------

  SleepTimerMode _sleepMode = SleepTimerMode.off;
  DateTime? _sleepDeadline;
  Timer? _sleepTimer;
  Timer? _sleepTicker;
  StreamSubscription<Duration>? _sleepPositionSub;

  /// Duration mode pauses after a fixed time; end-of-track pauses when the
  /// current song ends. Pausing keeps the timer; stop clears it.
  void setSleepTimer(SleepTimerMode mode, {Duration? duration}) {
    _clearSleepTimer(publish: false);

    switch (mode) {
      case SleepTimerMode.off:
        break;
      case SleepTimerMode.duration:
        final length = duration ?? const Duration(minutes: 30);
        if (length <= Duration.zero) break;
        _sleepMode = SleepTimerMode.duration;
        _sleepDeadline = DateTime.now().add(length);
        _sleepTimer = Timer(length, _fireSleepTimer);
      case SleepTimerMode.endOfTrack:
        if (nowPlaying.value == null) break;
        _sleepMode = SleepTimerMode.endOfTrack;
        _sleepPositionSub = _player.positionStream.listen((position) {
          final total = _player.duration;
          if (total == null || !_player.playing) return;
          if (total - position <= const Duration(milliseconds: 300)) {
            _fireSleepTimer();
          }
        });
    }

    if (_sleepMode != SleepTimerMode.off) {
      _sleepTicker = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _publishSleepTimer(),
      );
    }
    _publishSleepTimer();
  }

  void _fireSleepTimer() {
    if (_sleepMode == SleepTimerMode.off) return;
    _clearSleepTimer();
    unawaited(pause());
  }

  void _clearSleepTimer({bool publish = true}) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTicker?.cancel();
    _sleepTicker = null;
    unawaited(_sleepPositionSub?.cancel());
    _sleepPositionSub = null;
    _sleepMode = SleepTimerMode.off;
    _sleepDeadline = null;
    if (publish) _publishSleepTimer();
  }

  void _publishSleepTimer() {
    var remaining = Duration.zero;
    switch (_sleepMode) {
      case SleepTimerMode.off:
        break;
      case SleepTimerMode.duration:
        final deadline = _sleepDeadline;
        if (deadline != null) remaining = deadline.difference(DateTime.now());
      case SleepTimerMode.endOfTrack:
        final total = _player.duration ?? durationNotifier.value;
        remaining = total - _player.position;
    }
    sleepTimerNotifier.value = SleepTimerState(
      mode: _sleepMode,
      remaining: remaining.isNegative ? Duration.zero : remaining,
    );
  }

  /// Test-only teardown.
  @visibleForTesting
  Future<void> dispose() async {
    _idleTimer?.cancel();
    _sessionSaveTimer?.cancel();
    _progressSaveTimer?.cancel();
    _clearSleepTimer(publish: false);
    await _downloadRemovedSub?.cancel();
    await _messages.close();
  }
}
