import 'dart:io';

import 'package:bilibeats/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'playlist_storage_helpers.dart';

/// An older build was installed over this one and changed its playlists:
/// its file is now the newer, and is what the next launch reads.
void main() {
  late Directory docs;

  setUpAll(() async {
    docs = await stubDocs('playlist_downgrade');
    final a = song('A_p1');
    await downloaded(docs, a);
    await store(docs, 'bilibeat_downloaded.json', [a.toMap()]);
    await store(docs, 'bilibeat_playlists2.json', [
      playlist('pl_before', [a.id]),
    ]);
    final current = File('${docs.path}/bilibeat_playlists2.json');
    await current
        .setLastModified(DateTime.now().subtract(const Duration(days: 2)));
    await store(docs, 'bilibeat_playlists.json', [
      playlist('pl_older_build', [a.toMap(), song('Z_p1').toMap()]),
    ]);
  });

  test('the older build\'s playlists win, and are moved over again', () async {
    final lists = await DatabaseService.getPlaylists();
    expect(lists.map((p) => p.id), ['favorites', 'pl_older_build']);
    expect(lists.last.tracks, hasLength(2));
    final written = await stored(docs, 'bilibeat_playlists2.json') as List;
    expect(written.last['tracks'], ['BV1storeA_p1', song('Z_p1').toMap()]);
  });
}
