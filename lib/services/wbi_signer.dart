import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'bili_http.dart';

class WbiSigner {
  static final HttpClient _client = biliHttpClient();

  static final RegExp _stripChars = RegExp(r"[!'()*]");

  static const List<int> mixinKeyEncTab = [
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
    37,
    48,
    7,
    16,
    24,
    55,
    40,
    61,
    26,
    17,
    0,
    1,
    60,
    51,
    30,
    4,
    22,
    25,
    54,
    21,
    56,
    59,
    6,
    63,
    57,
    62,
    11,
    36,
    20,
    34,
    44,
    52
  ];

  static String _cachedImgKey = '';
  static String _cachedSubKey = '';
  static DateTime? _cacheTime;

  /// When the live keys could not be fetched, they are not asked for again
  /// before this: every signed request would otherwise wait out the same
  /// dead connection first.
  static DateTime? _retryAfter;
  static const Duration _retryEvery = Duration(minutes: 2);

  static const Map<String, String> _fallbackKeys = {
    'imgKey': '7057082772594611a917024e0f065363',
    'subKey': '0a6e0388df634f1ca668482436d4001c',
  };

  static String _getMixinKey(String orig) {
    return mixinKeyEncTab.map((n) => orig[n]).join().substring(0, 32);
  }

  static Future<Map<String, dynamic>> signParams(
      Map<String, dynamic> params) async {
    final keys = await _getWbiKeys();
    final mixinKey = _getMixinKey(keys['imgKey']! + keys['subKey']!);
    final currTime = (DateTime.now().millisecondsSinceEpoch / 1000).round();

    final newParams = Map<String, dynamic>.from(params);
    newParams['wts'] = currTime;

    // The characters the signature leaves out are left out of the request
    // too: Bilibili signs what it receives, so a keyword sent as "Hello!"
    // but signed as "Hello" is refused (quietly — see
    // [BilibiliSdk.isRiskControlled]).
    for (final k in newParams.keys.toList()) {
      newParams[k] = newParams[k].toString().replaceAll(_stripChars, '');
    }

    final sortedKeys = newParams.keys.toList()..sort();
    final queryParts = <String>[];

    for (final k in sortedKeys) {
      final val = newParams[k] as String;
      queryParts.add('${Uri.encodeComponent(k)}=${Uri.encodeComponent(val)}');
    }

    final queryStr = queryParts.join('&');
    final wbiSign = md5.convert(utf8.encode(queryStr + mixinKey)).toString();

    newParams['w_rid'] = wbiSign;
    return newParams;
  }

  static Future<Map<String, String>> _getWbiKeys() async {
    if (_cacheTime != null &&
        DateTime.now().difference(_cacheTime!).inHours < 12) {
      if (_cachedImgKey.isNotEmpty && _cachedSubKey.isNotEmpty) {
        return {'imgKey': _cachedImgKey, 'subKey': _cachedSubKey};
      }
    }

    final retryAfter = _retryAfter;
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) {
      return _fallbackKeys;
    }

    try {
      final req = await _client
          .getUrl(Uri.parse('https://api.bilibili.com/x/web-interface/nav'))
          .timeout(const Duration(seconds: 10));
      req.headers.set('User-Agent', kBiliUserAgent);
      req.headers.set('Referer', 'https://www.bilibili.com/');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw Exception('WBI HTTP ${res.statusCode}');
      }
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      final json = jsonDecode(body);
      final wbiImg = json['data']?['wbi_img'];
      if (wbiImg != null) {
        final imgUrl = wbiImg['img_url'] as String? ?? '';
        final subUrl = wbiImg['sub_url'] as String? ?? '';

        _cachedImgKey = imgUrl.split('/').last.split('.').first;
        _cachedSubKey = subUrl.split('/').last.split('.').first;
        _cacheTime = DateTime.now();
        _retryAfter = null;

        return {'imgKey': _cachedImgKey, 'subKey': _cachedSubKey};
      }
    } catch (e) {
      debugPrint('Failed to fetch WBI keys: $e');
    }

    // Fallback static keys if network unavailable. B站 rotates these, so a
    // stale pair signs requests that the API rejects — make that degraded
    // state visible instead of silently serving bad signatures.
    debugPrint('WbiSigner: live WBI keys unavailable, using static fallback. '
        'Signed requests may be rejected until the live keys can be fetched.');
    _retryAfter = DateTime.now().add(_retryEvery);
    return _fallbackKeys;
  }
}
