import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'package:bilibeats/services/store_files.dart';
import 'package:bilibeats/services/search_history.dart';

/// What a launch makes of the files the last one left: the stores are read
/// back, the download list is squared with the audio on disk, and covers
/// nothing shows any more are cleared away.
void main() {
  late Directory docs;

  Track track(String key, {String cover = ''}) => Track(
        id: 'BV1restart${key}_p1',
        bvid: 'BV1restart$key',
        cid: 1,
        title: 'song $key',
        rawTitle: 'video $key',
        uploader: 'artist $key',
        coverUrl: cover,
        duration: 200,
        named: true,
        matcher: 0,
      );

  setUpAll(() async {
    docs = await stubDocs('restart');
    final audio = Directory('${docs.path}/bilibeat_audio')..createSync();
    final covers = Directory('${docs.path}/bilibeat_covers')..createSync();

    Future<void> files(Track t, {bool ready = true, bool m4a = true}) async {
      final base = '${audio.path}/audio_${t.id}';
      if (ready) await File('$base.ready').create();
      if (m4a) await File('$base.m4a').writeAsBytes(List.filled(2048, 1));
      await File('$base.json').writeAsString(jsonEncode(t.toMap()));
    }

    final old = DateTime.now().subtract(const Duration(days: 3));
    Future<String> cover(String name, {bool aged = true}) async {
      final file = File('${covers.path}/$name');
      await file.writeAsBytes([1, 2, 3]);
      if (aged) await file.setLastModified(old);
      return file.path;
    }

    final usedCover = await cover('used.jpg');
    final playlistCover = await cover('playlist.jpg');
    await cover('unused_old.jpg');
    await cover('unused_new.jpg', aged: false);

    final a = track('A', cover: 'file://$usedCover');
    final b = track('B');
    final c = track('C');
    await files(a);
    await files(b, m4a: false); // listed, but its audio is gone
    await files(c); // on disk, but not listed
    // Left behind by a write and a download that did not finish.
    await File('${audio.path}/audio_x.json.123.tmp').writeAsString('x');
    await File('${audio.path}/audio_old.m4a.part').writeAsString('x');
    await File('${audio.path}/audio_old.m4a.part')
        .setLastModified(DateTime.now().subtract(const Duration(days: 30)));
    await File('${audio.path}/audio_new.m4a.part').writeAsString('x');
    await File('${docs.path}/bilibeat_playlists.json.9.tmp').writeAsString('x');

    await File('${docs.path}/bilibeat_downloaded.json')
        .writeAsString(jsonEncode({
      'schema_version': StoreFiles.schemaVersion,
      'data': [a.toMap(), b.toMap()],
    }));
    await File('${docs.path}/bilibeat_playlists.json')
        .writeAsString(jsonEncode({
      'schema_version': StoreFiles.schemaVersion,
      'data': [
        {
          'id': 'favorites',
          'name': '收藏',
          'tracks': [a.toMap()],
        },
        {
          'id': 'pl_1',
          'name': 'road',
          'coverUrl': playlistCover,
          'tracks': [a.toMap(), b.toMap()],
        },
      ],
    }));
    // Written before files carried a version: the bare payload.
    await File('${docs.path}/bilibeat_recently_played.json')
        .writeAsString(jsonEncode([b.toMap(), a.toMap()]));
    await File('${docs.path}/bilibeat_search_history.json')
        .writeAsString(jsonEncode(['周深', '大鱼']));
  });

  test('downloads are what is both listed and on disk, plus what is found',
      () async {
    final ids = [
      for (final t in await DatabaseService.getDownloadedTracks()) t.id
    ];
    expect(ids, unorderedEquals([track('A').id, track('C').id]));

    // The corrected list is written back.
    final file = File('${docs.path}/bilibeat_downloaded.json');
    await waitForTrue(() async {
      final data = jsonDecode(await file.readAsString())['data'] as List;
      return data.length == 2;
    });
  });

  test('playlists, favourites, history and searches come back as saved',
      () async {
    final playlists = await DatabaseService.getPlaylists();
    expect(playlists.map((p) => p.id), ['favorites', 'pl_1']);
    expect(playlists[1].name, 'road');
    expect(playlists[1].tracks.map((t) => t.title), ['song A', 'song B']);
    expect(playlists[0].tracks.single.isNamed, isTrue);

    final history = await DatabaseService.getRecentlyPlayed();
    expect(history.map((t) => t.id), [track('B').id, track('A').id]);
    expect(await SearchHistory.get(), ['周深', '大鱼']);
  });

  test('covers in use are kept; old ones nothing shows are removed', () async {
    await DatabaseService.getPlaylists();
    final covers = '${docs.path}/bilibeat_covers';
    await waitForTrue(
        () async => !await File('$covers/unused_old.jpg').exists());
    expect(await File('$covers/used.jpg').exists(), isTrue);
    expect(await File('$covers/playlist.jpg').exists(), isTrue);
    expect(await File('$covers/unused_new.jpg').exists(), isTrue);
  });

  test('what unfinished writes left behind is cleared', () async {
    await DatabaseService.getDownloadedTracks();
    final audio = '${docs.path}/bilibeat_audio';
    expect(await File('$audio/audio_x.json.123.tmp').exists(), isFalse);
    expect(await File('$audio/audio_old.m4a.part').exists(), isFalse);
    // A recent partial download may still be resumed.
    expect(await File('$audio/audio_new.m4a.part').exists(), isTrue);
    expect(await File('${docs.path}/bilibeat_playlists.json.9.tmp').exists(),
        isFalse);
  });
}
