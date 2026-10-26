import 'dart:io';

import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/audio_download_service.dart';
import 'package:bilibeats/services/database_service.dart';
import 'package:bilibeats/services/local_songs.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// Songs from the phone's storage: what the native side's copies become.
void main() {
  late Directory docs;
  late Directory audio;

  setUpAll(() async {
    docs = await stubDocs('local');
    audio = Directory('${docs.path}/bilibeat_audio')..createSync();
  });

  Future<String> copy(String name, List<int> bytes) async {
    final file = File('${audio.path}/incoming_$name.part');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  test('a file name says the song, and the artist where it names one', () {
    expect(LocalSongs.nameOf('周深 - 大鱼.mp3'),
        (stem: '周深 - 大鱼', title: '大鱼', artist: '周深'));
    expect(LocalSongs.nameOf('03. 大鱼.flac'),
        (stem: '03. 大鱼', title: '大鱼', artist: null));
    expect(LocalSongs.nameOf('Recording 12.m4a'),
        (stem: 'Recording 12', title: 'Recording 12', artist: null));
    expect(LocalSongs.nameOf('.mp3'), (stem: '', title: '未知歌曲', artist: null));
  });

  test('tags win over the file name; the song counts as named by the listener',
      () {
    final track = LocalSongs.trackFrom('local_abc', {
      'name': '周深 - 大鱼 (live).mp3',
      'title': '大鱼',
      'artist': '周深',
      'durationMs': 312400,
    });
    expect(track.isLocal, isTrue);
    expect(track.bvid, isEmpty);
    expect(track.title, '大鱼');
    expect(track.uploader, '周深');
    expect(track.rawTitle, '周深 - 大鱼 (live)');
    expect(track.duration, 312);
    expect(track.isNamed, isTrue);
    expect(track.matcher, 0);

    final untagged = LocalSongs.trackFrom('local_abc', {'name': 'demo.wav'});
    expect(untagged.title, 'demo');
    expect(untagged.uploader, '未知歌手');
  });

  test('a copy becomes a downloaded song; the same file twice is one song',
      () async {
    const hash = '0123456789abcdef0123456789abcdef01234567';
    final first = await LocalSongs.adopt([
      {
        'path': await copy('a', List.filled(4096, 7)),
        'hash': hash,
        'name': '周深 - 大鱼.mp3',
        'durationMs': 1000,
        'picture': Uint8List.fromList([1, 2, 3]),
      },
      {'error': 'not audio', 'name': 'notes.txt'},
    ]);
    expect(first.added, hasLength(1));
    expect(first.failed, 1);
    final track = first.added.single;
    expect(track.id, 'local_0123456789abcdef0123');
    expect(await AudioDownloadService.isDownloaded(track), isTrue);
    expect(
        File(await AudioDownloadService.audioPathForId(track.id)).lengthSync(),
        4096);
    expect(File(track.coverUrl).readAsBytesSync(), [1, 2, 3]);
    expect((await DatabaseService.downloadedTrack(track.id))?.title, '大鱼');

    final again = await LocalSongs.adopt([
      {'path': await copy('b', List.filled(4096, 7)), 'hash': hash},
    ]);
    expect(again.added, isEmpty);
    expect(again.existing.single.id, track.id);
    expect(File('${audio.path}/incoming_b.part').existsSync(), isFalse);
  });

  test('a deleted local song is not looked for on Bilibili', () async {
    const track = Track(
      id: 'local_ffffffffffffffffffff',
      bvid: '',
      cid: 0,
      title: 'gone',
      rawTitle: 'gone',
      uploader: 'x',
      coverUrl: '',
      duration: 1,
      named: true,
      matcher: 0,
    );
    await expectLater(AudioDownloadService.ensureDownloaded(track),
        throwsA(isA<VideoUnavailable>()));
  });
}
