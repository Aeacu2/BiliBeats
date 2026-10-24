import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/bilibili_sdk.dart';
import 'package:bilibeats/services/recommendation_engine.dart';
import 'package:flutter_test/flutter_test.dart';

Track t(String bvid, String title, String uploader,
        {int duration = 240, bool named = false}) =>
    Track(
      id: '${bvid}_p1',
      bvid: bvid,
      cid: 1,
      title: title,
      rawTitle: title,
      uploader: uploader,
      coverUrl: '',
      duration: duration,
      named: named,
    );

List<({Track track, int views})> listed(List<Track> tracks, {int views = 0}) =>
    [for (final x in tracks) (track: x, views: views)];

void main() {
  group('TasteProfile', () {
    test('is empty with nothing to learn from', () {
      expect(
        TasteProfile.build(favourites: [], history: [], searches: []).isEmpty,
        isTrue,
      );
    });

    test('a favourite leads the seeds, ahead of a mere play', () {
      final profile = TasteProfile.build(
        favourites: [t('BVfav', '大鱼', '周深')],
        history: [t('BVplay', '光年之外', '邓紫棋')],
        searches: [],
      );
      expect(profile.seedsFor(1).first.bvid, 'BVfav');
    });

    test('a recent play outweighs an older one', () {
      final history = [
        for (var i = 0; i < 10; i++) t('BV$i', '歌$i', 'UP$i'),
      ];
      final profile =
          TasteProfile.build(favourites: [], history: history, searches: []);
      expect(profile.weightOf(history.first),
          greaterThan(profile.weightOf(history.last)));
    });

    test('each page expands other seed songs, then runs out', () {
      final history = [
        for (var i = 0; i < 6; i++) t('BV$i', '歌$i', 'UP$i'),
      ];
      final profile =
          TasteProfile.build(favourites: [], history: history, searches: []);
      final first = profile.seedsFor(1).map((s) => s.bvid).toSet();
      final second = profile.seedsFor(2).map((s) => s.bvid).toSet();
      expect(first.intersection(second), isEmpty);
      expect(profile.seedsFor(3), isEmpty);
    });

    test('music watched on Bilibili seeds, and is not offered back', () {
      final profile = TasteProfile.build(
        favourites: [],
        history: [],
        watched: [t('BVwatched', '起风了', '买辣椒也用券')],
        searches: [],
      );
      expect(profile.seedsFor(1).single.bvid, 'BVwatched');
      expect(profile.knownVideos, contains('BVwatched'));
    });

    test('search history alone is something to go on', () {
      final profile =
          TasteProfile.build(favourites: [], history: [], searches: ['周深']);
      expect(profile.isEmpty, isFalse);
    });

    test('two uploads of one song share a key', () {
      expect(TasteProfile.songKey(t('a', '大鱼', '周深', named: true)),
          TasteProfile.songKey(t('b', '大 鱼', '别人', named: true)));
    });
  });

  group('ranking', () {
    final seed = t('BVseed', '大鱼', '周深', named: true);
    final profile =
        TasteProfile.build(favourites: [seed], history: [], searches: []);

    List<Track> rank(List<Track> neighbours,
            {List<Track> byArtist = const [],
            Set<String> excludeIds = const {}}) =>
        RecommendationEngine.rank(
          profile,
          related: {seed: listed(neighbours)},
          byArtist: byArtist,
          excludeIds: excludeIds,
        );

    test('keeps Bilibili\'s order among equals', () {
      final out = rank([
        t('BV1', '起风了', 'A', named: true),
        t('BV2', '平凡之路', 'B', named: true),
      ]);
      expect(out.map((x) => x.bvid), ['BV1', 'BV2']);
    });

    test('a song beside several of theirs ranks above one beside one', () {
      final other = t('BVother', '光年之外', '邓紫棋', named: true);
      final both =
          TasteProfile.build(favourites: [seed, other], history: [], searches: []);
      final shared = t('BVshared', '平凡之路', 'B', named: true);
      final out = RecommendationEngine.rank(both, related: {
        seed: listed([t('BVonly', '起风了', 'A', named: true), shared]),
        other: listed([shared]),
      });
      expect(out.first.bvid, 'BVshared');
    });

    test('leaves out what is not a song to listen to', () {
      final out = rank([
        t('BV1', '【教学】大鱼钢琴教程', 'A'),
        t('BV2', '周深歌曲合集', 'B'),
        t('BV3', '起风了 1小时循环', 'C'),
        t('BV4', '起风了 DJ版', 'D'),
        t('BV5', '一首歌', 'E', duration: 30),
        t('BV6', '一场演唱会', 'F', duration: 3600),
        t('BV7', '平凡之路', 'G', named: true),
      ]);
      expect(out.map((x) => x.bvid), ['BV7']);
    });

    test('never brings back what they have, or another upload of it', () {
      final out = rank([
        t('BVseed', '大鱼', '周深', named: true),
        t('BVcopy', '大鱼', '另一个UP', named: true),
        t('BVnew', '起风了', 'A', named: true),
      ]);
      expect(out.map((x) => x.bvid), ['BVnew']);
    });

    test('one upload per song, and at most two songs per artist', () {
      final out = rank([
        t('BV1', '起风了', 'A', named: true),
        t('BV2', '起风了', 'B', named: true),
        t('BV3', '歌三', 'C', named: true),
        t('BV4', '歌四', 'C', named: true),
        t('BV5', '歌五', 'C', named: true),
      ]);
      expect(out.map((x) => x.bvid), ['BV1', 'BV3', 'BV4']);
    });

    test('skips what is already on screen', () {
      final out = rank([
        t('BV1', '起风了', 'A', named: true),
        t('BV2', '平凡之路', 'B', named: true),
      ], excludeIds: {'BV1_p1'});
      expect(out.map((x) => x.bvid), ['BV2']);
    });

    test('an artist they come back to is lifted', () {
      final out = rank([
        t('BV1', '起风了', 'A', named: true),
        t('BV2', '化身孤岛的鲸', '周深', named: true),
      ]);
      expect(out.first.bvid, 'BV2');
    });
  });

  group('related videos', () {
    test('only songs are kept, with their play counts', () {
      final out = BilibiliSdk.parseRelated('''
{"code":0,"data":[
  {"bvid":"BV1song","cid":11,"tid":31,"title":"起风了 &amp; 翻唱",
   "pic":"http://i0.hdslb.com/a.jpg","duration":245,
   "owner":{"name":"UP"},"stat":{"view":12345}},
  {"bvid":"BV1game","cid":12,"tid":17,"title":"游戏实况","duration":600,
   "owner":{"name":"G"},"stat":{"view":5}},
  {"bvid":"BV1lesson","cid":13,"tid":244,"title":"声乐教学","duration":300,
   "owner":{"name":"T"},"stat":{"view":5}}
]}''');
      expect(out, hasLength(1));
      final song = out.single;
      expect(song.track.id, 'BV1song_p1');
      expect(song.track.title, '起风了 & 翻唱');
      expect(song.track.uploader, 'UP');
      expect(song.track.coverUrl, 'https://i0.hdslb.com/a.jpg');
      expect(song.track.duration, 245);
      expect(song.views, 12345);
    });

    test('a refusal or an odd shape is nothing', () {
      expect(BilibiliSdk.parseRelated('{"code":-404}'), isEmpty);
      expect(BilibiliSdk.parseRelated('{"code":0,"data":{}}'), isEmpty);
      expect(BilibiliSdk.parseRelated('<html>'), isEmpty);
    });
  });
}
