import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import 'audio_download_service.dart';
import 'database_service.dart';
import 'download_manager.dart';
import 'store_files.dart';

@immutable
class ImportQueueState {
  const ImportQueueState(
      {this.pending = 0,
      this.failed = 0,
      this.completed = 0,
      this.paused = false});
  final int pending;
  final int failed;
  final int completed;
  final bool paused;
  int get total => completed + pending;
}

/// Shared persistent download queue for library and Bilibili imports.
class ImportDownloadQueue {
  ImportDownloadQueue._();

  static const String _file = 'bilibeat_import.json';

  /// Downloads running at once: quick enough for a whole library, slow
  /// enough not to look like a crawler to Bilibili.
  static const int _concurrency = 2;

  /// A song that failed this many times (a deleted video, usually) is no
  /// longer tried on every start.
  static const int _maxAttempts = 3;

  /// Songs still to fetch, with the times each has failed.
  static final List<({Track track, int attempts})> _pending = [];
  static final Set<String> _running = {};
  static final Map<String, Object> _jobTokens = {};
  static final Set<Object> _interrupted = {};

  /// Not tried twice in one run: what stopped it (no network, a video
  /// that is gone) is usually still there a second later.
  static final Set<String> _failedThisRun = {};
  static bool _loaded = false;
  static Future<void>? _loading;
  static bool _paused = false;
  static int _completed = 0;
  static int _generation = 0;
  static final ValueNotifier<ImportQueueState> status =
      ValueNotifier(const ImportQueueState());

  static List<Track> get queuedTracks => [
        for (final p in _pending)
          if (!_running.contains(p.track.id) &&
              !_failedThisRun.contains(p.track.id) &&
              p.attempts < _maxAttempts)
            p.track,
      ];

  static List<Track> get failedTracks => [
        for (final p in _pending)
          if (_failedThisRun.contains(p.track.id) || p.attempts >= _maxAttempts)
            p.track,
      ];

  static bool contains(String id) => _pending.any((p) => p.track.id == id);

  /// Songs an import has yet to download.
  static final ValueNotifier<int> remaining = ValueNotifier(0);

  /// Replaces the downloader in tests.
  @visibleForTesting
  static Future<bool> Function(Track track)? downloadWith;

  static Future<void> _load() => _loading ??= _readQueue();

  static Future<void> _readQueue() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final text = await StoreFiles.readText(_file);
      if (text == null) return;
      final payload = StoreFiles.unwrap(jsonDecode(text));
      _paused = payload is Map && payload['paused'] == true;
      _completed = payload is Map && payload['completed'] is int
          ? payload['completed'] as int
          : 0;
      final items = payload is Map ? payload['items'] : payload;
      final queued = {for (final p in _pending) p.track.id};
      for (final raw in items as List? ?? const []) {
        if (raw is! Map) continue;
        final track =
            Track.fromMap(Map<String, dynamic>.from(raw['track'] as Map));
        if (!queued.add(track.id)) continue;
        _pending.add((
          track: track,
          attempts: (raw['attempts'] as num?)?.toInt() ?? 0,
        ));
      }
    } catch (e) {
      debugPrint('ImportDownloadQueue queue skipped: $e');
      // A damaged or newer queue may be the only record of unfinished work.
      await StoreFiles.setAside(_file);
    }
  }

  static Future<void> _save() async {
    try {
      await StoreFiles.write(_file, {
        'paused': _paused,
        'completed': _completed,
        'items': [
          for (final p in _pending)
            {'track': trackMapForTransfer(p.track), 'attempts': p.attempts}
        ],
      });
    } catch (e) {
      debugPrint('ImportDownloadQueue queue not saved: $e');
    }
  }

  static Future<int> enqueueDownloads(List<Track> tracks) async {
    await _load();
    final here = {
      for (final t in await DatabaseService.getDownloadedTracks()) t.id
    };
    if (_pending.isEmpty) _completed = 0;
    final queued = {for (final p in _pending) p.track.id};
    var added = 0;
    for (final track in tracks) {
      if (here.contains(track.id)) continue;
      // Do not reorder or reset work that is already queued or running.
      if (!queued.add(track.id)) continue;
      added++;
      _failedThisRun.remove(track.id);
      _pending.add((track: track, attempts: 0));
      _jobTokens[track.id] = Object();
    }
    await _save();
    _pump();
    return added;
  }

  static Future<void> pause() async {
    await _load();
    _paused = true;
    for (final id in _running) {
      final token = _jobTokens[id];
      if (token != null) _interrupted.add(token);
      DownloadManager.instance.cancelDownload(id);
    }
    await _save();
    _pump();
  }

  static Future<void> continueDownloads() async {
    await _load();
    _paused = false;
    await _save();
    _pump();
  }

  static Future<void> cancelTrack(String id) async {
    await _load();
    _pending.removeWhere((p) => p.track.id == id);
    if (DownloadManager.instance.isFailed(id)) {
      DownloadManager.instance.dismissFailed(id);
    }
    _jobTokens.remove(id);
    _failedThisRun.remove(id);
    DownloadManager.instance.cancelDownload(id);
    await _save();
    _pump();
  }

  static Future<void> cancelAll() async {
    await _load();
    for (final p in _pending) {
      if (DownloadManager.instance.isFailed(p.track.id)) {
        DownloadManager.instance.dismissFailed(p.track.id);
      }
    }
    _pending.clear();
    _jobTokens.clear();
    _failedThisRun.clear();
    _completed = 0;
    _paused = false;
    for (final id in _running) {
      DownloadManager.instance.cancelDownload(id);
    }
    await _save();
    _pump();
  }

  static Future<void> retryTrack(String id) async {
    await _load();
    final at = _pending.indexWhere((p) => p.track.id == id);
    if (at == -1) return;
    _pending[at] = (track: _pending[at].track, attempts: 0);
    _failedThisRun.remove(id);
    await _save();
    _pump();
  }

  static Future<void> retryFailed() async {
    await _load();
    for (var i = 0; i < _pending.length; i++) {
      final p = _pending[i];
      if (_failedThisRun.contains(p.track.id) || p.attempts >= _maxAttempts) {
        _pending[i] = (track: p.track, attempts: 0);
      }
    }
    _failedThisRun.clear();
    await _save();
    _pump();
  }

  /// Carries on with an import the last run of the app did not finish.
  static Future<void> resume() async {
    await _load();
    _pump();
  }

  static void _pump() {
    bool waiting(({Track track, int attempts}) p) =>
        p.attempts < _maxAttempts && !_failedThisRun.contains(p.track.id);
    remaining.value = _pending.where(waiting).length;
    status.value = ImportQueueState(
      pending: _pending.length,
      failed: _pending.where((p) => !waiting(p)).length,
      completed: _completed,
      paused: _paused,
    );
    if (_paused) return;
    for (final next in List.of(_pending)) {
      if (_running.length >= _concurrency) return;
      if (!waiting(next)) continue;
      if (!_running.add(next.track.id)) continue;
      final token = _jobTokens.putIfAbsent(next.track.id, Object.new);
      unawaited(_fetch(next.track, _generation, token));
    }
  }

  static Future<bool> _download(Track track) async {
    await DownloadManager.instance.startDownload(track);
    return AudioDownloadService.isDownloaded(track);
  }

  static Future<void> _fetch(Track track, int generation, Object token) async {
    var done = false;
    try {
      done = await (downloadWith ?? _download)(track);
    } catch (e) {
      debugPrint('ImportDownloadQueue download failed: $e');
    }
    if (generation != _generation) return;
    final interrupted = _interrupted.remove(token);
    final at = identical(_jobTokens[track.id], token)
        ? _pending.indexWhere((p) => p.track.id == track.id)
        : -1;
    if (at != -1) {
      if (done) {
        _pending.removeAt(at);
        _jobTokens.remove(track.id);
        _completed++;
      } else if (!_paused && !interrupted) {
        final failed = _pending[at];
        _pending[at] = (track: failed.track, attempts: failed.attempts + 1);
        _failedThisRun.add(track.id);
      }
    }
    await _save();
    _running.remove(track.id);
    _pump();
  }

  @visibleForTesting
  static void resetForTest() {
    _generation++;
    _interrupted.clear();
    _jobTokens.clear();
    _pending.clear();
    _running.clear();
    _failedThisRun.clear();
    _loaded = false;
    _loading = null;
    _paused = false;
    _completed = 0;
    remaining.value = 0;
    status.value = const ImportQueueState();
    downloadWith = null;
  }
}

/// Track fields that can be transferred safely to another device.
Map<String, dynamic> trackMapForTransfer(Track t) {
  final map = t.toMap()
    ..remove('audioUrl') // signed for one device and one hour
    ..remove('loudness'); // measured again with the download
  // Artwork picked on this device is a path that exists only here.
  if (!t.coverUrl.startsWith('http')) map.remove('coverUrl');
  return map;
}
