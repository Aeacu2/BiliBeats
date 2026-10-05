@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/models/video_hints.dart';
import 'package:bilibeats/services/bilibili_sdk.dart';
import 'package:bilibeats/services/lyrics_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

Future<bool> _reachable(String host) async {
  try {
    final socket =
        await Socket.connect(host, 443, timeout: const Duration(seconds: 4));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// The matcher against real videos, with NetEase and Bilibili for real.
///
/// `test/fixtures/zhoushen_videos.json` is 126 videos found by searching for
/// 周深 a dozen ways, each with its tags and the music Bilibili recognised
/// in it, as they were when surveyed. Those marked `checked` carry the name
/// and artist a listener would give them (`expect`, null for "not a song").
void main() {
  setUpAll(useRealHttp);

  test('the surveyed videos are named as a listener would name them', () async {
    if (!await _reachable('music.163.com')) {
      markTestSkipped('requires music.163.com');
      return;
    }
    // A library that is mostly 周深, like the one this was tuned for.
    LyricsEngine.knownArtists = ['周深'];
    final videos = (jsonDecode(
      File('test/fixtures/zhoushen_videos.json').readAsStringSync(),
    ) as List)
        .cast<Map>()
        .where((v) => v['checked'] == true)
        .toList();

    String? told(SongIdentity? id) =>
        id == null ? null : '${id.title} / ${id.artist}';
    final wrong = <String>[];
    // A few at a time: quick, without leaning on NetEase.
    for (var i = 0; i < videos.length; i += 6) {
      await Future.wait(videos.skip(i).take(6).map((v) async {
        final music = v['music'] as Map?;
        final found = await LyricsEngine.identify(
          v['title'] as String,
          uploader: v['up'] as String,
          durationSeconds: v['dur'] as int,
          hints: VideoHints(
            tags: List<String>.from(v['tags'] as List),
            description: v['desc'] as String,
            zone: v['zone'] as String,
            owner: v['up'] as String,
            musicTitle: music == null ? '' : music['title'] as String,
            musicArtists: music == null
                ? const []
                : BilibiliSdk.parseRecognisedMusic(
                    {'origin_artist': music['artists']},
                  ).artists,
          ),
        );
        final expected = v['expect'] as Map?;
        final want = expected == null
            ? null
            : '${expected['title']} / ${expected['artist']}';
        if (told(found) != want) {
          wrong.add('${v['title']}\n    want $want\n    got  ${told(found)}');
        }
      }));
    }
    expect(wrong, isEmpty, reason: wrong.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Bilibili says which song it recognised in a video', () async {
    if (!await _reachable('api.bilibili.com')) {
      markTestSkipped('requires api.bilibili.com');
      return;
    }
    final videos = (jsonDecode(
      File('test/fixtures/zhoushen_videos.json').readAsStringSync(),
    ) as List)
        .cast<Map>();
    final video = videos.firstWhere(
        (v) => (v['title'] as String).contains('官方Live MV】周深/五月天《如烟》'));
    final hints = await BilibiliSdk.fetchVideoHints(video['bvid'] as String);
    if (hints.isEmpty) {
      markTestSkipped('Bilibili refused the request');
      return;
    }
    expect(hints.musicTitle, contains('如烟'));
    expect(hints.musicArtists, containsAll(<String>['五月天', '周深']));
  });
}
