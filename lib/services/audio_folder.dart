import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_download_service.dart';
import 'database_service.dart';

/// The downloaded songs as files, in the system Files app (Android: a
/// read-only "BiliBeats" location served by `AudioFilesProvider`; macOS:
/// Finder; Windows: Explorer; Linux: file manager).
class AudioFolder {
  AudioFolder._();

  static const MethodChannel _channel = MethodChannel('bilibeats/files');

  static bool get supported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isMacOS ||
          Platform.isWindows ||
          Platform.isLinux);

  // Lives as long as the app.
  // ignore: cancel_subscriptions
  static StreamSubscription<void>? _following;
  static Timer? _pending;

  /// Returns the absolute path where audio files are stored.
  static Future<String> get path => AudioDownloadService.audioFolder();

  /// Keeps a Files app that shows the folder up to date: it lists it again
  /// after the library changes (a download, a deletion, a new name), at
  /// most once a second.
  static void followLibrary() {
    if (!supported || _following != null) return;
    if (!Platform.isAndroid) return;
    _following = DatabaseService.libraryUpdateStream.listen((_) {
      _pending?.cancel();
      _pending = Timer(const Duration(seconds: 1), () {
        unawaited(_channel.invokeMethod<void>('notifyAudioFiles').catchError(
            (Object e) => debugPrint('Audio folder notify failed: $e')));
      });
    });
  }

  /// Opens one song's file ([trackId]) in an app the listener picks (or
  /// reveals it in Finder / Explorer on desktop); false when the file is not
  /// there or no app would open it.
  static Future<bool> openSong(String trackId) async {
    if (!supported) return false;
    try {
      if (Platform.isAndroid) {
        return await _channel
                .invokeMethod<bool>('openAudioFile', {'id': trackId}) ??
            false;
      }

      final path = await AudioDownloadService.audioPathForId(trackId);
      final file = File(path);
      if (await file.exists()) {
        if (Platform.isMacOS) {
          // 'open -R <file>' reveals and selects the file in Finder
          final res = await Process.run('open', ['-R', path]);
          return res.exitCode == 0;
        } else if (Platform.isWindows) {
          final res = await Process.run('explorer.exe', ['/select,', path]);
          return res.exitCode == 0;
        } else if (Platform.isLinux) {
          final res = await Process.run('xdg-open', [file.parent.path]);
          return res.exitCode == 0;
        }
      }
      return await open();
    } catch (e) {
      debugPrint('Open audio file failed: $e');
      return false;
    }
  }

  /// Opens the folder; false when no app would show it.
  static Future<bool> open() async {
    if (!supported) return false;
    try {
      if (Platform.isAndroid) {
        return await _channel.invokeMethod<bool>('openAudioFolder') ?? false;
      }

      final folder = await AudioDownloadService.audioFolder();
      final dir = Directory(folder);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      if (Platform.isMacOS) {
        final res = await Process.run('open', [folder]);
        return res.exitCode == 0;
      } else if (Platform.isWindows) {
        final res = await Process.run('explorer.exe', [folder]);
        return res.exitCode == 0;
      } else if (Platform.isLinux) {
        final res = await Process.run('xdg-open', [folder]);
        return res.exitCode == 0;
      }
      return false;
    } catch (e) {
      debugPrint('Open audio folder failed: $e');
      return false;
    }
  }
}
