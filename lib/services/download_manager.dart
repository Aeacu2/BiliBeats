import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import 'audio_download_service.dart';

/// A live snapshot of an in-flight download.
///
/// There is no `status`: a task exists only while it is downloading, and is
/// removed on completion *or* failure. The old `DownloadStatus.failed` was
/// never assigned anywhere, so every `status == downloading` check in the app
/// was a tautology guarding unreachable state.
class DownloadTask {
  final Track track;

  /// 0..1, or 0 when the server sent no content length.
  final double fraction;

  const DownloadTask({required this.track, this.fraction = 0.0});

  DownloadTask copyWith({double? fraction}) =>
      DownloadTask(track: track, fraction: fraction ?? this.fraction);
}

/// A user-initiated download that failed, kept for the session so the
/// management view can offer Retry. Playback-path failures never land here:
/// only explicit user downloads are surfaced.
class FailedDownload {
  final Track track;
  final String error;
  final DateTime failedAt;

  const FailedDownload({
    required this.track,
    required this.error,
    required this.failedAt,
  });
}

/// Tracks user-initiated downloads with live progress so any screen can render
/// Apple Music–style rings and "X 下载中 / Y 已下载" counts.
///
/// Playback-path downloads (started inside the audio handler) are intentionally
/// NOT tracked here — only explicit user downloads are surfaced.
class DownloadManager {
  DownloadManager._() {
    AudioDownloadService.progressStream.listen(_onProgress);
  }
  static final DownloadManager instance = DownloadManager._();

  final Map<String, DownloadTask> _tasks = {};
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  /// Session failed downloads, newest first. Cleared per item on success,
  /// retry, or explicit dismiss. Never persisted: a restart re-discovers
  /// actual files instead of trusting stale failure records.
  final Map<String, FailedDownload> _failed = {};

  /// Emits the id of the track whose download state changed, so listeners
  /// can compare against their own id and sleep through everyone else's
  /// downloads. (Previously every listener ran on every progress tick of
  /// every download; N visible rows meant N wake-ups per 64 KiB chunk.)
  Stream<String> get updates => _controller.stream;

  /// Emits a human-readable message when a user-initiated download fails —
  /// without this a failure was indistinguishable from a success (the ring
  /// simply disappeared).
  Stream<String> get errors => _errorController.stream;

  /// Currently in-flight tasks, newest first.
  List<DownloadTask> get activeTasks =>
      _tasks.values.toList().reversed.toList();

  /// Failed downloads awaiting retry or dismissal, newest first.
  List<FailedDownload> get failedTasks {
    final list = _failed.values.toList()
      ..sort((a, b) => b.failedAt.compareTo(a.failedAt));
    return list;
  }

  DownloadTask? taskFor(String trackId) => _tasks[trackId];

  bool isDownloading(String trackId) => _tasks.containsKey(trackId);

  bool isFailed(String trackId) => _failed.containsKey(trackId);

  /// Moves a failed item back to active and retries. Returns false when
  /// there is nothing to retry.
  bool retryDownload(String trackId) {
    final failed = _failed.remove(trackId);
    if (failed == null) return false;
    if (_tasks.containsKey(trackId)) {
      _notify(trackId);
      return true;
    }
    _notify(trackId);
    unawaited(startDownload(failed.track));
    return true;
  }

  /// Drops a failed item without retrying.
  void dismissFailed(String trackId) {
    if (_failed.remove(trackId) != null) _notify(trackId);
  }

  // Guards double-tap while isDownloaded check is in flight.
  final Set<String> _pendingIsDownloadedCheck = {};

  /// Starts downloading [track] (idempotent). Observe progress via [updates].
  Future<void> startDownload(Track track) async {
    if (_tasks.containsKey(track.id)) return;
    if (_pendingIsDownloadedCheck.contains(track.id)) return;
    _pendingIsDownloadedCheck.add(track.id);
    bool alreadyDownloaded = false;
    try {
      alreadyDownloaded = await AudioDownloadService.isDownloaded(track);
    } catch (_) {
      alreadyDownloaded = false;
    }
    _pendingIsDownloadedCheck.remove(track.id);
    // If another call claimed the slot while we checked, bail.
    if (_tasks.containsKey(track.id)) return;
    if (alreadyDownloaded) return;
    // Claim the slot synchronously after the check, before any further await.
    _tasks[track.id] = DownloadTask(track: track);
    _failed.remove(track.id);
    _notify(track.id);
    try {
      await AudioDownloadService.ensureDownloaded(track);
    } catch (e) {
      debugPrint('Download failed: $e');
      _failed[track.id] = FailedDownload(
        track: track,
        error: '$e',
        failedAt: DateTime.now(),
      );
      if (!_errorController.isClosed) _errorController.add('$e');
    } finally {
      _tasks.remove(track.id);
      _notify(track.id);
    }
  }

  void _onProgress(DownloadProgress p) {
    final task = _tasks[p.trackId];
    if (task == null) {
      // Playback-path downloads are deliberately untracked, but their
      // completion still matters to the row showing that track. Relaying the
      // id here is what lets buttons drop their own subscription to the raw
      // chunk-frequency progress stream.
      if (p.done) _notify(p.trackId);
      return;
    }
    // Error events are preludes to startDownload's catch, which reports them.
    if (p.done || p.error != null) return;
    _tasks[p.trackId] = task.copyWith(fraction: p.fraction);
    _notify(p.trackId);
  }

  void _notify(String trackId) {
    if (!_controller.isClosed) _controller.add(trackId);
  }
}
