import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'song_reader.dart';

/// The on-device model ([SongReader]), from the app's assets.
///
/// A reading takes seconds of arithmetic, so each one runs in an isolate
/// of its own, which also gives the model's memory back when it is done:
/// songs are named one at a time, and rarely.
class SongReaderService {
  SongReaderService._();

  static const String _assets = 'assets/song_model';
  static const List<String> _files = [
    'song_model.bin',
    'song_vocab.txt',
    'song_singers.txt',
  ];

  /// Names this copy of the model; written last when unpacking, so a copy
  /// with it is whole and is this build's.
  static const String _stamp = 'song_model.json';

  static Future<String?>? _unpacked;

  /// Where the model's files are on disk. An isolate cannot read the app's
  /// assets, and handing it 150 MB would hold the model in memory twice, so
  /// they are unpacked once per build and the isolate reads them itself.
  static Future<String?> _directory() async {
    final stamp = await rootBundle.loadString('$_assets/$_stamp', cache: false);
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/song_model');
    final have = File('${dir.path}/$_stamp');
    if (have.existsSync() && have.readAsStringSync() == stamp) return dir.path;
    await dir.create(recursive: true);
    if (have.existsSync()) have.deleteSync();
    for (final name in _files) {
      final data = await rootBundle.load('$_assets/$name');
      final part = File('${dir.path}/$name.part');
      await part.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await part.rename('${dir.path}/$name');
    }
    await have.writeAsString(stamp, flush: true);
    return dir.path;
  }

  /// What the model reads in a video, or null when it cannot be run (the
  /// build ships without it, or it failed): the caller then goes by the
  /// catalogue alone.
  static Future<SongReading?> read({
    required String title,
    required String uploader,
    List<String> tags = const [],
    String musicTitle = '',
    List<String> musicArtists = const [],
    int durationSeconds = 0,
  }) async {
    try {
      final dir = await (_unpacked ??= _directory().catchError((Object e) {
        // Not there this time (no model in this build, a full disk): the
        // next song asks again.
        _unpacked = null;
        debugPrint('Song model unavailable: $e');
        return null;
      }));
      if (dir == null) return null;
      return await Isolate.run(() {
        final reader = SongReader.load(
          File('$dir/${_files[0]}').readAsBytesSync(),
          File('$dir/${_files[1]}').readAsStringSync(),
          File('$dir/${_files[2]}').readAsStringSync(),
        );
        return reader.read(
          title: title,
          uploader: uploader,
          tags: tags,
          musicTitle: musicTitle,
          musicArtists: musicArtists,
          durationSeconds: durationSeconds,
        );
      });
    } catch (e) {
      debugPrint('Song model failed: $e');
      return null;
    }
  }
}
