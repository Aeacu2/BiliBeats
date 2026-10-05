import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/audio_download_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// An audio origin that honours `Range` / `If-Range` the way a CDN does, and
/// can drop the connection part-way through a body.
class _RangeServer {
  _RangeServer._(this._server);

  final HttpServer _server;

  List<int> body = const [];
  String? etag;

  /// Send only this many body bytes of the next full response, then drop
  /// the connection.
  int? cutAfter;

  /// Every request's `Range` header (null when it had none).
  final List<String?> ranges = [];

  static Future<_RangeServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = _RangeServer._(server);
    server.listen(origin._handle);
    return origin;
  }

  String get url => 'http://127.0.0.1:${_server.port}/audio';

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
    ranges.add(range);
    final response = request.response;

    final cut = cutAfter;
    if (cut != null) {
      cutAfter = null;
      final socket = await response.detachSocket(writeHeaders: false);
      socket.add(utf8.encode('HTTP/1.1 200 OK\r\n'
          'Content-Type: audio/mp4\r\n'
          'Content-Length: ${body.length}\r\n'
          '${etag == null ? '' : 'ETag: $etag\r\n'}'
          '\r\n'));
      socket.add(body.sublist(0, cut));
      await socket.flush();
      socket.destroy();
      return;
    }

    response.headers.contentType = ContentType('audio', 'mp4');
    if (etag != null) response.headers.set(HttpHeaders.etagHeader, etag!);

    // A changed file answers a conditional range with the whole of itself.
    final ranged = range != null && (ifRange == null || ifRange == etag);
    if (ranged) {
      final start =
          int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (start >= body.length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */${body.length}');
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentRangeHeader,
          'bytes $start-${body.length - 1}/${body.length}');
      response.headers.contentLength = body.length - start;
      response.add(body.sublist(start));
    } else {
      response.headers.contentLength = body.length;
      response.add(body);
    }
    await response.close();
  }
}

/// A partial download is only continued when it is the start of the file
/// the server has now. Every attempt gets a fresh link from Bilibili, which
/// can be a different encode; appending its tail to the old head made a
/// track that was marked downloaded and could not play.
void main() {
  late _RangeServer server;
  late Directory docs;

  final first = List<int>.generate(8192, (i) => i % 251);
  final second = List<int>.generate(6000, (i) => (i * 7 + 3) % 253);

  setUpAll(() async {
    docs = await stubDocs('download_resume');
    useRealHttp();
    server = await _RangeServer.start();
  });

  tearDownAll(() => server.stop());

  setUp(() {
    server
      ..body = first
      ..etag = '"v1"'
      ..cutAfter = null
      ..ranges.clear();
  });

  // Unique per test: download state is memoised per id for the process.
  Track track(String name) => Track(
        id: 'rs-$name',
        bvid: 'BV1RESUME',
        cid: 1,
        title: name,
        rawTitle: name,
        uploader: 'uploader',
        coverUrl: '',
        duration: 200,
        audioUrl: server.url,
      );

  String audioPath(Track t) => '${docs.path}/bilibeat_audio/audio_${t.id}.m4a';
  File part(Track t) => File('${audioPath(t)}.part');
  File note(Track t) => File('${audioPath(t)}.part.json');

  Future<void> plant(Track t, List<int> bytes,
      {Object? total, String? validator}) async {
    await Directory('${docs.path}/bilibeat_audio').create(recursive: true);
    await part(t).writeAsBytes(bytes);
    if (total != null || validator != null) {
      await note(t)
          .writeAsString(jsonEncode({'total': total, 'validator': validator}));
    }
  }

  Future<List<int>> downloaded(Track t) async {
    expect(await AudioDownloadService.isDownloaded(t), isTrue);
    return File(audioPath(t)).readAsBytes();
  }

  test('an interrupted download picks up where it stopped', () async {
    final t = track('interrupted');
    server.cutAfter = 3000;

    await expectLater(
        AudioDownloadService.ensureDownloaded(t), throwsA(anything));
    expect(await AudioDownloadService.isDownloaded(t), isFalse);
    expect(await part(t).length(), 3000);
    expect(jsonDecode(await note(t).readAsString()),
        {'total': first.length, 'validator': '"v1"'});

    await AudioDownloadService.ensureDownloaded(t);

    expect(server.ranges, [null, 'bytes=3000-']);
    expect(await downloaded(t), first);
    expect(await part(t).exists(), isFalse);
    expect(await note(t).exists(), isFalse);
  });

  test('a file that changed on the server is downloaded whole', () async {
    final t = track('changed');
    await plant(t, first.sublist(0, 3000),
        total: first.length, validator: '"v1"');
    server
      ..body = second
      ..etag = '"v2"';

    await AudioDownloadService.ensureDownloaded(t);

    // Not the head of one file with the tail of another.
    expect(await downloaded(t), second);
  });

  test('without validators, a different total length starts over', () async {
    final t = track('length');
    await plant(t, first.sublist(0, 3000), total: first.length);
    server
      ..body = second
      ..etag = null;

    await AudioDownloadService.ensureDownloaded(t);

    expect(server.ranges, ['bytes=3000-', null]);
    expect(await downloaded(t), second);
  });

  test('partial bytes nothing vouches for are not continued', () async {
    final t = track('orphan');
    await plant(t, second.sublist(0, 3000)); // no note beside it

    await AudioDownloadService.ensureDownloaded(t);

    expect(server.ranges, [null]);
    expect(await downloaded(t), first);
  });

  test('a complete partial file is finished without downloading again',
      () async {
    final t = track('complete');
    await plant(t, first, total: first.length, validator: '"v1"');

    await AudioDownloadService.ensureDownloaded(t);

    expect(server.ranges, ['bytes=${first.length}-']);
    expect(await downloaded(t), first);
  });

  test('a partial file longer than the server\'s is not taken for complete',
      () async {
    final t = track('toolong');
    // 9000 bytes of a file that was 12000 long; the server now has 8192.
    await plant(t, List<int>.filled(9000, 1), total: 12000);
    server.etag = null;

    await AudioDownloadService.ensureDownloaded(t);

    expect(server.ranges, ['bytes=9000-', null]);
    expect(await downloaded(t), first);
  });

  group('ids that are not file names', () {
    test('are recognised', () {
      expect(AudioDownloadService.isSafeKey('BV1xx411c7mD_p3'), isTrue);
      for (final id in ['../../prefs', 'a/b', r'a\b', 'BV1..', '', 'a b']) {
        expect(AudioDownloadService.isSafeKey(id), isFalse, reason: id);
      }
    });

    test('are never downloaded or looked up on disk', () async {
      final hostile = Track(
        id: '../escape',
        bvid: 'BV1RESUME',
        cid: 1,
        title: 'x',
        rawTitle: 'x',
        uploader: 'u',
        coverUrl: '',
        duration: 1,
        audioUrl: server.url,
      );
      expect(await AudioDownloadService.isDownloadedById(hostile.id), isFalse);
      await expectLater(
          AudioDownloadService.ensureDownloaded(hostile), throwsA(anything));
      expect(server.ranges, isEmpty);
      expect(await File('${docs.path}/escape.m4a').exists(), isFalse);
    });
  });
}
