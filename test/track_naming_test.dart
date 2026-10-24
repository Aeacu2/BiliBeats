import 'package:bilibeats/models/lyrics.dart';
import 'package:bilibeats/models/subtitles.dart';
import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/models/video_hints.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/services/lyrics_engine.dart';
import 'package:bilibeats/services/song_reader.dart';
import 'package:bilibeats/services/track_naming.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// Automatic naming is the one thing that renames songs unasked. What it
/// may and may not touch:
void main() {
  var hintsAsked = 0;
  VideoHints hints = const VideoHints(owner: 'the uploader');
  Future<SongIdentity?> Function()? answer;

  Track video(String key) => Track(
        id: 'BV1naming${key}_p1',
        bvid: 'BV1naming$key',
        cid: 1,
        title: '【4K】周深《大鱼》现场 $key',
        rawTitle: '【4K】周深《大鱼》现场 $key',
        uploader: 'the uploader',
        coverUrl: 'https://example.com/video.jpg',
        duration: 200,
      );

  Future<Track> stored(Track t) async =>
      (await DatabaseService.getDownloadedTracks())
          .firstWhere((x) => x.id == t.id);

  setUpAll(() async {
    await stubDocs('naming');
    await DatabaseService.getDownloadedTracks();
    TrackNaming.hintsFor = (bvid, {cid = 0}) async {
      hintsAsked++;
      return hints;
    };
    TrackNaming.identifyWith = (
      rawTitle, {
      uploader = '',
      durationSeconds = 0,
      context = '',
      hints = VideoHints.none,
    }) async =>
        answer == null ? null : await answer!();
  });

  setUp(() {
    hintsAsked = 0;
    hints = const VideoHints(owner: 'the uploader');
    answer = () async => const SongIdentity(
          title: '大鱼',
          artist: '周深',
          coverUrl: 'https://example.com/release.jpg',
          exact: true,
        );
    TrackNaming.enabled = true;
    TrackNaming.readWith = null;
    TrackNaming.subtitlesFor = (bvid, {cid = 0}) async => null;
  });

  test('a confirmed answer names the song and records who named it', () async {
    final t = video('A');
    await DatabaseService.saveDownloadedTrack(t);
    await TrackNaming.nameNow(t);

    final now = await stored(t);
    expect(now.title, '大鱼');
    expect(now.uploader, '周深');
    expect(now.coverUrl, 'https://example.com/release.jpg');
    expect(now.rawUploader, 'the uploader');
    expect(now.matcher, TrackNaming.matcher);
    expect(now.rawTitle, t.rawTitle);
  });

  group('asked about while it downloads', () {
    test('is named on arrival without asking again', () async {
      var asked = 0;
      answer = () async {
        asked++;
        return const SongIdentity(title: '大鱼', artist: '周深', exact: true);
      };
      final t = video('early');
      await TrackNaming.prepareNow(t);
      expect(asked, 1);

      await DatabaseService.saveDownloadedTrack(t);
      await TrackNaming.nameNow(t);

      expect(asked, 1);
      expect(hintsAsked, 1);
      expect((await stored(t)).title, '大鱼');
    });

    test('is asked again when it arrived changed', () async {
      final t = video('early-part');
      await TrackNaming.prepareNow(t);
      // Stored as the first part of a multi-part video.
      await DatabaseService.saveDownloadedTrack(
          t.copyWith(title: '${t.rawTitle} - P1: 大鱼', duration: 180));
      await TrackNaming.nameNow(t);

      expect(hintsAsked, 2);
      expect((await stored(t)).title, '大鱼');
    });
  });

  test('a song the listener named is never looked at', () async {
    final t = video('B').copyWith(title: 'mine', named: true, matcher: 0);
    await DatabaseService.saveDownloadedTrack(t);
    await TrackNaming.nameNow(t);

    expect(hintsAsked, 0);
    expect((await stored(t)).title, 'mine');
  });

  test('an edit made while the lookup runs is not overwritten', () async {
    final t = video('C');
    await DatabaseService.saveDownloadedTrack(t);
    answer = () async {
      await DatabaseService.updateTrackMetadata(
          t.copyWith(title: 'edited meanwhile', named: true, matcher: 0));
      return const SongIdentity(title: '大鱼', artist: '周深', exact: true);
    };
    await TrackNaming.nameNow(t);

    final now = await stored(t);
    expect(now.title, 'edited meanwhile');
    expect(now.matcher, 0);
  });

  test('with part of the evidence missing nothing is written', () async {
    final t = video('D');
    await DatabaseService.saveDownloadedTrack(t);
    hints = const VideoHints(owner: 'the uploader', complete: false);
    await TrackNaming.nameNow(t);

    final now = await stored(t);
    expect(now.title, t.title);
    expect(now.isNamed, isFalse);
  });

  test('switched off, a queued lookup does not rename', () async {
    final t = video('E');
    await DatabaseService.saveDownloadedTrack(t);
    TrackNaming.enabled = false;
    await TrackNaming.nameNow(t);

    expect(hintsAsked, 0);
    expect((await stored(t)).isNamed, isFalse);
  });

  test(
      'a name from before matchers were recorded, by another artist than '
      'the uploader, is taken as the listener\'s', () async {
    final t = video('F')
        .copyWith(title: 'my title', uploader: 'my artist', named: true);
    await DatabaseService.saveDownloadedTrack(t);
    await TrackNaming.nameNow(t);

    final now = await stored(t);
    expect(now.title, 'my title');
    expect(now.uploader, 'my artist');
    expect(now.matcher, 0);
  });

  test('a compilation is not asked about at all', () async {
    final t = video('G').copyWith(duration: 3600);
    await DatabaseService.saveDownloadedTrack(t);
    await TrackNaming.nameNow(t);

    expect(hintsAsked, 0);
    expect((await stored(t)).isNamed, isFalse);
  });

  group('with the on-device model reading the video too', () {
    void reads(SongReading? reading) {
      TrackNaming.readWith = ({
        required title,
        required uploader,
        tags = const [],
        musicTitle = '',
        musicArtists = const [],
        durationSeconds = 0,
      }) async =>
          reading;
    }

    SongReading reading(String? song, List<String> performers,
            {double confidence = 0.99}) =>
        SongReading(
          pNone: song == null ? 0.99 : 0.01,
          pOwn: 0.01,
          song: song,
          performers: performers,
          own: false,
          names: const {},
          confidence: confidence,
        );

    test('a video it sees no song in keeps its title', () async {
      reads(reading(null, const []));
      final t = video('M1');
      await DatabaseService.saveDownloadedTrack(t);
      await TrackNaming.nameNow(t);

      final now = await stored(t);
      expect(now.isNamed, isFalse);
      expect(now.title, t.title);
    });

    test('the singer it is sure of is credited, without the release artwork',
        () async {
      reads(reading('大鱼', ['单依纯']));
      final t = video('M2');
      await DatabaseService.saveDownloadedTrack(t);
      await TrackNaming.nameNow(t);

      final now = await stored(t);
      expect(now.title, '大鱼');
      expect(now.uploader, '单依纯');
      expect(now.coverUrl, t.coverUrl);
      expect(now.matcher, TrackNaming.matcher);
    });

    test('a model that cannot be run leaves the catalogue\'s answer standing',
        () async {
      reads(null);
      final t = video('M3');
      await DatabaseService.saveDownloadedTrack(t);
      await TrackNaming.nameNow(t);

      final now = await stored(t);
      expect(now.title, '大鱼');
      expect(now.uploader, '周深');
    });

    group('and its subtitles', () {
      const sung = [
        '海浪无声将夜幕深深淹没',
        '漫过天空尽头的角落',
        '大鱼在梦境的缝隙里游过',
        '凝望你沉睡的轮廓',
        '看海天一色听风起雨落',
        '执子手吹散苍茫茫烟波',
        '大鱼的翅膀已经太辽阔',
        '我松开时间的绳索',
      ];
      List<LyricLine> lyricsOf(List<String> lines) => [
            for (var i = 0; i < lines.length; i++)
              LyricLine(time: i * 4.0, text: lines[i]),
          ];

      setUp(() {
        TrackNaming.subtitlesFor = (bvid, {cid = 0}) async => Subtitles(
              language: 'ai-zh',
              ai: true,
              lines: [
                for (var i = 0; i < sung.length; i++)
                  SubtitleLine(
                      from: 5 + i * 4.0, to: 8 + i * 4.0, text: sung[i]),
              ],
            );
      });
      tearDown(() {
        TrackNaming.lyricsFor = LyricsEngine.lyricsForTitle;
      });

      test('settle the song where the readings could not, not the singer',
          () async {
        reads(reading(null, const []));
        TrackNaming.lyricsFor = (title, {artist, max = 3}) async =>
            title == '大鱼' ? [lyricsOf(sung)] : const [];
        final t = video('S1');
        await DatabaseService.saveDownloadedTrack(t);
        await TrackNaming.nameNow(t);

        final now = await stored(t);
        expect(now.title, '大鱼');
        expect(now.uploader, 'the uploader');
        expect(now.coverUrl, t.coverUrl);
      });

      test('that sing something else change nothing', () async {
        reads(reading(null, const []));
        TrackNaming.lyricsFor = (title, {artist, max = 3}) async => [
              lyricsOf([
                '我曾经跨过山和大海',
                '也穿过人山人海',
                '我曾经拥有着的一切',
                '转眼都飘散如烟',
                '我曾经失落失望失掉所有方向',
                '直到看见平凡才是唯一的答案'
              ]),
            ];
        final t = video('S2');
        await DatabaseService.saveDownloadedTrack(t);
        await TrackNaming.nameNow(t);

        expect((await stored(t)).isNamed, isFalse);
      });
    });
  });
}
