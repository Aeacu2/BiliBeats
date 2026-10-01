import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeat/models/lyrics.dart';
import 'package:bilibeat/models/playlist.dart';
import 'package:bilibeat/models/track.dart';

/// Round-trips through the same jsonEncode/jsonDecode the database layer
/// uses, so a field that survives toMap/fromMap but not JSON (e.g. a non-
/// encodable type) is caught here, not on a user's disk.
Map<String, dynamic> throughJson(Map<String, dynamic> map) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(map)));

Track _track({String id = 'BV1_p1', String? audioUrl}) => Track(
      id: id,
      bvid: 'BV1',
      cid: 42,
      title: '显示标题',
      rawTitle: '【原始】B站视频标题',
      uploader: 'UP主',
      coverUrl: 'https://example.com/cover.jpg',
      duration: 245,
      audioUrl: audioUrl,
    );

void main() {
  group('Track', () {
    test('full JSON round-trip preserves every field', () {
      final t = _track(audioUrl: 'https://example.com/a.m4a');
      final rt = Track.fromMap(throughJson(t.toMap()));

      expect(rt.id, t.id);
      expect(rt.bvid, t.bvid);
      expect(rt.cid, t.cid);
      expect(rt.title, t.title);
      expect(rt.rawTitle, t.rawTitle);
      expect(rt.uploader, t.uploader);
      expect(rt.coverUrl, t.coverUrl);
      expect(rt.duration, t.duration);
      expect(rt.audioUrl, t.audioUrl);
      expect(
          rt, t); // identity is the id — rehydrated tracks must compare equal
    });

    test('null audioUrl survives the round-trip', () {
      final rt = Track.fromMap(throughJson(_track().toMap()));
      expect(rt.audioUrl, isNull);
    });

    test('tolerates unknown extra keys (older writer)', () {
      final map = throughJson(_track().toMap());
      map['uploaderFace'] = 'https://example.com/face.jpg';
      map['quality'] = 30280;
      map['isDownloaded'] = true;
      final rt = Track.fromMap(map);
      expect(rt.id, 'BV1_p1');
      expect(rt.title, '显示标题');
    });

    test('tolerates missing keys (newer writer) with safe defaults', () {
      final rt = Track.fromMap(throughJson({'id': 'x'}));
      expect(rt.id, 'x');
      expect(rt.title, isNotEmpty);
      expect(rt.uploader, isNotEmpty);
      expect(rt.cid, 0);
      expect(rt.duration, 0);
      // rawTitle falls back to the *persisted* title; when both are absent
      // there is nothing to fall back to and it stays empty.
      expect(rt.rawTitle, isEmpty);
    });
  });

  group('Playlist', () {
    test('JSON round-trip preserves playlist and nested tracks', () {
      final pl = Playlist(
        id: 'pl_1',
        name: '测试歌单',
        coverUrl: '/covers/pl_1.jpg',
        tracks: [_track(), _track(id: 'BV1_p2')],
      );

      // Serialised exactly the way DatabaseService._persistPlaylists does it.
      final map = pl.toMap();
      map['tracks'] = pl.tracks.map((t) => t.toMap()).toList();
      final decoded = throughJson(map);

      final tracks = (decoded['tracks'] as List<dynamic>)
          .map((t) => Track.fromMap(Map<String, dynamic>.from(t)))
          .toList();
      final rt = Playlist.fromMap(decoded, tracks: tracks);

      expect(rt.id, pl.id);
      expect(rt.name, pl.name);
      expect(rt.coverUrl, pl.coverUrl);
      expect(rt.tracks, pl.tracks);
      expect(rt.tracks.length, 2);
    });

    test('null coverUrl is omitted and stays null', () {
      final pl = Playlist(id: 'pl_2', name: '无封面', tracks: []);
      final decoded = throughJson(pl.toMap());
      expect(decoded.containsKey('coverUrl'), isFalse);
      expect(Playlist.fromMap(decoded).coverUrl, isNull);
    });

    test('tracks list is always growable (add-to-favorites regression)', () {
      final rt = Playlist.fromMap({'id': 'p', 'name': 'n'});
      rt.tracks.add(_track()); // must not throw
      expect(rt.tracks, hasLength(1));
    });
  });

  group('LyricLine', () {
    test('JSON round-trip preserves time, text and translation', () {
      const line =
          LyricLine(time: 72.5, text: '歌词', translation: 'translation');
      final rt = LyricLine.fromMap(throughJson(line.toMap()));
      expect(rt.time, 72.5);
      expect(rt.text, '歌词');
      expect(rt.translation, 'translation');
    });

    test('accepts integer time values from JSON', () {
      final rt = LyricLine.fromMap(throughJson({'time': 72, 'text': 'x'}));
      expect(rt.time, 72.0);
      expect(rt.translation, isNull);
    });
  });

  group('Lyrics', () {
    test('JSON round-trip preserves source, titles, lines, offset and pin', () {
      const res = Lyrics(
        source: 'netease',
        title: '歌名',
        artist: '歌手',
        offset: -0.35,
        pinned: true,
        lines: [
          LyricLine(time: 0, text: '第一行'),
          LyricLine(time: 12.34, text: '第二行', translation: '译'),
        ],
      );
      final rt = Lyrics.fromMap(throughJson(res.toMap()));
      expect(rt.source, 'netease');
      expect(rt.title, '歌名');
      expect(rt.artist, '歌手');
      expect(rt.offset, -0.35);
      expect(rt.pinned, isTrue);
      expect(rt.lines, hasLength(2));
      expect(rt.lines[1].time, 12.34);
      expect(rt.lines[1].translation, '译');
    });

    test('defaults: no source is none, unpinned, no offset', () {
      final bare = Lyrics.fromMap(throughJson({'lines': []}));
      expect(bare.source, 'none');
      expect(bare.lines, isEmpty);
      expect(bare.pinned, isFalse);
      expect(bare.offset, 0.0);
    });

    test('files from before pinning existed keep deliberate choices', () {
      // A paste used to be recognisable only by its source.
      final pasted = Lyrics.fromMap(throughJson({
        'source': 'user',
        'songTitle': '自定义歌词',
        'lines': [
          {'time': 1, 'text': 'x'}
        ],
      }));
      expect(pasted.pinned, isTrue);
      final current =
          Lyrics.fromMap(throughJson({'source': 'current', 'lines': []}));
      expect(current.pinned, isTrue);
      expect(current.source, 'user');
      final automatic =
          Lyrics.fromMap(throughJson({'source': 'netease', 'lines': []}));
      expect(automatic.pinned, isFalse);
    });

    test('synced means timestamps, not just lines', () {
      const timed = Lyrics(source: 'user', lines: [
        LyricLine(time: 0, text: 'a'),
        LyricLine(time: 4, text: 'b'),
      ]);
      const plain = Lyrics(source: 'user', lines: [
        LyricLine(time: 0, text: 'a'),
        LyricLine(time: 0, text: 'b'),
      ]);
      expect(timed.synced, isTrue);
      expect(plain.synced, isFalse);
    });
  });

  group('Track loudness', () {
    test('survives the round-trip and is absent when unknown', () {
      final measured = _track().copyWith(loudness: -9.5);
      expect(Track.fromMap(throughJson(measured.toMap())).loudness, -9.5);
      expect(_track().toMap().containsKey('loudness'), isFalse);
      expect(Track.fromMap(throughJson(_track().toMap())).loudness, isNull);
    });
  });
}
