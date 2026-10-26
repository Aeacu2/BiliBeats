import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'database_service.dart';

/// The downloaded songs as files, in the system Files app (Android: a
/// read-only "BiliBeats" location served by `AudioFilesProvider`).
class AudioFolder {
  AudioFolder._();

  static const MethodChannel _channel = MethodChannel('bilibeats/files');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  // Lives as long as the app.
  // ignore: cancel_subscriptions
  static StreamSubscription<void>? _following;
  static Timer? _pending;

  /// Keeps a Files app that shows the folder up to date: it lists it again
  /// after the library changes (a download, a deletion, a new name), at
  /// most once a second.
  static void followLibrary() {
    if (!supported || _following != null) return;
    _following = DatabaseService.libraryUpdateStream.listen((_) {
      _pending?.cancel();
      _pending = Timer(const Duration(seconds: 1), () {
        unawaited(_channel.invokeMethod<void>('notifyAudioFiles').catchError(
            (Object e) => debugPrint('Audio folder notify failed: $e')));
      });
    });
  }

  /// Opens one song's file ([trackId]) in an app the listener picks; false
  /// when the file is not there or no app would open it.
  static Future<bool> openSong(String trackId) async {
    if (!supported) return false;
    try {
      return await _channel
              .invokeMethod<bool>('openAudioFile', {'id': trackId}) ??
          false;
    } catch (e) {
      debugPrint('Open audio file failed: $e');
      return false;
    }
  }

  /// Opens the folder; false when no app would show it.
  static Future<bool> open() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('openAudioFolder') ?? false;
    } catch (e) {
      debugPrint('Open audio folder failed: $e');
      return false;
    }
  }
}
