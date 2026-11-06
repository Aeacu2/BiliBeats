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
