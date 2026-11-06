import 'package:bilibeats/services/bilibili_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every download starts from a `playurl` answer; these are its shapes.
void main() {
  Map<String, dynamic> answer(Map<String, dynamic> data) =>
      {'code': 0, 'data': data};

  test('the plain stream is preferred, over TLS, with its loudness', () {
    final stream = BilibiliSdk.parseAudioStream(answer({
      'durl': [
        {'url': 'http://cdn.example/a.m4a'},
      ],
      'dash': {
        'audio': [
          {'bandwidth': 1, 'baseUrl': 'https://cdn.example/dash.m4s'},
        ],
      },
      'volume': {'measured_i': -9.5},
    }));
    expect(stream?['url'], 'https://cdn.example/a.m4a');
    expect(stream?['loudness'], '-9.5');
  });

  test('without one, the DASH track with the highest bitrate', () {
    final stream = BilibiliSdk.parseAudioStream(answer({
      'durl': <dynamic>[],
      'dash': {
        'audio': [
          {'bandwidth': 64000, 'baseUrl': 'https://cdn.example/low.m4s'},
          {'bandwidth': 320000, 'base_url': 'https://cdn.example/high.m4s'},
        ],
      },
    }));
    expect(stream?['url'], 'https://cdn.example/high.m4s');
    expect(stream?.containsKey('loudness'), isFalse);
  });

  test('a track that only lists backups is still downloadable', () {
    final stream = BilibiliSdk.parseAudioStream(answer({
      'dash': {
        'audio': [
          {
            'bandwidth': 1,
            'backupUrl': ['http://cdn.example/backup.m4s'],
          },
        ],
      },
    }));
    expect(stream?['url'], 'https://cdn.example/backup.m4s');
  });

  test('Hi-Res FLAC stream is preferred when available', () {
    final stream = BilibiliSdk.parseAudioStream(answer({
      'durl': [
        {'url': 'http://cdn.example/plain.m4a'},
      ],
      'dash': {
        'audio': [
          {'bandwidth': 320000, 'baseUrl': 'https://cdn.example/320k.m4s'},
        ],
        'flac': {
          'audio': {
            'id': 30251,
            'bandwidth': 1764000,
            'baseUrl': 'http://cdn.example/hires.m4s',
          },
        },
      },
    }));
    expect(stream?['url'], 'https://cdn.example/hires.m4s');
    expect(stream?['quality'], 'Hi-Res 无损');
    expect(stream?['qualityId'], '30251');
    expect(stream?['bandwidth'], '1764000');
  });

  test('Dolby Atmos stream is selected over standard audio when available', () {
    final stream = BilibiliSdk.parseAudioStream(answer({
      'dash': {
        'audio': [
          {'bandwidth': 132000, 'baseUrl': 'https://cdn.example/132k.m4s'},
        ],
        'dolby': {
          'audio': [
            {
              'id': 30250,
              'bandwidth': 448000,
              'baseUrl': 'http://cdn.example/dolby.m4s',
            },
          ],
        },
      },
    }));
    expect(stream?['url'], 'https://cdn.example/dolby.m4s');
    expect(stream?['quality'], '杜比全景声');
    expect(stream?['qualityId'], '30250');
  });

  test('320k DASH track is preferred over plain durl', () {
    final stream = BilibiliSdk.parseAudioStream(answer({
      'durl': [
        {'url': 'http://cdn.example/plain.m4a'},
      ],
      'dash': {
        'audio': [
          {
            'id': 30280,
            'bandwidth': 320000,
            'baseUrl': 'http://cdn.example/320k.m4s'
          },
        ],
      },
    }));
    expect(stream?['url'], 'https://cdn.example/320k.m4s');
    expect(stream?['quality'], '320k 高品质');
    expect(stream?['qualityId'], '30280');
  });

  test('a refusal, or an answer naming no stream, is nothing', () {
    expect(BilibiliSdk.parseAudioStream({'code': -412}), isNull);
    expect(BilibiliSdk.parseAudioStream(answer({})), isNull);
    expect(BilibiliSdk.parseAudioStream('<html>'), isNull);
    // A loudness that is not a measurement is left out.
    final stream = BilibiliSdk.parseAudioStream(answer({
      'durl': [
        {'url': 'https://cdn.example/a.m4a'},
      ],
      'volume': {'measured_i': 0},
    }));
    expect(stream?.containsKey('loudness'), isFalse);
  });

  test('Dolby Atmos selects highest bandwidth when multiple streams listed',
      () {
    final stream = BilibiliSdk.parseAudioStream(answer({
      'dash': {
        'dolby': {
          'audio': [
            {
              'id': 30250,
              'bandwidth': 320000,
              'baseUrl': 'http://cdn.example/dolby_320k.m4s',
            },
            {
              'id': 30250,
              'bandwidth': 640000,
              'baseUrl': 'http://cdn.example/dolby_640k.m4s',
            },
            {
              'id': 30250,
              'bandwidth': 448000,
              'baseUrl': 'http://cdn.example/dolby_448k.m4s',
            },
          ],
        },
      },
    }));
    expect(stream?['url'], 'https://cdn.example/dolby_640k.m4s');
    expect(stream?['bandwidth'], '640000');
  });

  test('a video Bilibili will not serve is told from a failed request', () {
    expect(BilibiliSdk.unavailableReason({'code': -404, 'message': '啥都木有'}),
        '啥都木有');
    expect(BilibiliSdk.unavailableReason({'code': 87008}), '视频无法播放');
    // Too many requests, or no answer at all: worth asking again.
    for (final answer in [
      {'code': -412, 'message': '请求被拦截'},
      {'code': -352},
      {'code': -799},
      {'code': 0},
      '<html>',
      null,
    ]) {
      expect(BilibiliSdk.unavailableReason(answer), isNull, reason: '$answer');
    }
  });
}
