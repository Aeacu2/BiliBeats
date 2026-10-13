import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeats/services/lyrics_engine.dart';

void main() {
  test('LyricsEngine.cleanTitle survives all 540 fixture Bilibili titles',
      () async {
    // The corpus is real videos' titles and uploaders: it is kept on the
    // developer's machine, not published with the code. Without it (a
    // fresh clone, CI) there is nothing to run against.
    final file = File('test/fixtures/real_bilibili_titles.json');
    if (!file.existsSync()) {
      markTestSkipped('test/fixtures/real_bilibili_titles.json is not here');
      return;
    }
    final List<dynamic> rawList =
        jsonDecode(await file.readAsString()) as List<dynamic>;
    expect(rawList, hasLength(540));

    for (final entry in rawList) {
      final title = entry['title'] as String;
      final uploader = entry['uploader'] as String;
      final parsed = LyricsEngine.cleanTitle(title, defaultArtist: uploader);
      expect(parsed['songTitle'], isNotNull,
          reason: 'songTitle was null for: $title');
      expect(parsed['songTitle'], isNotEmpty,
          reason: 'songTitle was empty for: $title');
    }
  });
}
