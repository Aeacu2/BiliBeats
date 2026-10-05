import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/models/lyrics.dart';
import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/services/lyrics_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// A file this build cannot read — written by a newer build, or damaged —
/// must survive the next save: it holds the only copy of the listener's
/// playlists, favourites or pinned lyrics.
void main() {
  late Directory docs;

  const track = Track(
    id: 'BV1safety0001_p1',
    bvid: 'BV1safety0001',
    cid: 1,
    title: 't',
    rawTitle: 't',
    uploader: 'u',
    coverUrl: '',
    duration: 1,
  );

  final newerPlaylists = jsonEncode({
    'schema_version': DatabaseService.schemaVersion + 98,
    'data': [
      {'id': 'pl_future', 'name': 'from a newer build', 'tracks': []},
    ],
  });
  const tornHistory = '{"schema_version":1,"data":[{"id":"a_p1","ti';
  final newerLyrics = jsonEncode({
    'schema_version': DatabaseService.schemaVersion + 98,
    'data': {'x_p1': <String, dynamic>{}},
  });

  setUpAll(() async {
    docs = await stubDocs('store_safety');
    await File('${docs.path}/bilibeat_playlists.json')
        .writeAsString(newerPlaylists);
    await File('${docs.path}/bilibeat_recently_played.json')
        .writeAsString(tornHistory);
    await File('${docs.path}/bilibeat_lyrics.json').writeAsString(newerLyrics);
  });

  test('a newer build\'s playlists are kept aside, not overwritten', () async {
    // Loads as empty …
    final playlists = await DatabaseService.getPlaylists();
    expect(playlists.map((p) => p.id), ['favorites']);

    // … and a save writes a file this build understands …
    await DatabaseService.toggleFavorite(track);
    final current = jsonDecode(
        await File('${docs.path}/bilibeat_playlists.json').readAsString());
    expect(current['schema_version'], DatabaseService.schemaVersion);

    // … while what could not be read is still there, byte for byte.
    final aside = File('${docs.path}/bilibeat_playlists.json.unreadable');
    expect(await aside.exists(), isTrue);
    expect(await aside.readAsString(), newerPlaylists);
  });

  test('a damaged file is kept aside too', () async {
    await DatabaseService.addRecentlyPlayed(track);
    final aside = File('${docs.path}/bilibeat_recently_played.json.unreadable');
    expect(await aside.readAsString(), tornHistory);
    expect((await DatabaseService.getRecentlyPlayed()).single.id, track.id);
  });

  test('unreadable lyrics survive the next pin', () async {
    await LyricsStore.pin(
      track.id,
      const Lyrics(
        source: 'user',
        lines: [LyricLine(time: 0, text: 'la')],
      ),
    );
    final aside = File('${docs.path}/bilibeat_lyrics.json.unreadable');
    expect(await aside.readAsString(), newerLyrics);
    expect((await LyricsStore.get(track.id))?.pinned, isTrue);
  });

  group('a picked cover follows the documents folder', () {
    const now = '/var/mobile/Containers/Data/Application/NEW/Documents';

    test('a path into the cover folder is re-pointed', () {
      expect(
        DatabaseService.rebaseCover(
          '/var/mobile/Containers/Data/Application/OLD/Documents'
          '/bilibeat_covers/cover_1.jpg',
          now,
        ),
        '$now/bilibeat_covers/cover_1.jpg',
      );
      expect(
        DatabaseService.rebaseCover(
            'file:///old/Documents/bilibeat_covers/a.png', now),
        '$now/bilibeat_covers/a.png',
      );
    });

    test('a path already there, a web cover and other files are untouched', () {
      for (final url in [
        '$now/bilibeat_covers/cover_1.jpg',
        'https://i0.hdslb.com/bfs/archive/bilibeat_covers/x.jpg',
        '/somewhere/else/picture.jpg',
        '',
      ]) {
        expect(DatabaseService.rebaseCover(url, now), url, reason: url);
      }
    });
  });
}
