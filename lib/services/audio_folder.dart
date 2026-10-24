import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The downloaded songs as files, in the system Files app (Android: a
/// read-only "BiliBeats" location served by `AudioFilesProvider`).
class AudioFolder {
  AudioFolder._();

  static const MethodChannel _channel = MethodChannel('bilibeats/files');

  static bool get supported => !kIsWeb && Platform.isAndroid;

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
