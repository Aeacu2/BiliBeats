import 'dart:async';

import 'package:bilibeats/models/playlist.dart';
import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/services/library_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// A library copied as text on one device and pasted on another.
void main() {
  Track song(String key, {bool named = false, String cover = ''}) => Track(
        id: 'BV1move${key}_p1',
        bvid: 'BV1move$key',
        cid: 7,
        title: named ? '大鱼' : '【4K】周深《大鱼》现场 $key',
        rawTitle: '【4K】周深《大鱼》现场 $key',
        uploader: named ? '周深' : 'the uploader',
        coverUrl: cover.isEmpty ? 'https://example.com/$key.jpg' : cover,
        duration: 200,
        audioUrl: 'https://example.com/signed/$key.m4s',
        named: named,
        rawUploader: named ? 'the uploader' : null,
        matcher: named ? 0 : null,
      );

  setUpAll(() async {
    await stubDocs('transfer');
    await DatabaseService.getDownloadedTracks();
  });

  setUp(LibraryTransfer.resetForTest);

  /// The queue is written to disk between downloads: real IO, real time.
  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('the text carries each song\'s name and the playlists, in order', () {
    final a = song('A', named: true);
    final b = song('B');
    final text = LibraryTransfer.encode(LibrarySnapshot(
      tracks: [a, b],
      playlists: [
        (name: '收藏', favorites: true, tracks: [b]),
        (name: '夜里听', favorites: false, tracks: [b, a]),
      ],
    ));
    expect(text, startsWith(LibraryTransfer.prefix));

    final back = LibraryTransfer.decode('看看这个\n$text\n')!;
    expect(back.tracks.map((t) => t.id), [a.id, b.id]);
    final named = back.tracks.first;
    expect(named.title, '大鱼');
    expect(named.uploader, '周深');
    expect(named.rawTitle, a.rawTitle);
    expect(named.rawUploader, 'the uploader');
    expect(named.matcher, 0);
    expect(named.isNamed, isTrue);
    expect(named.audioUrl, isNull, reason: 'a signed address expires');
    expect(back.playlists[0].favorites, isTrue);
    expect(back.playlists[1].name, '夜里听');
    expect(back.playlists[1].tracks.map((t) => t.id), [b.id, a.id]);
  });

  test('artwork that is a file on this device does not travel', () {
    final local = song('C', cover: '/data/user/0/app/bilibeat_covers/c.jpg');
    final back = LibraryTransfer.decode(LibraryTransfer.encode(
        LibrarySnapshot(tracks: [local], playlists: const [])))!;
    expect(back.tracks.single.coverUrl, isEmpty);
  });

  test('text that is not a library is not one', () {
    expect(LibraryTransfer.decode(''), isNull);
    expect(LibraryTransfer.decode('https://b23.tv/abc'), isNull);
    expect(LibraryTransfer.decode('${LibraryTransfer.prefix}not-a-library'),
        isNull);
    final cut = LibraryTransfer.encode(
        LibrarySnapshot(tracks: [song('D')], playlists: const []));
    expect(LibraryTransfer.decode(cut.substring(0, cut.length - 12)), isNull,
        reason: 'a copy that lost its end is refused, not half imported');
  });

  test(
      'importing downloads what is missing, a few at a time, and merges '
      'playlists by name', () async {
    final here = song('E');
    await DatabaseService.saveDownloadedTrack(here);
    final mine = await DatabaseService.createPlaylist('夜里听');
    await DatabaseService.addTrackToPlaylist(mine.id, here);

    final incoming = [
      for (final k in ['F', 'G', 'H', 'I']) song(k)
    ];
    var running = 0;
    var most = 0;
    final fetched = <String>[];
    final gate = Completer<void>();
    LibraryTransfer.downloadWith = (track) async {
      most = ++running > most ? running : most;
      await gate.future;
      running--;
      fetched.add(track.id);
      return true;
    };

    final result = await LibraryTransfer.import(LibrarySnapshot(
      tracks: [here, ...incoming],
      playlists: [
        (name: '收藏', favorites: true, tracks: [incoming[0]]),
        (name: '夜里听', favorites: false, tracks: [incoming[1], here]),
        (name: '新的', favorites: false, tracks: [incoming[2]]),
      ],
    ));
    expect(result, (queued: 4, present: 1, playlists: 3));
    expect(LibraryTransfer.remaining.value, 4);

    gate.complete();
    await until(() => LibraryTransfer.remaining.value == 0);
    expect(most, 2);
    expect(fetched.toSet(), incoming.map((t) => t.id).toSet());
    expect(LibraryTransfer.remaining.value, 0);

    final lists = await DatabaseService.getPlaylists();
    Playlist named(String name) => lists.firstWhere((p) => p.name == name);
    expect(lists.where((p) => p.name == '夜里听'), hasLength(1));
    expect(named('夜里听').tracks.map((t) => t.id), [incoming[1].id, here.id]);
    expect(named('新的').tracks.single.id, incoming[2].id);
    expect(
        lists
            .firstWhere((p) => p.id == Playlist.favoritesId)
            .tracks
            .map((t) => t.id),
        contains(incoming[0].id));
  });

  test('an unfinished import carries on after a restart', () async {
    final tracks = [song('J'), song('K')];
    final fetched = <String>[];
    LibraryTransfer.downloadWith = (track) async {
      // J cannot be had this time; K is never reached before the app dies.
      if (track.id == tracks[0].id) return false;
      return Completer<bool>().future;
    };
    await LibraryTransfer.import(
        LibrarySnapshot(tracks: tracks, playlists: const []));
    await until(() => LibraryTransfer.remaining.value == 1);
    expect(LibraryTransfer.remaining.value, 1,
        reason: 'a failure is not hammered again in the same run');

    LibraryTransfer.resetForTest();
    LibraryTransfer.downloadWith = (track) async {
      fetched.add(track.id);
      return true;
    };
    await LibraryTransfer.resume();
    await until(() => LibraryTransfer.remaining.value == 0);
    expect(fetched.toSet(), {tracks[0].id, tracks[1].id});
    expect(LibraryTransfer.remaining.value, 0);
  });
}
