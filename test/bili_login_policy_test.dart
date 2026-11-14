import 'package:bilibeats/screens/bili_login.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('top-level login navigation stays on HTTPS Bilibili hosts', () {
    for (final url in [
      'https://passport.bilibili.com/h5-app/passport/login',
      'https://m.bilibili.com/',
      'https://bilibili.com/',
    ]) {
      expect(BiliLogin.isTrustedLoginUrl(url), isTrue, reason: url);
    }
    for (final url in [
      'http://passport.bilibili.com/',
      'https://bilibili.com.example.net/',
      'https://bilibili.com@example.net/',
      'https://example.net@bilibili.com/',
      'https://bilibili.com:8443/',
      'bilibili://browser',
    ]) {
      expect(BiliLogin.isTrustedLoginUrl(url), isFalse, reason: url);
    }
  });
}
