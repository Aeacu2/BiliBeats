import 'dart:io';

import 'package:bilibeats/services/audio_folder.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AudioFolder is supported on desktop and mobile platforms', () {
    expect(AudioFolder.supported, isTrue);
  });

  test('AudioFolder.path returns valid local audio folder path', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('bilibeat_folder_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return tempDir.path;
      }
      return null;
    });

    final folder = await AudioFolder.path;
    expect(folder, isNotEmpty);
    expect(folder.endsWith('bilibeat_audio'), isTrue);
  });
}
