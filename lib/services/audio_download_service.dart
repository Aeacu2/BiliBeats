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
    final key = track.id.isNotEmpty ? track.id : track.bvid;
    if (key.isEmpty) throw StateError('Track has empty id and bvid: $track');
    if (!isSafeKey(key)) throw StateError('Track id is not a file name: $key');
    return key;
  }

  static final RegExp _safeKey = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  /// Ids come from Bilibili's answers and end up in file names. A real one
  /// is letters, digits and `_`; anything else (a path separator, `..`)
  /// names no download and is never turned into a path.
  @visibleForTesting
  static bool isSafeKey(String key) => _safeKey.hasMatch(key);

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
    if (!isSafeKey(id)) return false;
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
      _partNotePath(_audioPath(dir, id)),
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

    final part = File('$path.part');
    final note = File(_partNotePath(path));
    try {
      // A partial file that turns out not to be the start of what the
      // server has now is thrown away, and the transfer made once more
      // from the first byte.
      var done = await _transfer(url, part, note, track.id);
      done ??= await _transfer(url, part, note, track.id);
      if (done == null) throw Exception('下载无法续传');

      final destination = File(path);
      if (await destination.exists()) {
        try {
          await destination.delete();
        } catch (e) {
          debugPrint('finalize delete failed: $e');
        }
      }
      try {
        await part.rename(path);
      } catch (e) {
        // Windows: target exists or is locked. Copy, then drop the part.
        debugPrint('finalize rename failed, trying copy: $e');
        await part.copy(path);
        try {
          await part.delete();
        } catch (_) {}
      }
      try {
        if (await note.exists()) await note.delete();
      } catch (_) {}
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

      _emit(DownloadProgress(track.id, done.received, done.total, true, null));
      await DatabaseService.saveDownloadedTrack(track);
      return path;
    } catch (e) {
      // Deliberately keep the .part file: the next attempt resumes it via
      // Range instead of re-downloading from byte 0 (see [_transfer] for
      // how a partial file that no longer fits is recognised).
      _emit(DownloadProgress(track.id, 0, null, false, '$e'));
      rethrow;
    }
  }

  static String _partNotePath(String audioPath) => '$audioPath.part.json';

  /// What a `.part` file is the beginning of: the full length of the file
  /// it was cut from, and the server's validator (ETag / Last-Modified) for
  /// it. Null when there is no usable note.
  static Future<({int? total, String? validator})?> _readPartNote(
      File note) async {
    try {
      if (!await note.exists()) return null;
      final map = jsonDecode(await note.readAsString());
      if (map is! Map) return null;
      final total = map['total'];
      final validator = map['validator'];
      return (
        total: total is int && total > 0 ? total : null,
        validator:
            validator is String && validator.isNotEmpty ? validator : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// A validator the server will compare exactly: a strong ETag, else the
  /// modification date. (`If-Range` ignores weak ETags.)
  static String? _validatorOf(HttpClientResponse res) {
    final etag = res.headers.value(HttpHeaders.etagHeader);
    if (etag != null && etag.isNotEmpty && !etag.startsWith('W/')) return etag;
    return res.headers.value(HttpHeaders.lastModifiedHeader);
  }

  static final RegExp _contentRange = RegExp(r'bytes\s+(\d+)-\d+/(\d+|\*)');

  static Future<void> _discardPart(File part, File note) async {
    for (final file in [part, note]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('discard partial download failed: $e');
      }
    }
  }

  /// Brings [part] up to the whole of [url], resuming what is already there.
  ///
  /// Every attempt asks Bilibili for a fresh link, which may be a different
  /// file — another bitrate, another encode. Bytes appended to the start of
  /// a different file make audio that is marked downloaded and cannot play,
  /// so a partial file is only continued when it is known to belong to this
  /// one: the note written beside it ([_readPartNote]) must agree with the
  /// server on the validator (sent as `If-Range`, so a changed file comes
  /// back whole) and on the total length.
  ///
  /// Returns the byte counts once [part] is complete, or null when the
  /// partial file had to be thrown away — call again to start from zero.
  static Future<({int received, int? total})?> _transfer(
    String url,
    File part,
    File note,
    String trackId,
  ) async {
    var existing = await part.exists() ? await part.length() : 0;
    final known = existing > 0 ? await _readPartNote(note) : null;
    if (existing > 0 && known == null) {
      // Nothing says what these bytes are the start of.
      await _discardPart(part, note);
      existing = 0;
    }

    final req = await _client.getUrl(Uri.parse(url));
    req.headers.set('Referer', 'https://www.bilibili.com/');
    req.headers.set('User-Agent', kBiliUserAgent);
    req.headers.set('Accept', '*/*');
    req.headers.set('Accept-Encoding', 'identity');
    if (existing > 0) {
      req.headers.set('Range', 'bytes=$existing-');
      final validator = known?.validator;
      if (validator != null) req.headers.set('If-Range', validator);
    }

    final res = await req.close().timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('CDN close timeout'),
        );

    // 416: nothing lies beyond what is on disk. That is a finished file
    // (e.g. a crash between the last byte and the rename) only when the
    // length is the one recorded for it.
    if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        existing > 0) {
      await res.drain<void>();
      if (known?.total == existing) {
        return (received: existing, total: existing);
      }
      await _discardPart(part, note);
      return null;
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
    final IOSink sink;
    if (res.statusCode == HttpStatus.partialContent && existing > 0) {
      // 206: the rest of a file — the same one only if it starts where the
      // partial file ends, is as long as recorded, and carries the same
      // validator.
      final range = _contentRange
          .firstMatch(res.headers.value(HttpHeaders.contentRangeHeader) ?? '');
      final start = int.tryParse(range?.group(1) ?? '');
      final full = int.tryParse(range?.group(2) ?? '');
      final validator = _validatorOf(res);
      final same = start == existing &&
          (known?.total == null || full == null || full == known?.total) &&
          (known?.validator == null ||
              validator == null ||
              validator == known?.validator) &&
          // With neither to go by there is no telling.
          (known?.validator != null || (known?.total != null && full != null));
      if (!same) {
        // Not read: the body is the tail of some other file.
        await res.listen((_) {}).cancel();
        await _discardPart(part, note);
        return null;
      }
      received = existing;
      total =
          full ?? (res.contentLength > 0 ? existing + res.contentLength : null);
      sink = part.openWrite(mode: FileMode.append);
    } else if (res.statusCode == HttpStatus.partialContent) {
      // A range nobody asked for.
      await res.listen((_) {}).cancel();
      throw Exception('CDN 返回了未请求的分段内容');
    } else {
      // 200: the whole file, from the first byte — a fresh download, or a
      // server saying (through If-Range) that the file has changed, or one
      // that ignores Range. Whatever the .part holds is replaced.
      total = res.contentLength > 0 ? res.contentLength : null;
      await _discardPart(part, note);
      try {
        await note.writeAsString(
          jsonEncode({'total': total, 'validator': _validatorOf(res)}),
          flush: true,
        );
      } catch (e) {
        // Without the note this download simply cannot be resumed.
        debugPrint('part note write failed: $e');
      }
      sink = part.openWrite();
    }

    var lastEmitted = received;
    try {
      // Apply read timeout per chunk: stall >30s is failure. res itself has
      // no idle timeout once headers arrived; chunk stream can hang forever.
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
          _emit(DownloadProgress(trackId, received, total, false, null));
        }
      }
      await sink.flush();
    } finally {
      try {
        await sink.close();
      } catch (_) {}
    }

    // Truncated transfer (dropped connection mid-stream): fail loudly rather
    // than marking a half file as ready.
    if (total != null && received < total) {
      throw Exception('下载不完整 ($received/$total 字节)');
    }
    if (received < 1024) {
      throw Exception('音频文件异常 ($received 字节)');
    }
    return (received: received, total: total);
  }

  static void _emit(DownloadProgress p) {
    if (!_progressController.isClosed) _progressController.add(p);
  }
}
