import 'dart:convert';

import 'package:bilibeats/models/subtitles.dart';
import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/audio_download_service.dart';
import 'package:bilibeats/services/audio_player_handler.dart';
import 'package:bilibeats/services/bili_account.dart';
import 'package:bilibeats/services/lyrics_engine.dart';
import 'package:bilibeats/state/lyrics_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'fake_audio_player.dart';

/// The video's subtitles in the lyrics: the clock automatic lyrics are set
/// against, and the lyrics of last resort.
void main() {
  late LocalAudioServer server;

  const daYu = [
    '海浪无声将夜幕深深淹没',
    '漫过天空尽头的角落',
    '大鱼在梦境的缝隙里游过',
    '凝望你沉睡的轮廓',
    '看海天一色听风起雨落',
    '执子手吹散苍茫茫烟波',
    '大鱼的翅膀已经太辽阔',
    '我松开时间的绳索',
  ];

  String lrc(List<String> lines) => [
        for (var i = 0; i < lines.length; i++)
          '[00:${(10 + i * 4).toString().padLeft(2, '0')}.00]${lines[i]}',
      ].join('\n');

  Subtitles heard(List<String> lines, {double start = 10}) =>
      Subtitles(language: 'ai-zh', ai: true, lines: [
        for (var i = 0; i < lines.length; i++)
          SubtitleLine(
              from: start + i * 4, to: start + i * 4 + 3, text: lines[i]),
      ]);

  /// NetEase knows [lines] as 大鱼 (or nothing); LRCLIB knows nothing.
  void catalogue(List<String>? lines) {
    LyricsEngine.httpCache = (url, fetch) async {
      if (url.contains('music.163.com/api/search')) {
        return jsonEncode({
          'result': {
            'songs': lines == null
                ? []
                : [
                    {
                      'id': 1,
                      'name': '大鱼',
                      'artists': [
                        {'name': '周深'}
                      ],
                      'duration': 300000,
                    }
                  ],
          },
        });
      }
      if (url.contains('music.163.com/api/song/lyric')) {
        return jsonEncode({
          'lrc': {'lyric': lrc(lines ?? const [])},
        });
      }
      if (url.contains('lrclib')) return '[]';
      return null;
    };
  }

  setUpAll(() async {
    await stubDocs('lyrics_subs');
    useRealHttp();
    server = await LocalAudioServer.start();
  });

  tearDownAll(() async {
    LyricsEngine.httpCache = null;
    await server.stop();
  });

  Future<Track> downloaded(String name) async {
    server.serveInstant(name);
    final t = serverTrack(server, name, title: '大鱼');
    await AudioDownloadService.ensureDownloaded(t);
    return t;
  }

  Future<LyricsState> settled(
      LyricsController c, bool Function(LyricsState) done) async {
    await waitFor(() => done(c.state.value));
    return c.state.value;
  }

  test('library lyrics are moved onto the video\'s own clock', () async {
    catalogue(daYu);
    final t = await downloaded('ls-offset');
    final handler = BiliBeatsAudioHandler(
        player: FakeAudioPlayer(), manageAudioSession: false);
    final controller = LyricsController(handler,
        subtitles: (bvid, {cid = 0}) async => heard(daYu, start: 12.5));
    await handler.playTrack(t, queue: [t]);

    final state = await settled(controller,
        (s) => s.status == LyricsStatus.ready && s.lyrics.offset != 0);
    expect(state.lyrics.source, isNot('bilibili'));
    expect(state.lyrics.offset, closeTo(2.5, 0.01));

    controller.dispose();
    await handler.dispose();
  });

  test('with no lyrics anywhere, sung subtitles are shown', () async {
    catalogue(null);
    final t = await downloaded('ls-fallback');
    final handler = BiliBeatsAudioHandler(
        player: FakeAudioPlayer(), manageAudioSession: false);
    final controller = LyricsController(handler,
        subtitles: (bvid, {cid = 0}) async =>
            heard([...daYu, ...daYu.take(4)]));
    await handler.playTrack(t, queue: [t]);

    final state =
        await settled(controller, (s) => s.status == LyricsStatus.ready);
    expect(state.lyrics.source, 'bilibili');
    expect(state.lyrics.lines.first.text, daYu.first);
    expect(state.lyrics.lines.first.time, 10);

    controller.dispose();
    await handler.dispose();
  });
  test('logging in aligns already cached automatic lyrics for the current song',
      () async {
    await BiliAccountStore.logOut();
    catalogue(daYu);
    final t = await downloaded('ls-login-refresh');
    final handler = BiliBeatsAudioHandler(
        player: FakeAudioPlayer(), manageAudioSession: false);
    final controller = LyricsController(handler,
        subtitles: (bvid, {cid = 0}) async =>
            BiliAccountStore.current.value == null
                ? null
                : heard(daYu, start: 13));
    await handler.playTrack(t, queue: [t]);
    await settled(controller, (s) => s.status == LyricsStatus.ready);
    expect(controller.state.value.lyrics.offset, 0);
    await BiliAccountStore.save(
        const BiliAccount(cookies: 'SESSDATA=test', mid: 1, name: 'test'));
    await settled(controller, (s) => s.lyrics.offset == 3);
    expect(controller.state.value.lyrics.offset, 3);
    controller.dispose();
    await BiliAccountStore.logOut();
    await handler.dispose();
  });
}
