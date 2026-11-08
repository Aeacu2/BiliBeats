import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bilibeats/models/track.dart';
import 'package:bilibeats/services/bilibili_sdk.dart';
import 'package:bilibeats/services/audio_download_service.dart';
import 'package:bilibeats/services/quality_upgrade_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

void main() {
  late Directory docs;
  setUpAll(() async {
    docs = await stubDocs('quality_upgrade');
  });
  test('scan survives listeners leaving and ignores a stopped scan', () async {
    final pending = <Completer<List<QualityUpgradeCandidate>>>[];
    final progress = <void Function(int, int)>[];
    final started = <Completer<void>>[Completer<void>(), Completer<void>()];
    final controller = QualityScanController(scan: ({onProgress, isCancelled}) {
      progress.add(onProgress!);
      final completer = Completer<List<QualityUpgradeCandidate>>();
      pending.add(completer);
      started[pending.length - 1].complete();
      return completer.future;
    });
    var notifications = 0;
    void listener() => notifications++;
    controller.addListener(listener);
    final first = controller.start();
    await started.first.future;
    controller.removeListener(listener);
    progress.first(1, 3);
    expect(controller.scanned, 1);
    expect(controller.state, QualityScanState.scanning);
    controller.stop();
    final second = controller.start();
    await started.last.future;
    pending.first.complete([]);
    await first;
    expect(controller.state, QualityScanState.scanning);
    progress.last(2, 3);
    pending.last.complete([]);
    await second;
    expect(controller.state, QualityScanState.finished);
    expect(controller.scanned, 2);
    expect(notifications, greaterThan(0));
    controller.dispose();
  });
  test('qualityRank correctly orders audio quality tiers', () {
    expect(QualityUpgradeService.qualityRank(30251), 500); // Hi-Res
    expect(QualityUpgradeService.qualityRank(30250), 400); // Dolby
    expect(QualityUpgradeService.qualityRank(30280), 300); // 320k
    expect(QualityUpgradeService.qualityRank(30200), 250); // durl
    expect(QualityUpgradeService.qualityRank(30232), 200); // 132k
    expect(QualityUpgradeService.qualityRank(30216), 100); // 64k

    expect(
        QualityUpgradeService.qualityRank(30251) >
            QualityUpgradeService.qualityRank(30280),
        isTrue);
    expect(
        QualityUpgradeService.qualityRank(30280) >
            QualityUpgradeService.qualityRank(30232),
        isTrue);
  });

  test('local tracks are never candidates for upgrade', () async {
    const localTrack = Track(
      id: 'local_123',
      bvid: '',
      cid: 0,
      title: 'Local File',
      rawTitle: 'Local File',
      uploader: 'Me',
      coverUrl: '',
      duration: 180,
    );
    final candidate = await QualityUpgradeService.checkTrack(localTrack);
    expect(candidate, isNull);
  });

  test('audio requests use supported DASH flags and accept Hi-Res', () async {
    Uri? requested;
    BilibiliSdk.requestWith = (url, {cookies}) async {
      requested = Uri.parse(url);
      return jsonEncode({
        'code': 0,
        'data': {
          'dash': {
            'flac': {
              'audio': {
                'id': 30251,
                'baseUrl': 'https://example.com/hires',
              },
            },
          },
        },
      });
    };
    addTearDown(() => BilibiliSdk.requestWith = null);

    final stream = await BilibiliSdk.fetchAudioStream('BV1TEST', 123);
    expect(requested?.queryParameters['fnval'], '4048');
    expect(requested?.queryParameters['bvid'], 'BV1TEST');
    expect(requested?.queryParameters['cid'], '123');
    expect(stream?['qualityId'], '30251');
    expect(stream?['url'], 'https://example.com/hires');
  });

  test('request errors fall back to the plain API and minimal DASH', () async {
    final requests = <Uri>[];
    BilibiliSdk.requestWith = (url, {cookies}) async {
      final uri = Uri.parse(url);
      requests.add(uri);
      if (uri.path.endsWith('/wbi/playurl') &&
          uri.queryParameters['fnval'] == '16') {
        return jsonEncode({
          'code': 0,
          'data': {
            'dash': {
              'audio': [
                {'id': 30232, 'baseUrl': 'https://example.com/audio'}
              ]
            }
          }
        });
      }
      return jsonEncode({'code': -400, 'message': '请求错误'});
    };
    addTearDown(() => BilibiliSdk.requestWith = null);
    final stream = await BilibiliSdk.fetchAudioStream('BV1TEST', 123);
    expect(stream?['url'], 'https://example.com/audio');
    expect(
        requests.map((uri) => '${uri.path}:${uri.queryParameters['fnval']}'), [
      '/x/player/wbi/playurl:4048',
      '/x/player/playurl:4048',
      '/x/player/wbi/playurl:16'
    ]);
  });

  test('a lower-quality response leaves the existing file intact', () async {
    final audioDir = Directory('${docs.path}/bilibeat_audio');
    await audioDir.create(recursive: true);
    const track = Track(
      id: 'BV1TEST_p1',
      bvid: 'BV1TEST',
      cid: 123,
      title: 'Track',
      rawTitle: 'Track',
      uploader: 'Artist',
      coverUrl: '',
      duration: 200,
    );
    final audio = File('${audioDir.path}/audio_${track.id}.m4a');
    final original = List<int>.filled(2048, 42);
    await audio.writeAsBytes(original);
    BilibiliSdk.requestWith = (url, {cookies}) async {
      if (!url.contains('playurl')) return null;
      return jsonEncode({
        'code': 0,
        'data': {
          'dash': {
            'audio': [
              {
                'id': 30232,
                'bandwidth': 132000,
                'baseUrl': 'https://example.com/audio'
              }
            ]
          }
        }
      });
    };
    addTearDown(() => BilibiliSdk.requestWith = null);
    await expectLater(
      AudioDownloadService.ensureDownloaded(track,
          force: true, minimumQualityRank: 300),
      throwsA(isA<VideoUnavailable>()),
    );
    expect(await audio.readAsBytes(), original);
  });

  test('tracks already at Hi-Res (rank >= 500) skip remote network check',
      () async {
    final audioDir = Directory('${docs.path}/bilibeat_audio');
    await audioDir.create(recursive: true);

    const track = Track(
      id: 'BV1TEST_p1',
      bvid: 'BV1TEST',
      cid: 12345,
      title: 'Hi-Res Track',
      rawTitle: 'Hi-Res Track',
      uploader: 'Artist',
      coverUrl: '',
      duration: 200,
    );

    // Save local quality info as Hi-Res (30251)
    final qualityFile = File('${audioDir.path}/audio_${track.id}.quality.json');
    await qualityFile.writeAsString(jsonEncode({
      'quality': 'Hi-Res 无损',
      'qualityId': 30251,
      'bandwidth': 1764000,
    }));

    // If checkTrack made a network call, requestWith would throw or be called
    var contacted = false;
    BilibiliSdk.requestWith = (_, {cookies}) async {
      contacted = true;
      return null;
    };
    addTearDown(() => BilibiliSdk.requestWith = null);

    final candidate = await QualityUpgradeService.checkTrack(track);
    expect(candidate, isNull);
    expect(contacted, isFalse);
  });
}
