import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'song_reader.dart';

/// The on-device model ([SongReader]), from the app's assets.
///
/// A reading takes a second or more of arithmetic, so it runs in an isolate
/// of its own ([_ReaderWorker]). Loading the model there takes as long
/// again, so the isolate keeps it while songs keep coming (an import names
/// hundreds) and exits once they stop, giving the memory back.
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
  static _ReaderWorker? _worker;

  /// How long the model stays loaded after the last reading.
  static const Duration _keepFor = Duration(seconds: 30);

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
      return await (_worker ??= _ReaderWorker.start(dir)).read([
        title,
        uploader,
        tags,
        musicTitle,
        musicArtists,
        durationSeconds,
      ]);
    } catch (e) {
      debugPrint('Song model failed: $e');
      return null;
    }
  }
}

/// One isolate holding the model, reading one video per request.
class _ReaderWorker {
  _ReaderWorker._(this._ready);

  final Future<SendPort> _ready;
  final RawReceivePort _replies = RawReceivePort();
  final Map<int, Completer<SongReading?>> _waiting = {};
  int _next = 0;
  Isolate? _isolate;
  Timer? _idle;
  bool _closed = false;

  static _ReaderWorker start(String dir) {
    final port = Completer<SendPort>();
    final worker = _ReaderWorker._(port.future..ignore());
    worker._replies.handler = (Object? message) {
      if (message is SendPort) {
        port.complete(message);
      } else if (message is List && message.length == 2 && message[0] is int) {
        // (id, reading) — or (id, error text) when the reading failed.
        final reply = message[1];
        worker._waiting.remove(message[0])?.complete(
              reply is SongReading ? reply : null,
            );
        if (reply is String) debugPrint('Song model failed: $reply');
        worker._scheduleExit();
      } else {
        // The isolate died (out of memory, a crash): what was asked of it
        // has no answer, and the next song starts a new one.
        worker._close();
      }
    };
    unawaited(() async {
      try {
        worker._isolate = await Isolate.spawn(
          _serve,
          (worker._replies.sendPort, dir),
          onExit: worker._replies.sendPort,
          onError: worker._replies.sendPort,
        );
        if (worker._closed) worker._isolate?.kill();
      } catch (e) {
        debugPrint('Song model worker failed to start: $e');
        if (!port.isCompleted) port.completeError(e);
        worker._close();
      }
    }());
    return worker;
  }

  Future<SongReading?> read(List<Object> request) async {
    _idle?.cancel();
    final id = _next++;
    final answer = Completer<SongReading?>();
    _waiting[id] = answer;
    try {
      (await _ready).send([id, ...request]);
    } catch (_) {
      _waiting.remove(id);
      return null;
    }
    return answer.future;
  }

  void _scheduleExit() {
    _idle?.cancel();
    if (_waiting.isNotEmpty) return;
    _idle = Timer(SongReaderService._keepFor, _close);
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _idle?.cancel();
    if (identical(SongReaderService._worker, this)) {
      SongReaderService._worker = null;
    }
    _isolate?.kill();
    _replies.close();
    for (final waiting in _waiting.values) {
      waiting.complete(null);
    }
    _waiting.clear();
  }

  static void _serve((SendPort, String) setup) {
    final (replies, dir) = setup;
    final requests = ReceivePort();
    SongReader? reader;
    requests.listen((Object? message) {
      final m = message! as List;
      try {
        reader ??= SongReader.load(
          File('$dir/${SongReaderService._files[0]}').readAsBytesSync(),
          File('$dir/${SongReaderService._files[1]}').readAsStringSync(),
          File('$dir/${SongReaderService._files[2]}').readAsStringSync(),
        );
        replies.send([
          m[0],
          reader!.read(
            title: m[1] as String,
            uploader: m[2] as String,
            tags: (m[3] as List).cast<String>(),
            musicTitle: m[4] as String,
            musicArtists: (m[5] as List).cast<String>(),
            durationSeconds: m[6] as int,
          ),
        ]);
      } catch (e) {
        replies.send([m[0], '$e']);
      }
    });
    replies.send(requests.sendPort);
  }
}
