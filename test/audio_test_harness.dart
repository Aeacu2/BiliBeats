import 'dart:async';
import 'dart:io';

import 'package:bilibeats/models/track.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real HTTP overrides: flutter_test installs a mock that answers 400 to
/// every request at binding init. Tests using [LocalAudioServer] restore
/// real clients with this (static assignment wins: the mock is static too).
class _RealHttpOverrides extends HttpOverrides {}

void useRealHttp() {
  HttpOverrides.global = _RealHttpOverrides();
}

/// Hermetic overrides for widget tests: localhost (the test audio server)
/// stays real, while any external host fails fast with [SocketException].
/// Provider lookups (lyrics, metadata) therefore resolve in milliseconds
/// instead of hanging on network timeouts, and results stay deterministic
/// with or without ambient connectivity.
class _SelectiveOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _SelectiveClient();
}

class _RealHolder extends HttpOverrides {}

class _SelectiveClient implements HttpClient {
  HttpClient? _real;

  HttpClient get _r => _real ??= HttpOverrides.runWithHttpOverrides(
        HttpClient.new,
        _RealHolder(),
      )!;

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    if (url.host == '127.0.0.1' || url.host == 'localhost') {
      return _r.getUrl(url);
    }
    throw const SocketException('external network disabled in tests');
  }

  @override
  set connectionTimeout(Duration? value) {
    if (value != null) _r.connectionTimeout = value;
  }

  @override
  set idleTimeout(Duration? value) {
    if (value != null) _r.idleTimeout = value;
  }

  @override
  set maxConnectionsPerHost(int? value) {
    if (value != null) _r.maxConnectionsPerHost = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void useHermeticHttp() {
  HttpOverrides.global = _SelectiveOverrides();
}

/// Local HTTP audio origin for handler tests: no real network, fully
/// deterministic timing and failure injection.
class LocalAudioServer {
  final HttpServer _server;
  final Map<String, List<int>> _instant = {};
  final Map<String, Completer<void>> _gates = {};
  final Set<String> _errors = {};

  /// Every request path seen, for deterministic "download started" waits.
  final Set<String> requested = {};

  LocalAudioServer._(this._server);

  static Future<LocalAudioServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = LocalAudioServer._(server);
    server.listen(origin._handle);
    return origin;
  }

  int get port => _server.port;

  String urlFor(String name) => 'http://127.0.0.1:$port/$name';

  /// Serves [bytes] (padded to >= 1024) immediately as audio/mp4.
  void serveInstant(String name, [List<int>? bytes]) {
    _errors.remove(name);
    _gates.remove(name);
    _instant[name] = _padded(bytes);
  }

  /// Blocks the response until [gate] completes, then serves audio.
  void serveGated(String name, Completer<void> gate, [List<int>? bytes]) {
    _errors.remove(name);
    _instant[name] = _padded(bytes);
    _gates[name] = gate;
  }

  /// Answers with an HTTP error so the download fails deterministically.
  void serveError(String name) {
    _instant.remove(name);
    _gates.remove(name);
    _errors.add(name);
  }

  static List<int> _padded([List<int>? bytes]) {
    var body = List<int>.of(bytes ?? [0x66, 0x74, 0x79, 0x70]);
    while (body.length < 2048) {
      body = [...body, ...body];
    }
    return body;
  }

  Future<void> _handle(HttpRequest request) async {
    final name =
        request.uri.pathSegments.isEmpty ? '' : request.uri.pathSegments.last;
    requested.add(name);
    try {
      if (_errors.contains(name)) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
        return;
      }
      final gate = _gates[name];
      if (gate != null) {
        await gate.future;
      }
      final body = _instant[name];
      if (body == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType('audio', 'mp4');
      request.response.headers.contentLength = body.length;
      request.response.add(body);
      await request.response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> stop() => _server.close(force: true);
}

/// Shared per-file setup for handler tests: temp documents dir for the
/// path_provider stub (each test file runs in its own isolate, so static
/// caches never cross files).
Future<Directory> stubDocs(String tag) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = await Directory.systemTemp.createTemp('bilibeat_$tag');
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    if (call.method == 'getApplicationDocumentsDirectory') {
      return dir.path;
    }
    return null;
  });
  return dir;
}

/// A test track whose audio comes from [server]. Unique [name] per test:
/// download memoization is process-static.
Track serverTrack(LocalAudioServer server, String name,
    {String title = 'title'}) {
  return Track(
    id: 'ht-$name',
    bvid: 'BV1TEST$name',
    cid: 1,
    title: title,
    rawTitle: title,
    uploader: 'uploader',
    coverUrl: '',
    duration: 200,
    audioUrl: server.urlFor(name),
  );
}

/// Polls [condition] until true or [timeout]; races in the handler settle
/// through real async gaps, never fixed sleeps in assertions.
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Async variant of [waitFor] for filesystem/network-backed conditions.
Future<void> waitForTrue(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
