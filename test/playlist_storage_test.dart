import 'dart:io';

import 'package:bilibeats/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'playlist_storage_helpers.dart';

/// The first launch after the upgrade: playlists move from the older file,
/// in which every song is kept in full, to one that names downloads by id.
void main() {
  late Directory docs;
  late String legacy;
  final kept = song('A_p1'); // downloaded
  final gone = song('B_p1'); // listed as downloaded, but its file is gone
  final saved = song('C_p1'); // in a playlist, never downloaded
  final renamed = song('D_p1'); // downloaded, renamed in the playlist only
  final drifted = song('E_p1'); // downloaded; the playlist's copy drifted

  setUpAll(() async {
    docs = await stubDocs('playlist_storage');
    await downloaded(docs, kept);
    await downloaded(docs, renamed);
    await downloaded(docs, drifted);
    await store(docs, 'bilibeat_downloaded.json',
        [kept.toMap(), gone.toMap(), renamed.toMap(), drifted.toMap()]);
    await store(docs, 'bilibeat_playlists.json', [
      playlist('favorites', [kept.toMap()]),
      playlist('pl_1', [
        kept.toMap(),
        gone.toMap(),
        saved.toMap(),
        renamed.copyWith(title: 'my name').toMap(),
        drifted.copyWith(loudness: -7.5, matcher: 3, rawUploader: 'UP').toMap(),
      ]),
    ]);
    legacy = await File('${docs.path}/bilibeat_playlists.json').readAsString();
  });

  test('every song comes over, and downloads are written by id', () async {
    final lists = await DatabaseService.getPlaylists();
    final list = lists.firstWhere((p) => p.id == 'pl_1');
    expect([for (final t in list.tracks) t.title],
        ['song A_p1', 'song B_p1', 'song C_p1', 'my name', 'song E_p1']);

    final written = await stored(docs, 'bilibeat_playlists2.json') as List;
    final entries = written.firstWhere((p) => p['id'] == 'pl_1')['tracks'];
    expect(entries, [
      kept.id,
      gone.toMap(),
      saved.toMap(),
      renamed.copyWith(title: 'my name').toMap(),
      // Differed only in what is worked out: now the download's copy.
      drifted.id,
    ]);
  });

  test('the older file is left exactly as it was', () async {
    await DatabaseService.createPlaylist('new');
    expect(await File('${docs.path}/bilibeat_playlists.json').readAsString(),
        legacy);
  });

  test('a deleted download is written in full into its playlists', () async {
    await DatabaseService.removeDownloadedTrack(kept);
    final written = await stored(docs, 'bilibeat_playlists2.json') as List;
    for (final id in ['favorites', 'pl_1']) {
      final entries = written.firstWhere((p) => p['id'] == id)['tracks'];
      expect((entries as List).first, kept.toMap(), reason: id);
    }
  });

  test('an edit applied everywhere is written by id again', () async {
    final edited = renamed.copyWith(title: 'one name');
    await DatabaseService.updateTrackMetadata(edited);
    final written = await stored(docs, 'bilibeat_playlists2.json') as List;
    final entries = written.firstWhere((p) => p['id'] == 'pl_1')['tracks'];
    expect((entries as List)[3], renamed.id);
  });
}
