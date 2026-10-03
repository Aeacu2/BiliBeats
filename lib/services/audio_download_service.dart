import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'bili_http.dart';
import 'bilibili_sdk.dart';
import 'database_service.dart';

/// Immutable snapshot of a single track download's progress.
class DownloadProgress {
  final String trackId;
  final int receivedBytes;
  final int? totalBytes;
  final bool done;
  final String? error;

  const DownloadProgress(
    this.trackId,
    this.receivedBytes,
    this.totalBytes,
    this.done,
    this.error,
  );

  double get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return 0.0;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
}

/// Downloads Bilibili audio to disk so playback is always served from a local
/// file. The native player (ExoPlayer / AVPlayer) reads straight from disk with
/// zero extra hops, no Dart-isolate byte forwarding, and no cleartext/ATS
/// issues on iOS.
///
/// Files are keyed by the full track id (`bvid_cid`), which uniquely identifies
/// a single playable part. Keying by `bvid` alone would collide across the
/// parts (P1/P2/…) of a multi-part video and play the wrong audio.
class AudioDownloadService {
  AudioDownloadService._();

  static final HttpClient _client = biliHttpClient(
    connectionTimeout: const Duration(seconds: 15),
    idleTimeout: const Duration(seconds: 60),
  );

  static String? _dirPath;

  /// Deduplicates concurrent downloads of the same track.
  static final Map<String, Future<String>> _inFlight = {};

  static final StreamController<DownloadProgress> _progressController =
      StreamController<DownloadProgress>.broadcast();

  /// Broadcast stream of download progress events (throttled per chunk batch).
  static Stream<DownloadProgress> get progressStream =>
      _progressController.stream;

  static Future<String> _dir() async {
    final cached = _dirPath;
    if (cached != null) return cached;
    final docs = await getApplicationDocumentsDirectory();
    final path = '${docs.path}/bilibeat_audio';
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dirPath = path;
    return path;
  }

  /// Stable per-part key. Falls back to bvid only for the (rare) track built
  /// without a usable id.
  static String _key(Track track) {
    if (track.id.isNotEmpty) return track.id;
    if (track.bvid.isNotEmpty) return track.bvid;
    throw StateError('Track has empty id and bvid: $track');
  }

  static String _audioPath(String dir, String key) => '$dir/audio_$key.m4a';

  /// Where [id]'s audio lives once downloaded. Does not check existence —
  /// callers pair it with [isDownloadedById] or the downloaded library.
  static Future<String> audioPathForId(String id) async =>
      _audioPath(await _dir(), id);
  static String _readyPath(String dir, String key) => '$dir/audio_$key.ready';
  static String _metaPath(String dir, String key) => '$dir/audio_$key.json';

  static Future<void> _atomicWriteString(String path, String content) async {
    final tmp = File('$path.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsString(content, flush: true);
    final target = File(path);
    // Only Windows needs the target gone before a rename (see
    // DatabaseService._writeJsonAtomically).
    if (Platform.isWindows && await target.exists()) {
      try {
        await target.delete();
      } catch (e) {
        debugPrint('_atomicWriteString delete failed: $e');
      }
    }
    await tmp.rename(path);
  }

  /// Saves track metadata JSON next to the audio file (used for rediscovery).
  ///
  /// Playback calls this on every start, with whatever `Track` object the
  /// caller happens to be holding — which may predate an edit the user made in
  /// 编辑信息. Writing that unconditionally silently reverted the edit on
  /// disk, so by default this only *creates* the file. Deliberate edits pass
  /// [force] to overwrite.
  static Future<void> saveTrackMetadata(Track track,
      {bool force = false}) async {
    try {
      final dir = await _dir();
      final key = _key(track);
      final metaPath = _metaPath(dir, key);
      final metaFile = File(metaPath);
      if (!force && await metaFile.exists()) return;
      final encoded = jsonEncode(track.toMap());
      if (await metaFile.exists()) {
        try {
          if (await metaFile.readAsString() == encoded) return;
        } catch (_) {}
      }
      await _atomicWriteString(metaPath, encoded);
    } catch (e) {
      debugPrint('saveTrackMetadata error: $e');
    }
  }

  /// Memoised answers for [isDownloadedById].
  ///
  /// Every row of every list asks this on build, and each answer costs three
  /// filesystem round-trips — a screenful of search results was ~90 stat calls
  /// for a set of files only this class ever creates or removes. It is
  /// therefore safe to remember: the map is updated wherever the on-disk state
  /// changes (a completed download, a delete), so it cannot go stale except by
  /// something outside the app deleting files under us.
  static final Map<String, bool> _downloadedMemo = {};

  /// Bounds for the memo: every search row ever queried would otherwise
  /// accumulate for the whole app lifetime.
  static const int _memoCap = 1024;

  /// True when a complete, verified audio file exists on disk for [track].
  static Future<bool> isDownloaded(Track track) =>
      isDownloadedById(_key(track));

  /// String-id variant of [isDownloaded] for callers that only hold an id.
  static Future<bool> isDownloadedById(String id) async {
    final memo = _downloadedMemo[id];
    if (memo != null) return memo;
    final result = await _statDownloaded(id);
    _downloadedMemo[id] = result;
    if (_downloadedMemo.length > _memoCap) {
      _downloadedMemo.remove(_downloadedMemo.keys.first);
    }
    return result;
  }

  static Future<bool> _statDownloaded(String id) async {
    final dir = await _dir();
    final audio = File(_audioPath(dir, id));
    final ready = File(_readyPath(dir, id));
    if (!await ready.exists()) return false;
    if (!await audio.exists()) return false;
    return await audio.length() > 0;
  }

  /// Per-track on-disk audio sizes in one directory listing: track id to
  /// bytes of the verified `.m4a` file. Only files with a sibling `.ready`
  /// marker count, matching [isDownloaded] semantics; partials and orphans
  /// are excluded. Used by download management for per-track and aggregate
  /// storage display without N stat calls.
  static Future<Map<String, int>> storageBreakdown() async {
    final result = <String, int>{};
    try {
      final dir = await _dir();
      await for (final entity in Directory(dir).list()) {
        if (entity is! File) continue;
        // URI segments always use `/`, unlike platform paths.
        final segments = entity.uri.pathSegments;
        if (segments.isEmpty) continue;
        final name = segments.last;
        if (!name.startsWith('audio_') || !name.endsWith('.m4a')) continue;
        final id = name.substring('audio_'.length, name.length - '.m4a'.length);
        if (id.isEmpty) continue;
        final ready = File('$dir/audio_$id.ready');
        if (!await ready.exists()) continue;
        try {
          result[id] = await entity.length();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('storageBreakdown error: $e');
    }
    return result;
  }

  /// Removes a track's audio, ready-marker and metadata from disk.
  /// Returns true when something was actually deleted.
  static Future<bool> delete(Track track) async {
    final dir = await _dir();
    String id;
    try {
      id = _key(track);
    } catch (_) {
      return false;
    }
    var deleted = false;
    // Delete in order: ready first so _statDownloaded immediately returns false,
    // then audio, then meta, then part. This avoids stale ready->false but m4a orphan.
    for (final path in [
      _readyPath(dir, id),
      _audioPath(dir, id),
      _metaPath(dir, id),
      '${_audioPath(dir, id)}.part',
    ]) {
      final file = File(path);
      try {
        if (await file.exists()) {
          await file.delete();
          deleted = true;
        }
      } catch (e) {
        debugPrint('delete download error: $e');
      }
    }
    _downloadedMemo[id] = false;
    return deleted;
  }

  /// Invalidate memo for an id whose file was externally removed or discovered missing.
  static void invalidateMemo(String id) {
    _downloadedMemo.remove(id);
  }

  /// Ensures [track]'s audio is fully downloaded and returns the local path.
  ///
  /// Idempotent and concurrency-safe: a second call for the same track while a
  /// download is in flight awaits the same future instead of downloading twice.
  static Future<String> ensureDownloaded(Track track) async {
    String id;
    try {
      id = _key(track);
    } catch (e) {
      debugPrint('ensureDownloaded invalid track: $e');
      throw Exception('无效曲目id');
    }
    final existing = _inFlight[id];
    if (existing != null) return existing;
    // Claim synchronously before any await to prevent parallel .part writes
    final completer = Completer<String>();
    _inFlight[id] = completer.future;
    try {
      final dir = await _dir();
      final path = _audioPath(dir, id);
      await saveTrackMetadata(track);
      if (await isDownloadedById(id)) {
        completer.complete(path);
        return path;
      }
      final result = await _download(track, dir, path);
      completer.complete(result);
      return result;
    } catch (e, st) {
      completer.completeError(e, st);
      // The dedup future may have no listener yet (or anymore): without
      // this, a failed download reports an unhandled async error even
      // though every path through here rethrows into a guarded caller.
      // Existing listeners still receive the error normally.
      completer.future.ignore();
      rethrow;
    } finally {
      _inFlight.remove(id);
    }
  }

  static Future<String> _download(Track track, String dir, String path) async {
    var url = track.audioUrl;
    if (url == null || url.isEmpty) {
      final info = await BilibiliSdk.fetchAudioStream(track.bvid, track.cid);
      url = info?['url'];
      final loudness = double.tryParse(info?['loudness'] ?? '');
      if (loudness != null) track = track.copyWith(loudness: loudness);
    }
    if (url == null || url.isEmpty) {
      _emit(DownloadProgress(track.id, 0, null, false, '无法获取音源下载链接'));
      throw Exception('无法获取音源下载链接');
    }

    final tmp = File('$path.part');
    IOSink? sink;
    var lastEmitted = 0;
    try {
      final req = await _client.getUrl(Uri.parse(url));
      req.headers.set('Referer', 'https://www.bilibili.com/');
      req.headers.set('User-Agent', kBiliUserAgent);
      req.headers.set('Accept', '*/*');
      req.headers.set('Accept-Encoding', 'identity');

      // Resume an interrupted download when a .part file survived: ask for
      // the remaining range. A server that ignores Range answers 200 with
      // the whole file, which is detected below and starts from scratch.
      final existing = await tmp.exists() ? await tmp.length() : 0;
      if (existing > 0) {
        req.headers.set('Range', 'bytes=$existing-');
      }

      final res = await req.close().timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException('CDN close timeout'),
          );
      // A .part that already covers the whole file (e.g. a crash between the
      // rename and the .ready marker) makes the CDN answer 416. The bytes on
      // disk are complete — finalize them instead of failing the download.
      if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          existing > 0) {
        await res.drain<void>();
        final destination = File(path);
        if (await destination.exists()) {
          try {
            await destination.delete();
          } catch (e) {
            debugPrint('416 finalize delete failed: $e');
          }
        }
        // Atomic rename with Windows fallback.
        try {
          await tmp.rename(path);
        } catch (e) {
          // Windows: target exists or lock. Try copy+delete fallback.
          debugPrint('416 rename failed, trying copy: $e');
          await tmp.copy(path);
          try {
            await tmp.delete();
          } catch (_) {}
        }
        // Ready marker: atomic create (empty file). Ensure after rename.
        try {
          final readyFile = File(_readyPath(dir, _key(track)));
          if (!await readyFile.exists()) {
            await readyFile.create(recursive: true);
          }
        } catch (e) {
          debugPrint('416 ready create failed: $e');
        }
        await saveTrackMetadata(track, force: track.loudness != null);
        _downloadedMemo[_key(track)] = true;
        _emit(DownloadProgress(track.id, existing, existing, true, null));
        await DatabaseService.saveDownloadedTrack(track);
        return path;
      }
      if (res.statusCode != HttpStatus.ok &&
          res.statusCode != HttpStatus.partialContent) {
        await res.drain<void>();
        throw Exception('CDN HTTP ${res.statusCode}');
      }
      // A signed CDN link that has expired answers 200 with an HTML/JSON error
      // body; writing that to disk would leave a permanently "downloaded"
      // track that cannot play.
      final contentType = res.headers.contentType?.mimeType ?? '';
      if (contentType.startsWith('text/') || contentType.contains('json')) {
        await res.drain<void>();
        throw Exception('CDN 返回了非音频内容 ($contentType)');
      }

      final int? total;
      var received = 0;
      if (res.statusCode == HttpStatus.partialContent) {
        // 206: the server honored the range — append to what is on disk.
        received = existing;
        lastEmitted = existing;
        total = res.contentLength > 0 ? existing + res.contentLength : null;
        sink = tmp.openWrite(mode: FileMode.append);
      } else {
        // 200 after a Range request means the server ignored it; the body is
        // the entire file, so whatever the .part holds is unusable.
        if (existing > 0) {
          await tmp.delete();
        }
        total = res.contentLength > 0 ? res.contentLength : null;
        sink = tmp.openWrite();
      }

      // Apply read timeout per chunk: stall >30s is failure. res itself has no
      // idle timeout once headers arrived; chunk stream can hang forever.
      final timeoutRes = res.timeout(
        const Duration(seconds: 30),
        onTimeout: (sink) =>
            sink.addError(TimeoutException('CDN chunk timeout')),
      );
      await for (final chunk in timeoutRes) {
        sink.add(chunk);
        received += chunk.length;
        // Throttle progress events to ~every 64 KiB to avoid stream spam.
        if (received - lastEmitted >= 65536) {
          lastEmitted = received;
          _emit(DownloadProgress(track.id, received, total, false, null));
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      // Truncated transfer (dropped connection mid-stream): fail loudly rather
      // than marking a half file as ready.
      if (total != null && received < total) {
        throw Exception('下载不完整 ($received/$total 字节)');
      }
      if (received < 1024) {
        throw Exception('音频文件异常 ($received 字节)');
      }

      final destination = File(path);
      if (await destination.exists()) {
        try {
          await destination.delete();
        } catch (e) {
          debugPrint('finalize delete failed: $e');
        }
      }
      try {
        await tmp.rename(path);
      } catch (e) {
        debugPrint('finalize rename failed, trying copy: $e');
        try {
          await tmp.copy(path);
          try {
            await tmp.delete();
          } catch (_) {}
        } catch (e2) {
          debugPrint('finalize copy failed: $e2');
          rethrow;
        }
      }
      try {
        final readyFile = File(_readyPath(dir, _key(track)));
        if (!await readyFile.exists()) {
          await readyFile.create(recursive: true);
        }
      } catch (e) {
        debugPrint('ready create failed: $e');
      }
      await saveTrackMetadata(track, force: track.loudness != null);
      _downloadedMemo[_key(track)] = true;

      _emit(DownloadProgress(track.id, received, total, true, null));
      await DatabaseService.saveDownloadedTrack(track);
      return path;
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      // Deliberately keep the .part file: the next attempt resumes it via
      // Range instead of re-downloading from byte 0. Corrupt or unwanted
      // partial data is handled there (a 200 answer restarts from scratch).
      _emit(DownloadProgress(track.id, 0, null, false, '$e'));
      rethrow;
    }
  }

  static void _emit(DownloadProgress p) {
    if (!_progressController.isClosed) _progressController.add(p);
  }
}
