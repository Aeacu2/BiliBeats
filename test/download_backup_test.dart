import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/audio_download_service.dart';
import 'package:bilibeats/services/bilibili_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

// The SDK upgrades stream URLs to HTTPS. Route the local test server back to
// HTTP so the real download code can exercise a failed CDN and its backup.
class _LocalHttp extends HttpOverrides {
  _LocalHttp(this.client);
  final HttpClient client;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _LocalClient(client);
}

class _LocalClient implements HttpClient {
  _LocalClient(this.delegate);
  final HttpClient delegate;

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    if (url.host != '127.0.0.1') {
      throw const SocketException('external network disabled in tests');
    }
    return delegate.getUrl(url.replace(scheme: 'http'));
  }

  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  set idleTimeout(Duration value) => delegate.idleTimeout = value;
  @override
  set maxConnectionsPerHost(int? value) =>
      delegate.maxConnectionsPerHost = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a failed primary CDN falls back to the same audio on a backup',
      () async {
    await stubDocs('backup');
    useRealHttp();
    final realClient = HttpClient();
    final server = await LocalAudioServer.start();
    HttpOverrides.global = _LocalHttp(realClient);
    server.serveError('primary');
    server.serveError('backup');
    server.serveInstant('lower');
    BilibiliSdk.requestWith = (_, {cookies}) async => jsonEncode({
          'code': 0,
          'data': {
            'dash': {
              'audio': [
                {
                  'id': 30280,
                  'bandwidth': 320000,
                  'baseUrl': server.urlFor('primary'),
                  'backupUrl': [server.urlFor('backup')],
                },
                {
                  'id': 30232,
                  'bandwidth': 132000,
                  'baseUrl': server.urlFor('lower'),
                },
              ],
            },
          },
        });
    addTearDown(() async {
      BilibiliSdk.requestWith = null;
      HttpOverrides.global = null;
      realClient.close(force: true);
      await server.stop();
    });
    const track = Track(
      id: 'BV1TEST_p1',
      bvid: 'BV1TEST',
      cid: 123,
      title: 'test',
      rawTitle: 'test',
      uploader: 'test',
      coverUrl: '',
      duration: 1,
    );
    final path = await AudioDownloadService.ensureDownloaded(track);
    expect(await File(path).length(), greaterThanOrEqualTo(1024));
    expect(server.requested, containsAll(['primary', 'backup', 'lower']));
  });
}
