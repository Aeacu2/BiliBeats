import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/models/playlist.dart';
import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'package:bilibeats/services/prefs.dart';

/// Writes queued for the same file are coalesced: whatever is skipped must
/// still be on disk when its caller is told the save is done.
void main() {
  late Directory docs;

  setUpAll(() async {
    docs = await stubDocs('write_coalescing');
  });

  test('a burst of changes all land, however many writes are skipped',
      () async {
    await DatabaseService.getPlaylists();
    final created = await Future.wait([
      for (var i = 0; i < 20; i++) DatabaseService.createPlaylist('list $i'),
    ]);

    final file = File('${docs.path}/bilibeat_playlists2.json');
    final saved = (jsonDecode(await file.readAsString())['data'] as List)
        .map((p) => (p as Map)['id'])
        .toSet();
    expect(saved, containsAll(created.map((p) => p.id)));
    expect(saved, contains('favorites'));
  });

  test('files assembled from each song\'s JSON read as before', () async {
    const song = Track(
      id: 'BV1json0001_p1',
      bvid: 'BV1json0001',
      cid: 3,
      title: '大鱼 "live"',
      rawTitle: '【周深】大鱼\n现场',
      uploader: '周深',
      coverUrl: 'https://i0.hdslb.com/a.jpg',
      duration: 312,
      loudness: -9.5,
      named: true,
      rawUploader: 'UP',
      matcher: 0,
    );
    final list = await DatabaseService.createPlaylist('封面');
    await DatabaseService.setPlaylistCover(list.id, '/covers/x.jpg');
    await DatabaseService.addTrackToPlaylist(list.id, song);
    await DatabaseService.addRecentlyPlayed(song);

    Future<dynamic> data(String name) async =>
        jsonDecode(await File('${docs.path}/$name').readAsString())['data'];
    final playlists = await data('bilibeat_playlists2.json') as List;
    expect(playlists.firstWhere((p) => p['id'] == list.id), {
      ...Playlist(
          id: list.id,
          name: '封面',
          coverUrl: '/covers/x.jpg',
          tracks: []).toMap(),
      'tracks': [song.toMap()],
    });
    expect((await data('bilibeat_recently_played.json') as List).first,
        song.toMap());
  });

  test('each caller sees its own change on disk once it returns', () async {
    for (var i = 0; i < 5; i++) {
      final saves = [
        Prefs.set('a', i),
        Prefs.set('b', i),
      ];
      await saves.first;
      final prefs = jsonDecode(
          await File('${docs.path}/bilibeat_prefs.json').readAsString());
      expect(prefs['data']['a'], i);
      await saves.last;
      final after = jsonDecode(
          await File('${docs.path}/bilibeat_prefs.json').readAsString());
      expect(after['data'], {'a': i, 'b': i});
    }
  });
}
