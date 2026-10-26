import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'audio_download_service.dart';
import 'audio_player_handler.dart';
import 'database_service.dart';
import 'accompaniment.dart';

/// What one import added.
class LocalImport {
  /// Songs new to the library.
  final List<Track> added;

  /// Songs the library already had (the same file imported before), as
  /// the library has them.
  final List<Track> existing;

  /// Files that were not audio, or could not be read.
  final int failed;

  const LocalImport(
      {this.added = const [], this.existing = const [], this.failed = 0});

  List<Track> get tracks => [...added, ...existing];
}

/// Songs from the phone's own storage: picked in 设置 → 导入本地歌曲, or
/// opened with (or shared to) BiliBeats from another app. Android only.
///
/// The native side (`LocalAudio.kt`) copies each file into the audio
/// folder and reads its tags; here the copy becomes a song in the library,
/// kept like a download. A song is named after its content (`local_` and
/// the start of its SHA-1), so the same file imported twice is one song.
/// Its name comes from the file's tags, else from the file name, and
/// counts as the listener's own: automatic matching leaves it alone.
class LocalSongs {
  LocalSongs._();

  static const MethodChannel _channel = MethodChannel('bilibeats/local');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static final StreamController<String> _messages =
      StreamController<String>.broadcast();

  /// Short notes for the listener about files opened with the app.
  static Stream<String> get messages => _messages.stream;

  /// Lets the listener pick audio files and imports them; null when no
  /// picker could be shown.
  static Future<LocalImport?> pick() async {
    if (!supported) return null;
    final copies = await _channel.invokeListMethod<Object?>('pick');
    if (copies == null) return null;
    return adopt(copies);
  }

  /// Plays the files opened with BiliBeats, from the launch on: those that
  /// started the app once [after] (restoring the last session) is done,
  /// and any opened while it runs.
  static void followOpened(BiliBeatsAudioHandler handler,
      {Future<void>? after}) {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened') await _playOpened(handler);
    });
    unawaited(Future(() async {
      try {
        await after;
      } catch (_) {}
      await _playOpened(handler);
    }));
  }

  static Future<void> _playOpened(BiliBeatsAudioHandler handler) async {
    try {
      final copies = await _channel.invokeListMethod<Object?>('takeOpened');
      if (copies == null || copies.isEmpty) return;
      final result = await adopt(copies);
      final tracks = result.tracks;
      if (tracks.isEmpty) {
        _messages.add('无法打开这个文件');
        return;
      }
      if (result.added.isNotEmpty) _messages.add('已加入资料库');
      await handler.playTrack(tracks.first);
    } catch (e) {
      debugPrint('Opening a file failed: $e');
      _messages.add('无法打开这个文件');
    }
  }

  /// Turns the native side's copies into songs in the library.
  @visibleForTesting
  static Future<LocalImport> adopt(List<Object?> copies) async {
    final added = <Track>[];
    final existing = <Track>[];
    var failed = 0;
    for (final raw in copies) {
      if (raw is! Map) {
        failed++;
        continue;
      }
      final copy = Map<String, Object?>.from(raw);
      final path = copy['path'];
      final hash = copy['hash'];
      if (path is! String ||
          hash is! String ||
          !RegExp(r'^[0-9a-f]{20,}$').hasMatch(hash)) {
        debugPrint('Local import skipped ${copy['name']}: ${copy['error']}');
        failed++;
        continue;
      }
      final file = File(path);
      final id = '${Track.localPrefix}${hash.substring(0, 20)}';
      try {
        final known = await DatabaseService.downloadedTrack(id);
        if (known != null) {
          await file.delete();
          existing.add(known);
          continue;
        }
        if (added.any((t) => t.id == id)) {
          await file.delete();
          continue;
        }
        final track = trackFrom(id, copy,
            coverUrl: await _saveCover(id, copy['picture']));
        await AudioDownloadService.adopt(track, file);
        await DatabaseService.saveDownloadedTrack(track);
        added.add(track);
      } catch (e) {
        debugPrint('Local import of ${copy['name']} failed: $e');
        failed++;
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
    return LocalImport(added: added, existing: existing, failed: failed);
  }

  /// The song a copy describes: its tags, else what its file name says.
  @visibleForTesting
  static Track trackFrom(String id, Map<String, Object?> copy,
      {String coverUrl = ''}) {
    String? text(String key) {
      final value = copy[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    final fromName = nameOf(text('name') ?? '');
    final durationMs = copy['durationMs'];
    var title = text('title') ?? fromName.title;
    var artist = text('artist') ?? fromName.artist ?? '未知歌手';
    // A backing track is credited to 伴奏, like one from Bilibili.
    if (Accompaniment.marks(title) || Accompaniment.marks(fromName.stem)) {
      title = Accompaniment.songOf(title);
      artist = Accompaniment.artist;
    }
    return Track(
      id: id,
      bvid: '',
      cid: 0,
      title: title,
      rawTitle: fromName.stem.isEmpty ? title : fromName.stem,
      uploader: artist,
      coverUrl: coverUrl,
      duration: durationMs is num ? (durationMs / 1000).round() : 0,
      named: true,
      matcher: 0,
    );
  }

  static final RegExp _extension = RegExp(r'\.[A-Za-z0-9]{1,5}$');
  static final RegExp _trackNumber = RegExp(r'^\d{1,3}\s*[-.、_]\s*');

  /// What a file name says: `周深 - 大鱼.mp3` is 大鱼 by 周深 (the way music
  /// apps name what they save), `03. 大鱼.flac` is 大鱼.
  @visibleForTesting
  static ({String stem, String title, String? artist}) nameOf(String file) {
    final stem = file.trim().replaceFirst(_extension, '').trim();
    final bare = stem.replaceFirst(_trackNumber, '').trim();
    final dash = bare.indexOf(' - ');
    if (dash > 0) {
      final artist = bare.substring(0, dash).trim();
      final title = bare.substring(dash + 3).trim();
      if (artist.isNotEmpty && title.isNotEmpty) {
        return (stem: stem, title: title, artist: artist);
      }
    }
    return (
      stem: stem,
      title: bare.isEmpty ? (stem.isEmpty ? '未知歌曲' : stem) : bare,
      artist: null,
    );
  }

  /// The file's own artwork, kept with the listener's picked covers.
  static Future<String> _saveCover(String id, Object? picture) async {
    if (picture is! Uint8List || picture.isEmpty) return '';
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/bilibeat_covers');
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File('${dir.path}/$id.img');
      await file.writeAsBytes(picture, flush: true);
      return file.path;
    } catch (e) {
      debugPrint('Local cover not saved: $e');
      return '';
    }
  }
}
