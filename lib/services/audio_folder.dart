import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The downloaded songs as files, in the system Files app (Android: a
/// read-only "BiliBeats" location served by `AudioFilesProvider`).
class AudioFolder {
  AudioFolder._();

  static const MethodChannel _channel = MethodChannel('bilibeats/files');

  static bool get supported => !kIsWeb && Platform.isAndroid;

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
