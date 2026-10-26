import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/services/search_history.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// Writes to one file that pile up behind the write lock are saved as one:
/// every caller still hears back only once its change is on disk.
void main() {
  late Directory docs;

  setUpAll(() async {
    docs = await stubDocs('store_writes');
  });

  Track track(int i) => Track(
        id: 'BV1writes${i.toString().padLeft(4, '0')}_p1',
        bvid: 'BV1writes${i.toString().padLeft(4, '0')}',
        cid: i,
        title: 'song $i',
        rawTitle: 'song $i',
        uploader: 'u',
        coverUrl: '',
        duration: 60,
      );

  Future<List<dynamic>> playlistsOnDisk() async =>
      jsonDecode(await File('${docs.path}/bilibeat_playlists2.json')
          .readAsString())['data'] as List<dynamic>;

  test('a burst of changes all reach the file, each awaited one is on disk',
      () async {
    final playlist = await DatabaseService.createPlaylist('burst');
    final adds = [
      for (var i = 0; i < 40; i++)
        DatabaseService.addTrackToPlaylist(playlist.id, track(i)),
    ];
    // The first one, awaited alone, already finds its song saved.
    await adds.first;
    final early = (await playlistsOnDisk())
        .firstWhere((p) => p['id'] == playlist.id)['tracks'] as List;
    expect(early.map((t) => t['id']), contains(track(0).id));

    await Future.wait(adds);
    final saved = (await playlistsOnDisk())
        .firstWhere((p) => p['id'] == playlist.id)['tracks'] as List;
    expect(saved.map((t) => t['id']).toSet(),
        {for (var i = 0; i < 40; i++) track(i).id});
  });

  test('a later change to a file still waiting is the one saved', () async {
    final playlist = await DatabaseService.createPlaylist('rename me');
    await Future.wait([
      DatabaseService.renamePlaylist(playlist.id, 'first'),
      DatabaseService.renamePlaylist(playlist.id, 'second'),
      DatabaseService.renamePlaylist(playlist.id, 'third'),
      SearchHistory.add('another file meanwhile'),
    ]);
    final saved =
        (await playlistsOnDisk()).firstWhere((p) => p['id'] == playlist.id);
    expect(saved['name'], 'third');
    expect(await SearchHistory.get(), contains('another file meanwhile'));
    // Nothing left behind by the writes.
    final leftovers = docs
        .listSync()
        .where((e) => e.path.endsWith('.tmp'))
        .map((e) => e.path);
    expect(leftovers, isEmpty);
  });
}
