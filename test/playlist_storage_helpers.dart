import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/models/track.dart';

/// Shared by the playlist storage tests: each runs in its own isolate, so
/// each launch of the library is a file of its own.
Track song(String key, {String title = 'song'}) => Track(
      id: 'BV1store$key',
      bvid: 'BV1store${key.split('_').first}',
      cid: 1,
      title: '$title $key',
      rawTitle: 'video $key',
      uploader: 'artist',
      coverUrl: '',
      duration: 200,
      named: true,
      matcher: 0,
    );

/// [t] as a download: its audio, marker and metadata in the audio folder.
Future<void> downloaded(Directory docs, Track t) async {
  final audio = Directory('${docs.path}/bilibeat_audio')
    ..createSync(recursive: true);
  final base = '${audio.path}/audio_${t.id}';
  await File('$base.ready').create();
  await File('$base.m4a').writeAsBytes(List.filled(64, 1));
  await File('$base.json').writeAsString(jsonEncode(t.toMap()));
}

Future<void> store(Directory docs, String name, Object data) =>
    File('${docs.path}/$name')
        .writeAsString(jsonEncode({'schema_version': 1, 'data': data}));

Future<dynamic> stored(Directory docs, String name) async =>
    jsonDecode(await File('${docs.path}/$name').readAsString())['data'];

Map<String, dynamic> playlist(String id, List<Object> tracks) =>
    {'id': id, 'name': id, 'tracks': tracks};
