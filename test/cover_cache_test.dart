import 'dart:io';

import 'package:bilibeats/widgets/cached_cover_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an oversized cover cache drops what was used longest ago', () async {
    final dir = await Directory.systemTemp.createTemp('bilibeat_covercache');
    addTearDown(() => dir.delete(recursive: true));
    final now = DateTime.now();
    for (var i = 0; i < 10; i++) {
      final file = File('${dir.path}/img_$i.img');
      await file.writeAsBytes(List<int>.filled(1000, i));
      // img_0 is the stalest, img_9 the freshest.
      await file.setLastAccessed(now.subtract(Duration(days: 10 - i)));
    }

    await CachedCoverImage.trimCache(dir, maxBytes: 8000);

    final left = [
      await for (final f in dir.list()) f.uri.pathSegments.last,
    ]..sort();
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
}
