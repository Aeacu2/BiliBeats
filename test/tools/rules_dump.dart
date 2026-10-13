@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/models/video_hints.dart';
import 'package:bilibeats/services/lyrics_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../audio_test_harness.dart';

/// What the matcher says about each video of a labelled set, for
/// tool/song_model (which compares it with the model and the labels).
///
///   RULES_IN=videos.json RULES_OUT=answers.json RULES_CACHE=netease.jsonl \
///     flutter test test/tools/rules_dump.dart --tags live
///
/// The input is a JSON list (or JSON lines) of
/// `{bvid, title, up, dur, tags, zone?, desc?, music: {t, a}?}`.
void main() {
  setUpAll(useRealHttp);

  test('dump', () async {
    final input = Platform.environment['RULES_IN'];
    final output = Platform.environment['RULES_OUT'];
    if (input == null || output == null) {
      markTestSkipped('RULES_IN / RULES_OUT not set');
      return;
    }
    final text = File(input).readAsStringSync().trim();
    final videos = (text.startsWith('[')
            ? jsonDecode(text) as List
            : [
                for (final l in const LineSplitter().convert(text))
                  jsonDecode(l)
              ])
        .cast<Map>();
    LyricsEngine.knownArtists = ['周深'];
    // RULES_CACHE: a file of answers already had from NetEase, so that a
    // changed rule is measured on the same evidence, in seconds.
    final cachePath = Platform.environment['RULES_CACHE'];
    final cacheFile = cachePath == null ? null : File(cachePath);
    final cache = <String, String>{};
    if (cacheFile != null && cacheFile.existsSync()) {
      for (final l in cacheFile.readAsLinesSync()) {
        final e = jsonDecode(l) as List;
        cache[e[0] as String] = e[1] as String;
      }
    }
    final fresh = cacheFile?.openWrite(mode: FileMode.append);
    final pending = <String, Future<String?>>{};
    if (cacheFile != null) {
      LyricsEngine.httpCache = (url, fetch) {
        final known = cache[url];
        if (known != null) return Future.value(known);
        return pending[url] ??= fetch().then((body) {
          if (body != null) {
            cache[url] = body;
            fresh!.writeln(jsonEncode([url, body]));
          }
          pending.remove(url);
          return body;
        });
      };
    }
    final answers = List<Map<String, Object?>>.filled(videos.length, const {});
    for (var i = 0; i < videos.length; i += 6) {
      await Future.wait([
        for (var k = i; k < videos.length && k < i + 6; k++)
          () async {
            final v = videos[k];
            final music = v['music'] as Map?;
            final hints = VideoHints(
              tags: List<String>.from(v['tags'] as List? ?? const []),
              description: v['desc'] as String? ?? '',
              zone: v['zone'] as String? ?? '',
              owner: v['up'] as String,
              musicTitle: music == null ? '' : music['t'] as String? ?? '',
              musicArtists: List<String>.from(music?['a'] as List? ?? const []),
            );
            final before = LyricsEngine.httpFailures;
            final found = await LyricsEngine.identify(
              v['title'] as String,
              uploader: v['up'] as String,
              durationSeconds: v['dur'] as int? ?? 0,
              hints: hints,
            );
            answers[k] = {
              'bvid': v['bvid'],
              // Who an unnamed video is credited to (TrackCredit).
              'credit': LyricsEngine.cleanTitle(v['title'] as String,
                      defaultArtist: v['up'] as String)['artist'] ??
                  v['up'],
              if (found != null) ...{
                't': found.title,
                'a': found.artist,
                'exact': found.exact,
              },
              // Decided before any catalogue is asked: a medley, a
              // compilation, an hour of music.
              if (LyricsEngine.neverOneSong(
                  v['title'] as String, v['dur'] as int? ?? 0))
                'never': true,
              if (LyricsEngine.httpFailures != before) 'failed': true,
            };
          }(),
      ]);
    }
    await fresh?.close();
    LyricsEngine.httpCache = null;
    File(output).writeAsStringSync(jsonEncode(answers));
  }, timeout: const Timeout(Duration(minutes: 60)));
}
