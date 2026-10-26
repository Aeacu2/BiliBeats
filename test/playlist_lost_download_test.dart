import 'dart:io';

import 'package:bilibeats/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'playlist_storage_helpers.dart';

/// A playlist names a song by id whose download is gone from the list and
/// the disk alike (the list was unreadable): the older file still has it.
void main() {
  late Directory docs;

  setUpAll(() async {
    docs = await stubDocs('playlist_lost');
    await File('${docs.path}/bilibeat_downloaded.json').writeAsString('{"sch');
    await store(docs, 'bilibeat_playlists.json', [
      playlist('pl_1', [song('A_p1').toMap()]),
    ]);
    await File('${docs.path}/bilibeat_playlists.json')
        .setLastModified(DateTime.now().subtract(const Duration(days: 9)));
    await store(docs, 'bilibeat_playlists2.json', [
      playlist('pl_1', ['BV1storeA_p1', 'BV1storeNowhere_p1']),
    ]);
  });

  test('the song comes back from the older file, in full', () async {
    final lists = await DatabaseService.getPlaylists();
    final list = lists.firstWhere((p) => p.id == 'pl_1');
    expect(list.tracks.map((t) => t.title), ['song A_p1']);
    final written = await stored(docs, 'bilibeat_playlists2.json') as List;
    expect(written.firstWhere((p) => p['id'] == 'pl_1')['tracks'],
        [song('A_p1').toMap()]);
  });
}
