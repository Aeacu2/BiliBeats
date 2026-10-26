import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/models/video_hints.dart';
import 'package:bilibeats/services/accompaniment.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/services/local_songs.dart';
import 'package:bilibeats/services/lyrics_engine.dart';
import 'package:bilibeats/services/track_credit.dart';
import 'package:bilibeats/services/track_naming.dart';
import 'package:bilibeats/state/lyrics_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// Backing tracks are credited to 伴奏, so they gather there among the
/// artists and stay out of the singers' own lists.
void main() {
  Track video(String key, String title,
          {String? name, String? artist, int? matcher}) =>
      Track(
        id: 'BV1backing${key}_p1',
        bvid: 'BV1backing$key',
        cid: 1,
        title: name ?? title,
        rawTitle: title,
        uploader: artist ?? 'the uploader',
        coverUrl: '',
        duration: 200,
        named: name != null,
        matcher: matcher,
      );

  Future<Track> stored(Track t) async =>
      (await DatabaseService.downloadedTrack(t.id))!;

  setUpAll(() async {
    await stubDocs('accompaniment');
    TrackNaming.hintsFor =
        (bvid, {cid = 0}) async => const VideoHints(owner: 'the uploader');
    TrackNaming.identifyWith = (
      rawTitle, {
      uploader = '',
      durationSeconds = 0,
      context = '',
      hints = VideoHints.none,
    }) async =>
        const SongIdentity(title: '大鱼 (伴奏版)', artist: '周深', exact: false);
    TrackNaming.readWith = null;
    TrackNaming.subtitlesFor = (bvid, {cid = 0}) async => null;
  });

  test('what a title says', () {
    expect(Accompaniment.marks('【高品质伴奏】大鱼'), isTrue);
    expect(Accompaniment.marks('Lemon (Off Vocal)'), isTrue);
    expect(Accompaniment.marks('大鱼 消音版'), isTrue);
    expect(Accompaniment.marks('大鱼 消人声伴奏'), isTrue);
    expect(Accompaniment.marks('大鱼 去人声'), isTrue);
    expect(Accompaniment.marks('无伴奏合唱《大鱼》'), isFalse);
    expect(Accompaniment.marks('大鱼 去伴奏 纯人声'), isFalse);
    expect(Accompaniment.marks('大鱼（消伴奏干声）'), isFalse);
    expect(Accompaniment.marks('周深《大鱼》现场'), isFalse);
    expect(Accompaniment.songOf('大鱼 (伴奏版)'), '大鱼');
    expect(Accompaniment.songOf('Lemon (Off Vocal)'), 'Lemon');
    expect(Accompaniment.songOf('大鱼（伴奏）'), '大鱼');
    expect(Accompaniment.songOf('大鱼 (Live)'), '大鱼 (Live)');
  });

  test('a backing track not yet named is credited to 伴奏 already', () {
    expect(TrackCredit.artistOf(video('X', '【伴奏】周深《大鱼》')), '伴奏');
    expect(TrackCredit.artistOf(video('Y', '无伴奏 周深《大鱼》')), isNot('伴奏'));
  });

  test('the matcher names the song and credits it to 伴奏', () async {
    final t = video('A', '【伴奏】周深《大鱼》');
    await DatabaseService.saveDownloadedTrack(t);
    await TrackNaming.nameNow(t);
    final now = await stored(t);
    expect(now.title, '大鱼');
    expect(now.uploader, '伴奏');
  });

  test('songs the matcher named earlier are credited now; the listener\'s not',
      () async {
    final auto = video('B', '大鱼 伴奏', name: '大鱼', artist: '周深', matcher: 6);
    final own = video('C', '大鱼 伴奏', name: '我的大鱼', artist: '我', matcher: 0);
    await DatabaseService.saveDownloadedTrack(auto);
    await DatabaseService.saveDownloadedTrack(own);
    await TrackNaming.markAccompaniments();
    expect((await stored(auto)).uploader, '伴奏');
    expect((await stored(own)).uploader, '我');
  });

  test('its lyrics are looked for under the singer the title names', () {
    final t = video('L', '【伴奏】周深《大鱼》', name: '大鱼', artist: '伴奏', matcher: 7);
    expect(LyricsController.defaultQuery(t), '周深 大鱼');
    expect(LyricsController.defaultQuery(video('M', '【伴奏】周深《大鱼》')), '周深 大鱼');
  });

  test('an imported backing track is credited to 伴奏 too', () {
    final t = LocalSongs.trackFrom('local_x', {
      'name': '周深 - 大鱼 (伴奏).mp3',
      'title': '大鱼 (伴奏)',
      'artist': '周深',
    });
    expect(t.title, '大鱼');
    expect(t.uploader, '伴奏');
  });
}
