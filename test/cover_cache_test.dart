import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/widgets/cached_cover_image.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';
import 'player_page_harness.dart' show pumpUntil;

void main() {
  test('an oversized cover cache drops what was used longest ago', () async {
    final dir = await Directory.systemTemp.createTemp('bilibeat_covercache');
    addTearDown(() => dir.delete(recursive: true));
    final now = DateTime.now();
    for (var i = 0; i < 10; i++) {
      final file = File('${dir.path}/img_$i.img');
      await file.writeAsBytes(List<int>.filled(1000, i));
      // img_0 is the stalest, img_9 the freshest.
      await file.setLastModified(now.subtract(Duration(days: 10 - i)));
    }

    await CachedCoverImage.trimCache(dir, maxBytes: 8000);

    final left = [await for (final f in dir.list()) f.uri.pathSegments.last]
      ..sort();
    // Down to three quarters of the limit: the six freshest remain.
    expect(left, [for (var i = 4; i < 10; i++) 'img_$i.img']);
  });

  test('a cache within its limit is left alone', () async {
    final dir = await Directory.systemTemp.createTemp('bilibeat_covercache');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/img_a.img').writeAsBytes(List<int>.filled(1000, 1));

    await CachedCoverImage.trimCache(dir, maxBytes: 8000);

    expect(await File('${dir.path}/img_a.img').exists(), isTrue);
  });

  testWidgets('a recycled cover keeps the original URL in its disk key', (
    tester,
  ) async {
    useHermeticHttp();
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('bilibeat_cover_request'),
    ))!;
    final server = (await tester.runAsync(LocalAudioServer.start))!;
    final directoryPath = Completer<String>();
    addTearDown(() async {
      await server.stop();
      await dir.delete(recursive: true);
      HttpOverrides.global = null;
    });
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) => call.method == 'getApplicationSupportDirectory'
          ? directoryPath.future
          : Future.value(),
    );

    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAA'
        'C0lEQVR42mP8/x8AAwMCAO+aULsAAAAASUVORK5CYII=';
    server.serveInstant('old-cover', base64Decode(png));
    server.serveError('current-cover');
    final oldUrl = server.urlFor('old-cover');
    final currentUrl = server.urlFor('current-cover');
    Widget showCover(String url) => MaterialApp(
          home:
              Center(child: CachedCoverImage(url: url, width: 48, height: 48)),
        );
    String hash(String url) => md5.convert(utf8.encode(url)).toString();
    final oldSize = hash(oldUrl).substring(0, 10);
    File cachedUnder(String url) =>
        File('${dir.path}/bilibeat_covers/img_${hash(url)}_$oldSize.img');

    await tester.pumpWidget(showCover(oldUrl));
    await tester.pumpWidget(showCover(currentUrl));
    directoryPath.complete(dir.path);
    await pumpUntil(
      tester,
      () =>
          server.requested.contains('old-cover') &&
          (cachedUnder(oldUrl).existsSync() ||
              cachedUnder(currentUrl).existsSync()),
    );

    expect(cachedUnder(oldUrl).existsSync(), isTrue);
    expect(cachedUnder(currentUrl).existsSync(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 31));
  });
}
