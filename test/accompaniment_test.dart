import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/models/video_hints.dart';
import 'package:bilibeats/services/accompaniment.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/services/lyrics_engine.dart';
import 'package:bilibeats/services/track_naming.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// Backing tracks: named as one (「大鱼（伴奏）」), and filed in a 伴奏
/// playlist the listener can rename, prune or delete.
void main() {
  Track video(String key, String title, {String? name, int? matcher}) => Track(
        id: 'BV1backing${key}_p1',
        bvid: 'BV1backing$key',
        cid: 1,
        title: name ?? title,
        rawTitle: title,
        uploader: 'the uploader',
        coverUrl: '',
        duration: 200,
        named: name != null,
        matcher: matcher,
      );

  Future<Track> stored(Track t) async =>
      (await DatabaseService.downloadedTrack(t.id))!;

  Future<List<String>?> filed() async {
    for (final p in await DatabaseService.getPlaylists()) {
      if (p.name == '伴奏') return [for (final t in p.tracks) t.id];
    }
    return null;
  }

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
        const SongIdentity(title: '大鱼', artist: '周深', exact: false);
    TrackNaming.readWith = null;
    TrackNaming.subtitlesFor = (bvid, {cid = 0}) async => null;
  });

  test('what a title says', () {
    expect(Accompaniment.marks('【高品质伴奏】大鱼'), isTrue);
    expect(Accompaniment.marks('Lemon (Off Vocal)'), isTrue);
    expect(Accompaniment.marks('大鱼 消音版'), isTrue);
    expect(Accompaniment.marks('无伴奏合唱《大鱼》'), isFalse);
    expect(Accompaniment.marks('大鱼 去伴奏 纯人声'), isFalse);
    expect(Accompaniment.marks('大鱼（消伴奏干声）'), isFalse);
    expect(Accompaniment.marks('大鱼 消人声伴奏'), isTrue);
    expect(Accompaniment.marks('大鱼 去人声'), isTrue);
    expect(Accompaniment.marks('周深《大鱼》现场'), isFalse);
    expect(Accompaniment.titled('大鱼'), '大鱼（伴奏）');
    expect(Accompaniment.titled('大鱼 (伴奏版)'), '大鱼 (伴奏版)');
    expect(Accompaniment.songOf('大鱼（伴奏）'), '大鱼');
    expect(Accompaniment.songOf('大鱼 (伴奏)'), '大鱼');
    expect(Accompaniment.songOf('大鱼'), '大鱼');
  });

  test('a backing track is named as one, and filed', () async {
    final t = video('A', '【伴奏】周深《大鱼》');
    await DatabaseService.saveDownloadedTrack(t);
    expect(await filed(), [t.id]);

    await TrackNaming.nameNow(t);
    expect((await stored(t)).title, '大鱼（伴奏）');
    expect(await filed(), [t.id]);
  });

  test('a song the matcher named earlier gets the mark; the listener\'s not',
      () async {
    final auto = video('B', '大鱼 伴奏', name: '大鱼', matcher: 6);
    final own = video('C', '大鱼 伴奏', name: '我的大鱼', matcher: 0);
    await DatabaseService.saveDownloadedTrack(auto);
    await DatabaseService.saveDownloadedTrack(own);
    await TrackNaming.markAccompaniments();
    expect((await stored(auto)).title, '大鱼（伴奏）');
    expect((await stored(own)).title, '我的大鱼');
    expect((await filed())!.first, auto.id);
    expect(await filed(), isNot(contains(own.id)));
  });

  test('one the listener took out stays out', () async {
    final list = (await DatabaseService.getPlaylists())
        .firstWhere((p) => p.name == '伴奏');
    final t = video('A', '【伴奏】周深《大鱼》');
    await DatabaseService.removeTrackFromPlaylist(list.id, t.id);
    await DatabaseService.updateTrackMetadata(
        (await stored(t)).copyWith(uploader: '周深 & 伴奏'));
    expect(await filed(), isNot(contains(t.id)));
  });

  test('once deleted, the playlist is not made again', () async {
    final list = (await DatabaseService.getPlaylists())
        .firstWhere((p) => p.name == '伴奏');
    await DatabaseService.deletePlaylist(list.id);
    await DatabaseService.saveDownloadedTrack(video('D', 'Lemon (Off Vocal)'));
    expect(await filed(), isNull);
  });
}
