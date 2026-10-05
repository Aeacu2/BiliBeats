import 'dart:convert';

import 'package:bilibeats/services/bilibili_sdk.dart';
import 'package:bilibeats/services/wbi_signer.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_test_harness.dart';

/// How requests to Bilibili are formed and how its answers are read —
/// offline: the signer falls back to its built-in keys.
void main() {
  setUpAll(useHermeticHttp);

  group('video ids in a search', () {
    test('a BV number is found alone, in a link and in share text', () {
      expect(BilibiliSdk.extractBvOrAvId('BV1xx411c7mD'), 'BV1xx411c7mD');
      expect(BilibiliSdk.extractBvOrAvId('bv1xx411c7mD'), 'BV1xx411c7mD');
      expect(
        BilibiliSdk.extractBvOrAvId(
            'https://www.bilibili.com/video/BV1xx411c7mD?p=2'),
        'BV1xx411c7mD',
      );
      expect(
        BilibiliSdk.extractBvOrAvId('【周深】大鱼 https://b23.tv/BV1xx411c7mD'),
        'BV1xx411c7mD',
      );
    });

    test('an av number is found alone and in a link', () {
      expect(BilibiliSdk.extractBvOrAvId('av170001'), '170001');
      expect(
        BilibiliSdk.extractBvOrAvId('https://www.bilibili.com/video/av170001/'),
        '170001',
      );
    });

    test('words that merely contain "bv" or "av" are not ids', () {
      for (final query in [
        'subversiveness',
        'obviousnessxyz',
        'wav24bit 无损',
        'nav2 导航',
        'Java8 教程',
        'BV2xx411c7mD', // every BV number starts BV1
        'BV1xx411c7mDextra',
      ]) {
        expect(BilibiliSdk.extractBvOrAvId(query), isNull, reason: query);
      }
    });
  });

  group('risk control', () {
    test('the refusal codes are recognised', () {
      expect(BilibiliSdk.isRiskControlled('{"code":-352}'), isTrue);
      expect(
          BilibiliSdk.isRiskControlled('{"code": 412, "data": null}'), isTrue);
    });

    test('code 0 with a captcha voucher and no results is a refusal', () {
      expect(
        BilibiliSdk.isRiskControlled('{"code":0,"data":{"v_voucher":"abc"}}'),
        isTrue,
      );
    });

    test('an ordinary answer, an empty one and non-JSON are not', () {
      expect(
        BilibiliSdk.isRiskControlled('{"code":0,"data":{"result":[]}}'),
        isFalse,
      );
      expect(BilibiliSdk.isRiskControlled('{"code":0,"data":{}}'), isFalse);
      expect(BilibiliSdk.isRiskControlled('<html>'), isFalse);
      expect(BilibiliSdk.isRiskControlled(null), isFalse);
    });
  });

  group('recognised music', () {
    test('artists come as one string, split on its separators', () {
      final live = BilibiliSdk.parseRecognisedMusic(
          {'music_title': '如烟 (Live)', 'origin_artist': '五月天,周深'});
      expect(live.title, '如烟 (Live)');
      expect(live.artists, ['五月天', '周深']);

      expect(
        BilibiliSdk.parseRecognisedMusic({'origin_artist': '宋雨琦/五月天'}).artists,
        ['宋雨琦', '五月天'],
      );
    });

    test('an answer without them is no music', () {
      final none = BilibiliSdk.parseRecognisedMusic({'mv_bvid': 'x'});
      expect(none.title, isEmpty);
      expect(none.artists, isEmpty);
    });
  });

  group('WBI signature', () {
    test('what is sent is what was signed', () async {
      final signed = await WbiSigner.signParams({
        'keyword': "Hello! (Don't) *stop*",
        'page': 1,
      });

      // The characters the signature skips are not sent either.
      expect(signed['keyword'], 'Hello Dont stop');

      // Recompute the signature from the parameters as a caller sends them.
      final sent = Map.of(signed)..remove('w_rid');
      final query = (sent.keys.toList()..sort())
          .map((k) => '${Uri.encodeComponent(k)}='
              '${Uri.encodeComponent(sent[k].toString())}')
          .join('&');
      // Offline, the signer uses its built-in keys.
      const img = '7057082772594611a917024e0f065363';
      const sub = '0a6e0388df634f1ca668482436d4001c';
      final mixin = WbiSigner.mixinKeyEncTab
          .map((n) => (img + sub)[n])
          .join()
          .substring(0, 32);
      expect(
          signed['w_rid'], md5.convert(utf8.encode(query + mixin)).toString());
    });

    test('a keyword without those characters is sent unchanged', () async {
      final signed = await WbiSigner.signParams({'keyword': '周杰伦 晴天'});
      expect(signed['keyword'], '周杰伦 晴天');
    });
  });
}
